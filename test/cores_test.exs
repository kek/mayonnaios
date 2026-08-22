defmodule MayonnaiOS.CoresTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Cores

  # The interesting behaviour is `sync/0`, and specifically that it *clears*
  # before it links. A core that was uninstalled, or that went away with a
  # RetroArch upgrade, must not survive as a dangling symlink: RetroArch lists
  # the directory and would offer it, then fail at dlopen with an error about
  # a file rather than about an install.

  setup do
    base = Path.join(System.tmp_dir!(), "cores-test-#{System.unique_integer([:positive])}")
    bundles = Path.join(base, "bundles")
    core_root = Path.join(base, "cores")
    core_dir = Path.join(base, "active")
    File.mkdir_p!(core_dir)

    prev = %{
      bundle_root: Application.get_env(:mayonnaios, :bundle_root),
      core_root: Application.get_env(:mayonnaios, :core_root),
      core_dir: Application.get_env(:mayonnaios, :core_dir),
      retroarch_append_config: Application.get_env(:mayonnaios, :retroarch_append_config),
      cores: Application.get_env(:mayonnaios, :cores)
    }

    Application.put_env(:mayonnaios, :bundle_root, bundles)
    Application.put_env(:mayonnaios, :core_root, core_root)
    Application.put_env(:mayonnaios, :core_dir, core_dir)
    Application.put_env(:mayonnaios, :retroarch_append_config, Path.join(base, "mayonnaios.cfg"))
    Application.put_env(:mayonnaios, :cores, %{})

    on_exit(fn ->
      File.rm_rf(base)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:mayonnaios, k)
        {k, v} -> Application.put_env(:mayonnaios, k, v)
      end)
    end)

    %{bundles: bundles, core_root: core_root, core_dir: core_dir, base: base}
  end

  # A bundle as it looks once installed: a version directory and a `current`
  # symlink pointing at it, which is what Bundle.publish/3 leaves behind.
  defp install_retroarch(bundles, version, cores) do
    dir = Path.join([bundles, "retroarch", version, "lib", "libretro"])
    File.mkdir_p!(dir)
    Enum.each(cores, &File.write!(Path.join(dir, "#{&1}_libretro.so"), "so"))
    link_current(Path.join([bundles, "retroarch"]), version)
  end

  defp install_core(core_root, name, version) do
    dir = Path.join([core_root, name, version])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}_libretro.so"), "so")
    link_current(Path.join(core_root, name), version)
  end

  defp link_current(parent, version) do
    current = Path.join(parent, "current")
    File.rm(current)
    File.ln_s!(Path.join(parent, version), current)
  end

  test "an empty device syncs to an empty directory, and that is not an error", %{
    core_dir: core_dir
  } do
    assert Cores.sync() == []
    assert File.dir?(core_dir)
  end

  test "picks up the cores the RetroArch bundle ships", %{bundles: bundles} do
    install_retroarch(bundles, "1.22.2", ["2048", "snes9x2010"])

    assert Cores.sync() == ["2048_libretro.so", "snes9x2010_libretro.so"]
  end

  test "picks up separately installed cores", %{bundles: bundles, core_root: core_root} do
    install_retroarch(bundles, "1.22.2", ["2048"])
    install_core(core_root, "gambatte", "0.5.0")

    Application.put_env(:mayonnaios, :cores, %{
      gambatte: %{name: "gambatte", version: "0.5.0", url: "x", sha256: "y"}
    })

    assert Cores.sync() == ["2048_libretro.so", "gambatte_libretro.so"]
  end

  test "the links resolve to real files", %{bundles: bundles, core_dir: core_dir} do
    install_retroarch(bundles, "1.22.2", ["2048"])
    Cores.sync()

    path = Path.join(core_dir, "2048_libretro.so")
    assert File.read!(path) == "so"
  end

  test "a core installed by hand survives a RetroArch upgrade", %{
    bundles: bundles,
    core_root: core_root
  } do
    install_retroarch(bundles, "1.22.2", ["2048"])
    install_core(core_root, "snes9x2010", "1.22.2")

    Application.put_env(:mayonnaios, :cores, %{
      snes9x2010: %{name: "snes9x2010", version: "1.22.2", url: "x", sha256: "y"}
    })

    assert Cores.sync() == ["2048_libretro.so", "snes9x2010_libretro.so"]

    # The upgrade: a new version directory, `current` moved. This is the case
    # that loses a hand-copied core when libretro_directory points inside the
    # bundle, which is the whole reason this module exists.
    install_retroarch(bundles, "1.23.0", ["2048"])

    assert Cores.sync() == ["2048_libretro.so", "snes9x2010_libretro.so"]
  end

  test "sync clears a core that is no longer anywhere", %{bundles: bundles, core_dir: core_dir} do
    install_retroarch(bundles, "1.22.2", ["2048", "doomed"])
    assert "doomed_libretro.so" in Cores.sync()

    install_retroarch(bundles, "1.23.0", ["2048"])

    assert Cores.sync() == ["2048_libretro.so"]
    refute File.exists?(Path.join(core_dir, "doomed_libretro.so"))
  end

  test "sync is idempotent", %{bundles: bundles} do
    install_retroarch(bundles, "1.22.2", ["2048"])

    assert Cores.sync() == Cores.sync()
  end

  test "list reports installed and available separately", %{bundles: bundles} do
    install_retroarch(bundles, "1.22.2", ["2048"])

    Application.put_env(:mayonnaios, :cores, %{
      "2048": %{name: "2048", version: "9.9", url: "x", sha256: "y", label: "2048"},
      gambatte: %{name: "gambatte", version: "0.5.0", url: "x", sha256: "y", label: "Game Boy"}
    })

    Cores.sync()
    by_key = Map.new(Cores.list(), &{&1.key, &1})

    # 2048 comes from the RetroArch bundle: usable, but not installed as its
    # own bundle -- and the catalogue entry claims a version that is not what
    # is there. Those are genuinely different facts and the UI needs both.
    assert by_key["2048"].available
    refute by_key["2048"].installed

    refute by_key["gambatte"].available
    refute by_key["gambatte"].installed
  end

  test "list also reports a core that is present but not catalogued", %{bundles: bundles} do
    install_retroarch(bundles, "1.22.2", ["2048", "snes9x2010"])
    Cores.sync()

    by_key = Map.new(Cores.list(), &{&1.key, &1})

    # Neither is in the catalogue, and both work. A UI shown only the
    # catalogue would say a core someone is already playing games with is not
    # there, and offer to install it.
    assert by_key["2048"].available
    assert by_key["snes9x2010"].available
    refute by_key["snes9x2010"].installed

    # And no version is claimed, because nothing here read one. The .so does
    # not carry one and taking the bundle's would be a statement about
    # something this function did not look at.
    assert by_key["snes9x2010"].version == nil
  end

  test "installing an uncatalogued core is refused rather than attempted" do
    assert {:error, :unknown_core} = Cores.install("nonesuch")
  end

  # RetroArch does not validate `libretro_directory` the way it validates the
  # save directories -- it takes the value verbatim -- and it persists whatever
  # `--appendconfig` supplied as though the player had set it. So a value
  # naming a directory nothing fills survives the bundle that introduced it,
  # and shows up as a console with no cores and no warning about why. These
  # tests are about taking it back out.
  describe "clear_stale_directory/0" do
    setup %{core_dir: core_dir} do
      cfg = Path.join(Path.dirname(core_dir), "retroarch.cfg")
      prev = Application.get_env(:mayonnaios, :retroarch_config)
      Application.put_env(:mayonnaios, :retroarch_config, cfg)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:mayonnaios, :retroarch_config, prev),
          else: Application.delete_env(:mayonnaios, :retroarch_config)
      end)

      %{cfg: cfg}
    end

    test "removes a value naming somewhere else, and leaves the rest alone", %{cfg: cfg} do
      File.write!(cfg, """
      video_driver = "gl"
      libretro_directory = "/root/retroarch/cores"
      menu_driver = "rgui"
      """)

      assert {:ok, {:cleared, ["/root/retroarch/cores"]}} = Cores.clear_stale_directory()

      after_ = File.read!(cfg)
      refute after_ =~ "libretro_directory"
      assert after_ =~ ~s(video_driver = "gl")
      assert after_ =~ ~s(menu_driver = "rgui")
    end

    test "leaves a value that already names the core directory", %{cfg: cfg, core_dir: dir} do
      # RetroArch writes this itself once nothing overrides the default.
      # Removing it every boot would be churn, and would make the file
      # disagree with the program for no reason.
      File.write!(cfg, ~s(libretro_directory = "#{dir}"\n))

      assert {:ok, :unchanged} = Cores.clear_stale_directory()
      assert File.read!(cfg) =~ "libretro_directory"
    end

    test "compares expanded paths, because RetroArch saves ~ for the home dir",
         %{cfg: cfg} do
      # The saved form of the default is never string-equal to the absolute
      # path this module uses, so a naive comparison would strip a correct
      # value on every boot.
      home = System.user_home!()
      Application.put_env(:mayonnaios, :core_dir, Path.join(home, ".config/retroarch/cores"))
      File.write!(cfg, ~s(libretro_directory = "~/.config/retroarch/cores"\n))

      assert {:ok, :unchanged} = Cores.clear_stale_directory()
    end

    test "no config at all is not a failure", %{cfg: cfg} do
      refute File.exists?(cfg)
      # A freshly flashed device: RetroArch has never run, so there is nothing
      # to correct and nothing wrong.
      assert {:ok, :no_config} = Cores.clear_stale_directory()
    end

    test "an unquoted value is recognised too", %{cfg: cfg} do
      File.write!(cfg, "libretro_directory = /somewhere/else\n")
      assert {:ok, {:cleared, ["/somewhere/else"]}} = Cores.clear_stale_directory()
    end

    test "a key that merely contains the name is left alone", %{cfg: cfg} do
      # `content_show_contentless_cores`, `core_updater_buildbot_cores_url` and
      # friends are all in that file. Matching loosely would corrupt it.
      contents = """
      core_assets_directory = "~/.config/retroarch/downloads"
      libretro_info_path = "~/bundles/retroarch/current/share/retroarch/info"
      libretro_log_level = "1"
      """

      File.write!(cfg, contents)
      assert {:ok, :unchanged} = Cores.clear_stale_directory()
      assert File.read!(cfg) == contents
    end

    test "the rewrite leaves no temporary file behind", %{cfg: cfg} do
      File.write!(cfg, ~s(libretro_directory = "/gone"\n))
      assert {:ok, {:cleared, _}} = Cores.clear_stale_directory()
      refute File.exists?(cfg <> ".mayonnaios")
    end
  end

  describe "write_append_config/0" do
    # The bundle's own config sets libretro_directory and the launcher appends
    # it on every launch, so boot-time repair loses to launch-time damage. This
    # file is appended after the bundle's and has the last word.

    test "names the directory the symlinks go into", %{core_dir: core_dir} do
      assert :ok = Cores.write_append_config()

      assert File.read!(Cores.append_config()) =~
               ~s(libretro_directory = "#{core_dir}"\n)
    end

    test "turns SRAM autosave on, because off is what lost a save" do
      # The device was found with autosave_interval = "0": the .srm is then
      # written only when content closes cleanly, so every kill and every
      # pulled power cable discards the session.
      assert :ok = Cores.write_append_config()

      assert File.read!(Cores.append_config()) =~
               ~s(autosave_interval = "#{Cores.autosave_interval()}")

      refute Cores.autosave_interval() == 0
    end

    test "the interval travels rather than being written twice" do
      Application.put_env(:mayonnaios, :retroarch_autosave_interval, 42)
      on_exit(fn -> Application.delete_env(:mayonnaios, :retroarch_autosave_interval) end)

      Cores.write_append_config()

      assert File.read!(Cores.append_config()) =~ ~s(autosave_interval = "42")
    end

    test "follows core_dir rather than repeating it", %{base: base} do
      moved = Path.join(base, "somewhere-else")
      Application.put_env(:mayonnaios, :core_dir, moved)

      Cores.write_append_config()

      assert File.read!(Cores.append_config()) =~ moved
    end

    test "creates the directory it writes into", %{base: base} do
      nested = Path.join([base, "not", "there", "yet", "mayonnaios.cfg"])
      Application.put_env(:mayonnaios, :retroarch_append_config, nested)

      assert :ok = Cores.write_append_config()
      assert File.exists?(nested)
    end

    test "the value it writes is one clear_stale_directory/0 leaves alone", %{
      core_dir: core_dir,
      base: base
    } do
      # The two have to agree, or every launch would write a value the next
      # boot strips out again -- which is the loop this whole arrangement
      # exists to end.
      config = Path.join(base, "retroarch.cfg")
      File.write!(config, ~s(libretro_directory = "#{core_dir}"\n))

      Cores.clear_stale_directory(config)

      assert File.read!(config) =~ "libretro_directory"
    end

    test "is written at boot, before anything launches", %{core_dir: core_dir} do
      Cores.Startup.run()

      assert File.read!(Cores.append_config()) =~ core_dir
    end
  end

  # The autosave setting is asserted in the appended file and scrubbed out of
  # the player's own config, and it is the scrub that makes it retractable: a
  # value RetroArch persisted on exit is indistinguishable from one the player
  # chose, so without this, `autosave_interval = "0"` would outlive every file
  # that ever set it -- which is precisely what libretro_directory did.
  describe "clear_persisted_autosave/0" do
    setup %{core_dir: core_dir} do
      cfg = Path.join(Path.dirname(core_dir), "retroarch.cfg")
      prev = Application.get_env(:mayonnaios, :retroarch_config)
      Application.put_env(:mayonnaios, :retroarch_config, cfg)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:mayonnaios, :retroarch_config, prev),
          else: Application.delete_env(:mayonnaios, :retroarch_config)
      end)

      %{cfg: cfg}
    end

    test "removes the value that lost the save, and leaves the rest alone", %{cfg: cfg} do
      File.write!(cfg, """
      video_driver = "gl"
      autosave_interval = "0"
      menu_driver = "rgui"
      """)

      assert {:ok, {:cleared, ["0"]}} = Cores.clear_persisted_autosave()

      after_ = File.read!(cfg)
      refute after_ =~ "autosave_interval"
      assert after_ =~ ~s(video_driver = "gl")
      assert after_ =~ ~s(menu_driver = "rgui")
    end

    test "removes the value this firmware itself asks for", %{cfg: cfg} do
      # Unconditional on purpose, and this is the case that proves it. The
      # value that decides a launch is the one in the appended file, merged
      # last on every launch; the copy in the player's config is a fossil even
      # when it agrees. Leaving agreeing values would mean a later change of
      # mind could not take them back.
      File.write!(cfg, ~s(autosave_interval = "#{Cores.autosave_interval()}"\n))

      assert {:ok, {:cleared, _}} = Cores.clear_persisted_autosave()
      refute File.read!(cfg) =~ "autosave_interval"
    end

    test "a key that merely looks similar is left alone", %{cfg: cfg} do
      contents = """
      savestate_auto_save = "false"
      autosave_interval_unrelated = "5"
      video_driver = "gl"
      """

      File.write!(cfg, contents)
      assert {:ok, :unchanged} = Cores.clear_persisted_autosave()
      assert File.read!(cfg) == contents
    end

    test "no config at all is not a failure", %{cfg: cfg} do
      refute File.exists?(cfg)
      assert {:ok, :no_config} = Cores.clear_persisted_autosave()
    end

    test "the rewrite leaves no temporary file behind", %{cfg: cfg} do
      File.write!(cfg, ~s(autosave_interval = "0"\n))
      assert {:ok, {:cleared, _}} = Cores.clear_persisted_autosave()
      refute File.exists?(cfg <> ".mayonnaios")
    end

    test "boot scrubs the fossil and writes the setting again", %{cfg: cfg} do
      # The pair, in the order the device runs it. Without the scrub half, a
      # device that has ever run RetroArch keeps whatever it persisted and no
      # later firmware can withdraw it.
      File.write!(cfg, ~s(autosave_interval = "0"\n))

      Cores.Startup.run()

      refute File.read!(cfg) =~ "autosave_interval"

      assert File.read!(Cores.append_config()) =~
               ~s(autosave_interval = "#{Cores.autosave_interval()}")
    end
  end
end
