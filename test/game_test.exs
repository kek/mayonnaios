defmodule MayonnaiOS.GameTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Browser, Game, Launcher, Panel}

  setup do
    root = Path.join(System.tmp_dir!(), "game-test-#{System.unique_integer([:positive])}")
    core_dir = Path.join(root, "cores")
    rom_root = Path.join(root, "roms")
    retroarch = Path.join(root, "retroarch")
    File.mkdir_p!(core_dir)
    File.mkdir_p!(Path.join(rom_root, "snes"))
    File.write!(Path.join(core_dir, "fake_libretro.so"), "core")
    File.write!(Path.join(rom_root, "snes/chrono.sfc"), "rom")
    File.write!(retroarch, "#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 3\n")
    File.chmod!(retroarch, 0o755)

    pickles_root = Path.join(root, "pickles")
    File.mkdir_p!(pickles_root)

    keys = [
      :systems,
      :rom_roots,
      :file_roots,
      :cores,
      :core_dir,
      :core_root,
      :core_priority,
      :programs,
      :pickles_root
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:mayonnaios, &1)})

    Application.put_env(:mayonnaios, :systems, [
      %{key: "snes", name: "Super Nintendo", extensions: [".sfc"]}
    ])

    Application.put_env(:mayonnaios, :rom_roots, [rom_root])

    Application.put_env(:mayonnaios, :file_roots, [
      %{key: "roms", path: Path.join(rom_root, "snes"), note: "test ROMs"}
    ])

    Application.put_env(:mayonnaios, :core_dir, core_dir)
    Application.put_env(:mayonnaios, :core_root, Path.join(root, "core-bundles"))
    Application.put_env(:mayonnaios, :core_priority, [:fake])
    Application.put_env(:mayonnaios, :pickles_root, pickles_root)

    Application.put_env(:mayonnaios, :cores, %{
      fake: %{name: "fake", label: "Fake Core", systems: ["snes"], version: "1"}
    })

    Application.put_env(:mayonnaios, :programs, [
      %{
        name: "RetroArch",
        path: retroarch,
        args: ["--appendconfig", "shared.cfg"],
        needs_udev: true
      },
      %{name: "Moonlight", path: "/nonexistent/moonlight"}
    ])

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:mayonnaios, key)
        {key, value} -> Application.put_env(:mayonnaios, key, value)
      end)

      File.rm_rf(root)
      Panel.release()
    end)

    %{
      core: Path.join(core_dir, "fake_libretro.so"),
      retroarch: retroarch,
      rom: Path.join(rom_root, "snes/chrono.sfc")
    }
  end

  test "Games browses systems and merged library ROMs" do
    games = Browser.new() |> Browser.descend()
    assert Browser.selected(games).name == "Super Nintendo"

    roms = Browser.descend(games)
    assert %{kind: :rom, name: "chrono.sfc", system: "snes"} = Browser.selected(roms)
  end

  test "previewing a system ignores regular files that are not ROMs", context do
    File.write!(Path.join(Path.dirname(context.rom), "notes.txt"), "not a ROM")

    games = Browser.new() |> Browser.descend()
    assert Browser.selected(games).name == "Super Nintendo"

    assert %{kind: :level, level: %{entries: [entry]}} = Browser.preview(games)
    assert %{kind: :rom, name: "chrono.sfc", system: "snes"} = entry
  end

  test "builds a direct RetroArch launch from the first available matching core", context do
    assert {:ok, program} = Game.program("snes", context.rom)
    assert program.path == context.retroarch
    assert program.needs_udev
    assert program.args == ["--appendconfig", "shared.cfg", "-L", context.core, context.rom]
  end

  test "A on a library ROM uses the ordinary external-program path", context do
    start_supervised!({Launcher, device: "/nonexistent/event0"})

    # Games -> Super Nintendo -> chrono.sfc -> launch.
    Launcher.launch()
    Launcher.launch()
    Launcher.launch()

    assert eventually(fn -> Launcher.obituary() end)
    assert %{status: 3, lines: lines} = Launcher.obituary()
    assert "-L" in lines
    assert context.core in lines
    assert context.rom in lines
  end

  test "A on a recognized ROM in Files launches it too", context do
    start_supervised!({Launcher, device: "/nonexistent/event0"})

    send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, :btn_dpad_down, 1}]})
    Launcher.selected()
    Launcher.launch()
    Launcher.launch()
    Launcher.launch()

    assert eventually(fn -> Launcher.obituary() end)
    assert %{lines: lines} = Launcher.obituary()
    assert context.core in lines
    assert context.rom in lines
  end

  test "external programs move to Apps when Games is a library" do
    apps = Browser.new() |> Browser.move(2) |> Browser.descend()
    assert Enum.map(Browser.focused(apps).entries, & &1.name) == ["RetroArch", "Moonlight"]
  end

  test "a recognized extension and missing core are explicit" do
    assert Game.system_for("anything.sfc").key == "snes"
    File.rm!(Path.join(Application.fetch_env!(:mayonnaios, :core_dir), "fake_libretro.so"))
    assert Game.program("snes", "/tmp/chrono.sfc") == {:error, :no_core}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    case fun.() do
      nil -> Process.sleep(10) && eventually(fun, attempts - 1)
      value -> value
    end
  end
end
