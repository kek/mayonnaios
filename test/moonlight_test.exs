defmodule MayonnaiOS.MoonlightTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Moonlight

  # The property that matters here is that editing a config file is *editing*
  # it: a key this screen does not offer must survive being saved over, and a
  # comment must still be there afterwards. Everything else is arithmetic.

  setup do
    base = Path.join(System.tmp_dir!(), "moonlight-test-#{System.unique_integer([:positive])}")
    bundles = Path.join(base, "bundles")
    config = Path.join([base, "config", "moonlight.conf"])
    File.mkdir_p!(base)

    prev = %{
      bundle_root: Application.get_env(:mayonnaios, :bundle_root),
      moonlight_config: Application.get_env(:mayonnaios, :moonlight_config)
    }

    Application.put_env(:mayonnaios, :bundle_root, bundles)
    Application.put_env(:mayonnaios, :moonlight_config, config)

    on_exit(fn ->
      File.rm_rf(base)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:mayonnaios, k)
        {k, v} -> Application.put_env(:mayonnaios, k, v)
      end)
    end)

    %{base: base, bundles: bundles, config: config}
  end

  # A bundle as it looks once installed: a version directory and a `current`
  # symlink pointing at it, which is what Bundle.publish/3 leaves behind.
  defp install_moonlight(bundles, template \\ nil) do
    dir = Path.join([bundles, "moonlight", "2.7.1"])
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join([dir, "bin", "moonlight"]), "elf")

    if template do
      File.mkdir_p!(Path.join([dir, "share", "moonlight"]))
      File.write!(Path.join([dir, "share", "moonlight", "moonlight.conf"]), template)
    end

    File.ln_s!(dir, Path.join([bundles, "moonlight", "current"]))
    dir
  end

  describe "parse/1" do
    test "reads the keys the screen owns" do
      settings =
        Moonlight.parse("""
        address = 192.168.1.10
        width = 1920
        height = 1080
        fps = 60
        bitrate = 20000
        codec = hevc
        app = Desktop
        """)

      assert settings == %{
               address: "192.168.1.10",
               resolution: "1920x1080",
               fps: "60",
               bitrate: "20000",
               codec: "hevc",
               app: "Desktop"
             }
    end

    test "anything absent keeps its default" do
      assert Moonlight.parse("address = host.lan") ==
               Map.put(Moonlight.defaults(), :address, "host.lan")
    end

    test "comments are not keys" do
      assert Moonlight.parse("## address = 10.0.0.1").address == ""
    end

    test "a width with no height is not a resolution" do
      settings = Moonlight.parse("width = 1920")
      assert settings.resolution == Moonlight.defaults().resolution
    end

    test "whitespace around the separator is allowed, as Moonlight's own parser allows it" do
      assert Moonlight.parse("fps=60").fps == "60"
      assert Moonlight.parse("  bitrate   =   3000  ").bitrate == "3000"
    end
  end

  describe "render/2" do
    test "replaces a value where it already is" do
      text = "width = 1280\nheight = 720\nfps = 30\n"
      settings = Map.merge(Moonlight.defaults(), %{fps: "60"})

      assert Moonlight.render(text, settings) =~ "fps = 60"
      refute Moonlight.render(text, settings) =~ "fps = 30"
    end

    test "keeps comments, blank lines and keys the screen does not offer" do
      text = """
      ## Hardware notes worth keeping.

      platform = sdl
      surround = 5.1
      rotate = 90
      fps = 30
      """

      rendered = Moonlight.render(text, Map.put(Moonlight.defaults(), :fps, "60"))

      assert rendered =~ "## Hardware notes worth keeping."
      assert rendered =~ "platform = sdl"
      assert rendered =~ "surround = 5.1"
      assert rendered =~ "rotate = 90"
      assert rendered =~ "fps = 60"
    end

    test "appends a key the file does not have yet" do
      rendered =
        Moonlight.render("platform = sdl\n", Map.put(Moonlight.defaults(), :address, "10.0.0.5"))

      assert rendered =~ "address = 10.0.0.5"
      assert rendered =~ "platform = sdl"
    end

    test "a cleared value removes its line rather than writing it empty" do
      text = "address = 10.0.0.5\napp = Desktop\n"
      settings = Map.merge(Moonlight.defaults(), %{address: "10.0.0.5", app: ""})
      rendered = Moonlight.render(text, settings)

      refute rendered =~ "app"
      assert rendered =~ "address = 10.0.0.5"
    end

    test "one resolution row is two keys" do
      rendered =
        Moonlight.render(
          "platform = sdl\n",
          Map.put(Moonlight.defaults(), :resolution, "640x480")
        )

      assert rendered =~ "width = 640"
      assert rendered =~ "height = 480"
    end

    test "rendering twice is rendering once" do
      settings = Map.merge(Moonlight.defaults(), %{address: "10.0.0.5", fps: "60"})
      once = Moonlight.render("platform = sdl\n", settings)

      assert Moonlight.render(once, settings) == once
    end

    test "what was rendered is what parses back" do
      settings = Map.merge(Moonlight.defaults(), %{address: "host.lan", resolution: "1920x1080"})

      assert "platform = sdl\n" |> Moonlight.render(settings) |> Moonlight.parse() == settings
    end
  end

  describe "save/1" do
    test "creates the directory and writes the file", %{config: config} do
      refute File.exists?(config)

      assert {:ok, ^config} = Moonlight.save(Map.put(Moonlight.defaults(), :address, "10.0.0.5"))
      assert File.read!(config) =~ "address = 10.0.0.5"
    end

    test "seeds from the bundle's template when there is no file yet", %{
      bundles: bundles,
      config: config
    } do
      install_moonlight(bundles, "## the bundle's own notes\nplatform = sdl\nfps = 30\n")

      assert {:ok, ^config} = Moonlight.save(Map.put(Moonlight.defaults(), :address, "10.0.0.5"))

      written = File.read!(config)
      assert written =~ "## the bundle's own notes"
      assert written =~ "platform = sdl"
      assert written =~ "address = 10.0.0.5"
    end

    test "with no bundle and no file there is still something to write", %{config: config} do
      assert {:ok, ^config} = Moonlight.save(Moonlight.defaults())
      assert File.read!(config) =~ "platform = sdl"
    end

    test "a second save edits the first rather than starting again", %{config: config} do
      {:ok, _} = Moonlight.save(Map.put(Moonlight.defaults(), :address, "10.0.0.5"))
      File.write!(config, File.read!(config) <> "rotate = 90\n")

      {:ok, _} = Moonlight.save(Map.merge(Moonlight.defaults(), %{address: "10.0.0.6"}))

      written = File.read!(config)
      assert written =~ "address = 10.0.0.6"
      refute written =~ "10.0.0.5"
      assert written =~ "rotate = 90"
    end

    test "a directory that cannot be created is an error, not an exception", %{base: base} do
      blocked = Path.join(base, "blocked")
      File.write!(blocked, "not a directory")
      Application.put_env(:mayonnaios, :moonlight_config, Path.join([blocked, "x", "m.conf"]))

      assert {:error, _reason} = Moonlight.save(Moonlight.defaults())
    end
  end

  describe "load/1" do
    test "says where the values came from", %{bundles: bundles, config: config} do
      assert {settings, :defaults} = Moonlight.load()
      assert settings == Moonlight.defaults()

      install_moonlight(bundles, "fps = 60\n")
      assert {%{fps: "60"}, :template} = Moonlight.load()

      File.mkdir_p!(Path.dirname(config))
      File.write!(config, "fps = 30\naddress = saved.lan\n")
      assert {%{fps: "30", address: "saved.lan"}, :file} = Moonlight.load()
    end
  end

  describe "installed?/0" do
    test "is the binary, not the directory", %{bundles: bundles} do
      refute Moonlight.installed?()

      install_moonlight(bundles)
      assert Moonlight.installed?()
    end
  end

  describe "choices/2 and step/3" do
    defp field(id), do: Enum.find(Moonlight.fields(), &(&1.id == id))

    test "a value the screen does not offer is kept in the list" do
      settings = Map.put(Moonlight.defaults(), :resolution, "1600x900")

      assert "1600x900" in Moonlight.choices(field(:resolution), settings)
    end

    test "stepping wraps" do
      settings = Map.put(Moonlight.defaults(), :fps, "60")

      assert Moonlight.step(field(:fps), settings, +1).fps == "30"
      assert Moonlight.step(field(:fps), settings, -1).fps == "30"
    end

    test "a text row has no choices and does not step" do
      settings = Moonlight.defaults()

      assert Moonlight.choices(field(:address), settings) == []
      assert Moonlight.step(field(:address), settings, +1) == settings
    end
  end

  describe "display/2" do
    test "an empty text row reads as its placeholder" do
      assert Moonlight.display(field(:address), Moonlight.defaults()) == "not set"
      assert Moonlight.display(field(:app), Moonlight.defaults()) == "Steam"
    end

    test "a value carries its unit" do
      assert Moonlight.display(field(:fps), Moonlight.defaults()) == "30 fps"
      assert Moonlight.display(field(:bitrate), Moonlight.defaults()) == "5000 kbps"
    end
  end

  describe "config_pairs/1" do
    test "every key Moonlight's own parser knows" do
      keys = Moonlight.defaults() |> Moonlight.config_pairs() |> Enum.map(&elem(&1, 0))

      assert keys == ["address", "width", "height", "fps", "bitrate", "codec", "app"]
    end
  end
end
