defmodule MayonnaiOS.FilesTest do
  # Not async: two tests here set :rom_roots to check that the roots come from
  # the library's, and `MayonnaiOS.LibraryRootsTest` sets the same key. The
  # application environment is one global, so a shared key is a shared
  # resource; a suite that passes except when it does not is worse than a
  # slower one.
  use ExUnit.Case, async: false

  alias MayonnaiOS.Files

  # Two roots, standing in for the internal card and the games card. Everything
  # here runs on the host: the boundary is arithmetic on names, and the writes
  # are the part that has already cost this project a set of ROMs, so both are
  # worth checking somewhere that does not need the device plugged in.

  setup do
    id = System.unique_integer([:positive])
    internal = Path.join(System.tmp_dir!(), "files-internal-#{id}")
    card = Path.join(System.tmp_dir!(), "files-card-#{id}")
    File.mkdir_p!(internal)
    File.mkdir_p!(card)

    Application.put_env(:mayonnaios, :file_roots, [
      %{key: "internal", path: internal, note: "games, and where uploads land"},
      %{key: "card", path: card, note: "games on another card"}
    ])

    on_exit(fn ->
      Application.delete_env(:mayonnaios, :file_roots)
      File.rm_rf(internal)
      File.rm_rf(card)
    end)

    %{internal: internal, card: card}
  end

  # Everything a request-shaped name could try. Each of these must be an
  # error, not a repair: `Path.basename/1` would turn most of them into
  # something harmless and leave nothing saying an escape was attempted.
  @rejected [
    "..",
    ".",
    "",
    "../bundles",
    "a/b",
    "/etc/shadow",
    "..\\bundles",
    <<"rom", 0, "boot">>,
    <<0xFF, 0xFE>>
  ]

  describe "the boundary" do
    test "a location is a root key and names, and resolves under that root", %{internal: internal} do
      assert {:ok, location} = Files.at("internal", ["snes", "game.sfc"])
      assert Files.resolve(location) == {:ok, Path.join([internal, "snes", "game.sfc"])}
    end

    test "an unknown root is an error, not a path" do
      assert Files.at("etc") == {:error, :unknown_root}
      assert Files.resolve(%{root: "etc", path: []}) == {:error, :unknown_root}
    end

    test "every name that could mean something other than itself is rejected" do
      for name <- @rejected do
        assert Files.at("internal", [name]) == {:error, :bad_name},
               "at/2 accepted #{inspect(name)}"

        {:ok, root} = Files.at("internal")

        assert Files.descend(root, name) == {:error, :bad_name},
               "descend/2 accepted #{inspect(name)}"
      end
    end

    test "a name longer than 200 bytes is rejected" do
      assert Files.at("internal", [String.duplicate("a", 201)]) == {:error, :bad_name}
      assert {:ok, _} = Files.at("internal", [String.duplicate("a", 200)])
    end

    test "a location assembled by hand is re-checked when it is resolved" do
      # The struct is a plain map, so nothing stops another module building
      # one. resolve/1 is where that stops mattering.
      assert Files.resolve(%{root: "internal", path: [".."]}) == {:error, :bad_name}
      assert Files.resolve(%{root: "internal", path: ["ok", "../.."]}) == {:error, :bad_name}
    end

    test "dotfiles are reachable, deliberately unlike the upload boundary" do
      # Library rejects a leading dot so an upload cannot land as a dotfile.
      # Here /root/.config/retroarch is one of the directories most worth
      # looking at, and hiding it would be a lie about what is on the disk.
      assert {:ok, location} = Files.at("internal", [".config", "retroarch"])
      assert {:ok, path} = Files.resolve(location)
      assert String.ends_with?(path, "/.config/retroarch")
    end

    test "ascend stops at the root rather than climbing out of it" do
      {:ok, deep} = Files.at("internal", ["a", "b"])
      assert %{path: ["a"]} = Files.ascend(deep)
      assert %{path: []} = deep |> Files.ascend() |> Files.ascend()
      assert Files.ascend(%{root: "internal", path: []}) == nil
    end

    test "a root itself is not an entry, so nothing can operate on one", %{internal: internal} do
      root = %{root: "internal", path: []}
      assert Files.basename(root) == {:error, :is_root}
      assert Files.delete(root) == {:error, :is_root}
      assert File.dir?(internal)
    end
  end

  describe "listing" do
    test "directories first, then names case-insensitively", %{internal: internal} do
      File.mkdir_p!(Path.join(internal, "snes"))
      File.mkdir_p!(Path.join(internal, "Arcade"))
      File.write!(Path.join(internal, "zelda.sfc"), "z")
      File.write!(Path.join(internal, "Chrono.sfc"), "c")

      {:ok, location} = Files.at("internal")
      assert {:ok, entries} = Files.list(location)

      assert Enum.map(entries, & &1.name) == ["Arcade", "snes", "Chrono.sfc", "zelda.sfc"]
    end

    test "sizes come from the file, and dotfiles are listed", %{internal: internal} do
      File.write!(Path.join(internal, "game.sfc"), String.duplicate("x", 42))
      File.mkdir_p!(Path.join(internal, ".config"))

      {:ok, location} = Files.at("internal")
      {:ok, entries} = Files.list(location)
      by_name = Map.new(entries, &{&1.name, &1})

      assert by_name["game.sfc"].size == 42
      assert by_name["game.sfc"].type == :regular
      assert by_name[".config"].type == :directory
    end

    test "a symlink says so, and a broken one says that", %{internal: internal} do
      File.write!(Path.join(internal, "real.so"), "elf")
      File.ln_s!(Path.join(internal, "real.so"), Path.join(internal, "good.so"))
      File.ln_s!(Path.join(internal, "gone.so"), Path.join(internal, "bad.so"))

      {:ok, location} = Files.at("internal")
      {:ok, entries} = Files.list(location)
      by_name = Map.new(entries, &{&1.name, &1})

      assert by_name["good.so"].link == Path.join(internal, "real.so")
      refute by_name["good.so"].broken?

      # This is the case that matters on the device: the core directory is
      # nothing but symlinks, and a dangling one looks like an installed core
      # to anything that only lists names.
      assert by_name["bad.so"].broken?
      assert by_name["bad.so"].type == :missing
    end

    test "a directory that is not there is an error to render, not a raise" do
      {:ok, location} = Files.at("internal", ["not-here"])
      assert Files.list(location) == {:error, :enoent}
    end
  end

  describe "copy" do
    setup %{internal: internal} do
      File.mkdir_p!(Path.join(internal, "snes"))
      File.mkdir_p!(Path.join(internal, "backup"))
      File.write!(Path.join([internal, "snes", "game.sfc"]), "rom bytes")

      {:ok, source} = Files.at("internal", ["snes", "game.sfc"])
      {:ok, dest} = Files.at("internal", ["backup"])
      %{source: source, dest: dest}
    end

    test "copies the bytes", %{source: source, dest: dest, internal: internal} do
      assert Files.copy(source, dest) == :ok
      assert File.read!(Path.join([internal, "backup", "game.sfc"])) == "rom bytes"
    end

    test "fsyncs the whole file, on an open handle, before the rename", ctx do
      %{source: source, dest: dest, internal: internal} = ctx
      final = Path.join([internal, "backup", "game.sfc"])
      test = self()

      sync = fn fd ->
        # Three things are asserted by taking them here rather than
        # afterwards. That the handle is still open -- :file.position answers
        # on an open fd and raises or errors on a closed one. That everything
        # was written first, because the position is the byte count. And that
        # the destination does not exist yet, so the sync happened while the
        # data was still in the .part file and before it was renamed into
        # place. A test that only looked at the file afterwards could not tell
        # a synced copy from an unsynced one: both are there until the power
        # goes, which is the failure this guards against.
        send(test, {:synced, :file.position(fd, :cur), File.exists?(final)})
        :file.sync(fd)
      end

      assert Files.copy(source, dest, sync: sync) == :ok

      assert_received {:synced, {:ok, 9}, false}
      assert File.read!(final) == "rom bytes"
      # And the .part file is gone, so the rename happened rather than a copy.
      refute File.exists?(final <> ".part")
    end

    test "refuses to overwrite", %{source: source, dest: dest, internal: internal} do
      File.write!(Path.join([internal, "backup", "game.sfc"]), "someone's save")

      assert Files.copy(source, dest) == {:error, :eexist}
      assert File.read!(Path.join([internal, "backup", "game.sfc"])) == "someone's save"
    end

    test "refuses a directory", %{dest: dest} do
      {:ok, source} = Files.at("internal", ["snes"])
      assert Files.copy(source, dest) == {:error, :eisdir}
    end

    test "refuses a symlink source, so a copy cannot read through one", ctx do
      %{internal: internal, dest: dest} = ctx
      File.ln_s!("/etc/hosts", Path.join([internal, "snes", "outside"]))

      {:ok, source} = Files.at("internal", ["snes", "outside"])
      assert Files.copy(source, dest) == {:error, :is_symlink}
    end

    test "copies across roots, which is what two cards are for", ctx do
      %{source: source, card: card} = ctx
      {:ok, dest} = Files.at("card")

      assert Files.copy(source, dest) == :ok
      assert File.read!(Path.join(card, "game.sfc")) == "rom bytes"
    end
  end

  describe "move" do
    setup %{internal: internal} do
      File.mkdir_p!(Path.join(internal, "snes"))
      File.mkdir_p!(Path.join(internal, "megadrive"))
      File.write!(Path.join([internal, "snes", "game.sfc"]), "rom bytes")

      {:ok, source} = Files.at("internal", ["snes", "game.sfc"])
      {:ok, dest} = Files.at("internal", ["megadrive"])
      %{source: source, dest: dest}
    end

    test "is a rename when it can be", %{source: source, dest: dest, internal: internal} do
      assert Files.move(source, dest) == :ok
      refute File.exists?(Path.join([internal, "snes", "game.sfc"]))
      assert File.read!(Path.join([internal, "megadrive", "game.sfc"])) == "rom bytes"
    end

    test "refuses to overwrite", %{source: source, dest: dest, internal: internal} do
      File.write!(Path.join([internal, "megadrive", "game.sfc"]), "not this one")

      assert Files.move(source, dest) == {:error, :eexist}
      assert File.exists?(Path.join([internal, "snes", "game.sfc"]))
    end

    test "across filesystems it copies, fsyncs and then removes the source", ctx do
      %{source: source, dest: dest, internal: internal} = ctx
      test = self()

      # A test cannot mount a second filesystem, so :exdev is injected. That
      # is the whole reason the seam exists: the cross-device path is the one
      # that writes bytes, and therefore the one that has to fsync them.
      assert Files.move(source, dest,
               rename: fn _from, _to -> {:error, :exdev} end,
               sync: fn fd ->
                 send(test, {:synced, :file.position(fd, :cur)})
                 :file.sync(fd)
               end
             ) == :ok

      assert_received {:synced, {:ok, 9}}
      refute File.exists?(Path.join([internal, "snes", "game.sfc"]))
      assert File.read!(Path.join([internal, "megadrive", "game.sfc"])) == "rom bytes"
    end

    test "a directory across filesystems is refused rather than copied", ctx do
      %{dest: dest, internal: internal} = ctx
      {:ok, source} = Files.at("internal", ["snes"])

      assert Files.move(source, dest, rename: fn _f, _t -> {:error, :exdev} end) ==
               {:error, :exdev}

      assert File.dir?(Path.join(internal, "snes"))
    end
  end

  describe "rename" do
    setup %{internal: internal} do
      File.write!(Path.join(internal, "game.sfc"), "rom")
      {:ok, source} = Files.at("internal", ["game.sfc"])
      %{source: source}
    end

    test "renames in place", %{source: source, internal: internal} do
      assert Files.rename(source, "zelda.sfc") == :ok
      assert File.read!(Path.join(internal, "zelda.sfc")) == "rom"
      refute File.exists?(Path.join(internal, "game.sfc"))
    end

    test "cannot become a move, because the new name goes through the boundary", ctx do
      %{source: source} = ctx

      for name <- @rejected do
        assert Files.rename(source, name) == {:error, :bad_name},
               "rename accepted #{inspect(name)}"
      end
    end

    test "refuses a name that is already taken", %{source: source, internal: internal} do
      File.write!(Path.join(internal, "taken.sfc"), "someone else")

      assert Files.rename(source, "taken.sfc") == {:error, :eexist}
      assert File.read!(Path.join(internal, "taken.sfc")) == "someone else"
    end
  end

  describe "delete" do
    test "removes a file", %{internal: internal} do
      File.write!(Path.join(internal, "game.sfc"), "rom")
      {:ok, location} = Files.at("internal", ["game.sfc"])

      assert Files.delete(location) == :ok
      refute File.exists?(Path.join(internal, "game.sfc"))
    end

    test "removes the link and not what it points at", %{internal: internal} do
      real = Path.join(internal, "real.so")
      File.write!(real, "elf")
      File.ln_s!(real, Path.join(internal, "core.so"))

      {:ok, location} = Files.at("internal", ["core.so"])
      assert Files.delete(location) == :ok

      refute File.exists?(Path.join(internal, "core.so"))
      assert File.read!(real) == "elf"
    end

    test "removes an empty directory", %{internal: internal} do
      File.mkdir_p!(Path.join(internal, "empty"))
      {:ok, location} = Files.at("internal", ["empty"])

      assert Files.delete(location) == :ok
      refute File.exists?(Path.join(internal, "empty"))
    end

    test "will not remove a directory with anything in it", %{internal: internal} do
      File.mkdir_p!(Path.join(internal, "snes"))
      File.write!(Path.join([internal, "snes", "game.sfc"]), "rom")

      {:ok, location} = Files.at("internal", ["snes"])
      assert Files.delete(location) == {:error, :not_empty}
      assert File.exists?(Path.join([internal, "snes", "game.sfc"]))
    end

    test "a name that could mean something else deletes nothing" do
      for name <- @rejected do
        {:ok, root} = Files.at("internal")
        assert Files.descend(root, name) == {:error, :bad_name}
      end
    end
  end

  describe "space" do
    test "reports the filesystem holding a location", %{internal: internal} do
      {:ok, location} = Files.at("internal")

      assert %{device: device, free: free, total: total} = Files.space(location)
      assert is_binary(device)
      assert free > 0
      assert total >= free
      # The same numbers as the path, because the location is the path.
      assert Files.space(internal).total == total
    end

    test "is nil rather than a guess when there is nothing to measure" do
      assert Files.space(%{root: "etc", path: []}) == nil
      assert Files.space("/definitely/not/here") == nil
    end

    test "the library's free space is now the same measurement" do
      # One df parse in this application, not two. Library.free_bytes/0 is the
      # older caller and the web page reads it.
      on_exit(fn -> Application.delete_env(:mayonnaios, :rom_roots) end)
      Application.put_env(:mayonnaios, :rom_roots, [System.tmp_dir!()])

      # A delta, not equality: these are two calls to df a millisecond apart,
      # and the rest of this suite is writing temporary files to the same
      # filesystem. Asserting the two numbers were identical made this test
      # fail on the difference between two moments rather than on the thing
      # it is about.
      assert_in_delta MayonnaiOS.Library.free_bytes(),
                      Files.space(System.tmp_dir!()).free,
                      64 * 1024 * 1024

      # And the same nil from the same parse when there is nothing to measure.
      Application.put_env(:mayonnaios, :rom_roots, ["/definitely/not/here"])
      assert MayonnaiOS.Library.free_bytes() == nil
    end
  end

  describe "the configured roots" do
    test "come from the library's roots, so the two cannot disagree" do
      Application.delete_env(:mayonnaios, :file_roots)

      Application.put_env(:mayonnaios, :rom_roots, ["/root/ROMS", "/root/mnt/games/ROMS"])
      on_exit(fn -> Application.delete_env(:mayonnaios, :rom_roots) end)

      paths = Enum.map(Files.places(), & &1.path)

      assert "/root/ROMS" in paths
      assert "/root/mnt/games/ROMS" in paths
      assert "/root" in paths
      # The whole filesystem is browsable from its own root.
      assert "/" in paths
    end
  end
end
