defmodule MayonnaiOS.SavesTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Saves

  # What cannot be tested from here: whether an fsync reached the card. There
  # is no way to observe that from Elixir and no way to observe it on the
  # device either without pulling the power mid-game. So `:sync` is injected
  # and what these tests assert is the part that can be wrong silently -- that
  # the right directory is found, and that every file in it gets a handle and a
  # sync -- because a flush of the wrong directory succeeds, logs a cheerful
  # zero, and protects nothing.

  setup do
    base = Path.join(System.tmp_dir!(), "saves-test-#{System.unique_integer([:positive])}")
    saves = Path.join(base, "saves")
    File.mkdir_p!(saves)

    keys = [:retroarch_config, :retroarch_append_config, :retroarch_save_dir, :bundle_root]
    prev = Map.new(keys, &{&1, Application.get_env(:mayonnaios, &1)})

    Application.put_env(:mayonnaios, :retroarch_config, Path.join(base, "retroarch.cfg"))
    Application.put_env(:mayonnaios, :retroarch_append_config, Path.join(base, "mayonnaios.cfg"))
    Application.put_env(:mayonnaios, :bundle_root, Path.join(base, "bundles"))
    Application.delete_env(:mayonnaios, :retroarch_save_dir)

    on_exit(fn ->
      File.rm_rf(base)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:mayonnaios, k)
        {k, v} -> Application.put_env(:mayonnaios, k, v)
      end)
    end)

    %{base: base, saves: saves}
  end

  # A sync that records which file it was handed instead of syncing it, by
  # reading the handle: every file below writes its own name as its contents,
  # so a test can assert *which* files were flushed and not merely how many.
  defp recorder do
    test = self()

    fn handle ->
      send(test, {:synced, read(handle)})
      :ok
    end
  end

  defp read(handle) do
    case :file.read(handle, 100) do
      {:ok, data} -> data
      other -> other
    end
  end

  defp synced do
    receive do
      {:synced, what} -> [what | synced()]
    after
      0 -> []
    end
  end

  describe "flush/1" do
    test "fsyncs a save that is one directory down, because that is where it is",
         %{saves: saves} do
      # sort_savefiles_enable = "true", so the file is under a per-core
      # directory: a flat listing of the save directory finds nothing at all.
      core = Path.join(saves, "Snes9x 2010")
      File.mkdir_p!(core)
      File.write!(Path.join(core, "Chrono Trigger (U) [!].srm"), "chrono")

      assert {:ok, 1} = Saves.flush(dir: saves, sync: recorder())
      assert synced() == ["chrono"]
    end

    test "fsyncs every file, at any depth", %{saves: saves} do
      File.write!(Path.join(saves, "top.srm"), "top")
      File.mkdir_p!(Path.join(saves, "core/deeper"))
      File.write!(Path.join(saves, "core/mid.srm"), "mid")
      File.write!(Path.join(saves, "core/deeper/deep.srm"), "deep")

      assert {:ok, 3} = Saves.flush(dir: saves, sync: recorder())
      assert Enum.sort(synced()) == ["deep", "mid", "top"]
    end

    test "a directory that is not there yet is not a failure", %{base: base} do
      # A device where nobody has saved anything. Reporting an error here would
      # make the launcher log a warning on every exit of every program.
      assert {:ok, 0} = Saves.flush(dir: Path.join(base, "nothing-here"), sync: recorder())
      assert synced() == []
    end

    test "counts only the files it actually synced", %{saves: saves} do
      # One unsyncable file must not cost the flush of the save that matters,
      # and must not be counted as flushed either.
      File.write!(Path.join(saves, "a.srm"), "a")
      File.write!(Path.join(saves, "b.srm"), "b")

      sync = fn _handle ->
        if Process.put(:failed_once, true), do: :ok, else: {:error, :eio}
      end

      assert {:ok, 1} = Saves.flush(dir: saves, sync: sync)
    end

    test "directories are not opened", %{saves: saves} do
      # File.open/2 on a directory fails, so a listing that included them would
      # log a warning per subdirectory on every program exit -- which is how a
      # log stops being worth reading.
      File.mkdir_p!(Path.join(saves, "Snes9x 2010"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 0} = Saves.flush(dir: saves, sync: recorder())
        end)

      refute log =~ "could not open"
    end

    test "is capped, and it is the most recently written that make the cut", %{saves: saves} do
      # The cap bounds a flush that runs on the way back to the menu. Ordering
      # by mtime is what makes it safe rather than arbitrary: a file that could
      # still be dirty is one that was written recently, and the ones past the
      # cap were written in an earlier session and are long since on the card.
      for i <- 1..70 do
        path = Path.join(saves, "game#{i}.srm")
        File.write!(path, "game#{i}")
        File.touch!(path, {{2020, 1, 1}, {0, 0, 0}} |> shift(i))
      end

      assert {:ok, 64} = Saves.flush(dir: saves, sync: recorder())

      flushed = synced()
      assert "game70" in flushed
      assert "game7" in flushed
      refute "game6" in flushed
      refute "game1" in flushed
    end

    defp shift(datetime, seconds) do
      datetime
      |> NaiveDateTime.from_erl!()
      |> NaiveDateTime.add(seconds)
      |> NaiveDateTime.to_erl()
    end

    test "the handle it syncs cannot write to the save", %{saves: saves} do
      # An fsync needs a descriptor, not write access, and a mechanism that
      # exists to protect save files must not be able to damage one. The handle
      # is opened read-only, so a write through it is refused by the kernel.
      path = Path.join(saves, "a.srm")
      File.write!(path, "a")

      test = self()

      # Attempted while the handle is open, which is the only moment the
      # question means anything.
      sync = fn handle ->
        send(test, {:write, :file.write(handle, "clobbered")})
        :ok
      end

      Saves.flush(dir: saves, sync: sync)

      assert_received {:write, {:error, :ebadf}}
      assert File.read!(path) == "a"
    end
  end

  describe "dir/0" do
    test "defaults to saves beside RetroArch's own config" do
      assert Saves.dir() == Saves.default_dir()
      assert Path.basename(Saves.dir()) == "saves"
    end

    test "an explicit configuration wins over everything", %{base: base} do
      elsewhere = Path.join(base, "elsewhere")
      File.mkdir_p!(elsewhere)
      Application.put_env(:mayonnaios, :retroarch_save_dir, elsewhere)
      on_exit(fn -> Application.delete_env(:mayonnaios, :retroarch_save_dir) end)

      assert Saves.dir() == elsewhere
    end

    test "follows savefile_directory out of the player's config", %{base: base} do
      elsewhere = Path.join(base, "player-said-here")
      File.mkdir_p!(elsewhere)
      File.write!(config(), ~s(savefile_directory = "#{elsewhere}"\n))

      assert Saves.dir() == elsewhere
    end

    test "an appended file wins over the player's config, as RetroArch merges them",
         %{base: base} do
      # --appendconfig is merged over the main config, so the last file to set
      # the value is the one that decides where the saves actually go.
      player = Path.join(base, "player")
      appended = Path.join(base, "appended")
      File.mkdir_p!(player)
      File.mkdir_p!(appended)

      File.write!(config(), ~s(savefile_directory = "#{player}"\n))
      File.write!(MayonnaiOS.Cores.append_config(), ~s(savefile_directory = "#{appended}"\n))

      assert Saves.dir() == appended
    end

    test "the bundle's config is read too", %{base: base} do
      # The launcher appends it on every launch, and it is a separately
      # versioned artifact that has already been wrong about a directory once.
      elsewhere = Path.join(base, "bundle-said-here")
      File.mkdir_p!(elsewhere)

      cfg = Path.join([base, "bundles", "retroarch", "1.0.0", "share", "retroarch"])
      File.mkdir_p!(cfg)
      File.write!(Path.join(cfg, "retroarch.cfg"), ~s(savefile_directory = "#{elsewhere}"\n))

      File.ln_s!(
        Path.join([base, "bundles", "retroarch", "1.0.0"]),
        Path.join([base, "bundles", "retroarch", "current"])
      )

      assert Saves.dir() == elsewhere
    end

    test ~s(a value of "default" means RetroArch has no opinion) do
      File.write!(config(), ~s(savefile_directory = "default"\n))

      assert Saves.dir() == Saves.default_dir()
    end

    test "an empty value does not resolve to the working directory" do
      # This is the one that needs the name check rather than the directory
      # check: Path.expand("") is the cwd, which exists, so an empty setting
      # would otherwise be accepted and every flush would fsync whatever the
      # VM happens to be sitting in.
      File.write!(config(), ~s(savefile_directory = ""\n))

      assert Saves.dir() == Saves.default_dir()
    end

    test "a directory that does not exist is one RetroArch would drop too", %{base: base} do
      File.write!(config(), ~s(savefile_directory = "#{Path.join(base, "gone")}"\n))

      assert Saves.dir() == Saves.default_dir()
    end

    test "a config that says nothing about saves falls through" do
      File.write!(config(), ~s(video_driver = "gl"\nsavestate_directory = "/root/states"\n))

      assert Saves.dir() == Saves.default_dir()
    end

    defp config, do: MayonnaiOS.Cores.retroarch_config()
  end
end
