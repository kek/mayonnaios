defmodule MayonnaiOS.HostRuntimeTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.{HostRuntime, Programs}

  setup do
    root = Path.join(System.tmp_dir!(), "host-runtime-#{System.unique_integer([:positive])}")
    files = Path.join(root, "files")
    pickles = Path.join(root, "pickles")
    backlight = Path.join(root, "brightness")
    previous_pickles = Application.get_env(:mayonnaios, :pickles_root)

    Application.put_env(:mayonnaios, :pickles_root, pickles)

    on_exit(fn ->
      Application.put_env(:mayonnaios, :pickles_root, previous_pickles)
      File.rm_rf(root)
    end)

    %{files: files, pickles: pickles, backlight: backlight}
  end

  test "prepares safe writable state and a graphical Luerl example", context do
    assert :ok =
             HostRuntime.prepare(%{
               files: context.files,
               pickles: context.pickles,
               backlight: context.backlight,
               example: Path.expand("pickles/hello")
             })

    assert File.exists?(Path.join(context.files, "README.txt"))
    assert File.read!(context.backlight) == "1"
    assert File.exists?(Path.join([context.pickles, "hello", "pickle.json"]))
    assert File.exists?(Path.join([context.pickles, "hello", "main.lua"]))

    programs = Programs.list()
    assert Enum.any?(programs, &(&1.name == "Host program (launcher handoff)" and &1.installed?))
    assert Enum.any?(programs, &(&1.app == {MayonnaiOS.Top, :beam}))
    assert Enum.any?(programs, &(&1.app == {MayonnaiOS.Pickles.App, "hello"}))
  end

  test "dev children use the real launcher and keyboard controller bridge" do
    assert HostRuntime.children() == [
             MayonnaiOS.HostRuntime,
             MayonnaiOS.Web,
             MayonnaiOS.Launcher,
             MayonnaiOS.Keyboard
           ]

    # The test environment remains headless for CI.
    refute Application.get_env(:mayonnaios, :host_runtime)
    refute Application.get_env(:mayonnaios, :autostart_ui)
  end
end
