defmodule MayonnaiOS.MixProject do
  use Mix.Project

  @app :mayonnaios
  @version "0.1.0"
  @all_targets [
    :rg40xxv,
    :bbb,
    :mangopi_mq_pro,
    :qemu_aarch64,
    :rpi,
    :rpi0,
    :rpi0_2,
    :rpi2,
    :rpi3,
    :rpi4,
    :rpi5,
    :x86_64
  ]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.17"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      source_url: "https://github.com/kek/mayonnaios",
      homepage_url: "https://kek.github.io/mayonnaios/",
      description: "Firmware and device software for the Anbernic RG40XXV handheld",
      docs: &docs/0
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {MayonnaiOS.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      # Used at runtime for portable backup manifests. Do not rely on the
      # transitive copy from :nerves, which is excluded from releases.
      {:jason, "~> 1.4"},
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

      # The upload UI. Plug for routing, Bandit for the socket.
      #
      # Bandit rather than Cowboy because it is pure Elixir -- no NIF, nothing
      # compiled against a sysroot, nothing for the cross build to get wrong --
      # and because it streams request bodies. That last part is the whole
      # requirement: this device has 1 GB of RAM and a CD image is several
      # hundred megabytes.
      #
      # No Phoenix. There is one page and a handful of endpoints, none of them
      # stateful, and Phoenix would bring an asset pipeline and thirty
      # dependencies to serve a file input.
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},

      # The Pickle engine: sandboxed Lua scriptapps. Luerl is Lua implemented
      # in pure Erlang -- no NIF, nothing to cross-compile, and a script that
      # crashes takes down one BEAM process instead of the VM. Chosen over
      # embedding real Lua for exactly those reasons.
      {:luerl, "~> 1.5"},

      # Scenic.
      #
      # scenic_driver_local comes from git, not Hex, and that is deliberate.
      # The released 0.11.0 has no cairo backend: its Makefile only knows
      # [glfw, bcm, drm], and the drm target links -lGLESv2 -lEGL -lgbm plus
      # -lvchostif, which is a Broadcom library that does not exist on this
      # device. The cairo-fb backend -- CPU rendering straight into /dev/fb0,
      # no GPU -- only exists on main.
      #
      # Requires cairo and freetype in the system; see nerves_defconfig in
      # nerves_anbernic. Build with SCENIC_LOCAL_TARGET=cairo-fb, since the
      # driver cannot infer a backend for a custom MIX_TARGET.
      # scenic also comes from git: the Hex 0.11.2 release pins
      # elixir_make ~> 0.7.7 while the driver's main branch needs ~> 0.8, so
      # mixing a released scenic with a git driver fails resolution outright.
      {:scenic, github: "ScenicFramework/scenic", override: true},
      {:scenic_driver_local, github: "ScenicFramework/scenic_driver_local"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_bbb, "~> 2.19", runtime: false, targets: :bbb},
      {:nerves_system_mangopi_mq_pro, "~> 0.6", runtime: false, targets: :mangopi_mq_pro},
      {:nerves_system_qemu_aarch64, "~> 0.1", runtime: false, targets: :qemu_aarch64},
      {:nerves_system_rpi, "~> 2.0", runtime: false, targets: :rpi},
      {:nerves_system_rpi0, "~> 2.0", runtime: false, targets: :rpi0},
      {:nerves_system_rpi0_2, "~> 2.0", runtime: false, targets: :rpi0_2},
      {:nerves_system_rpi2, "~> 2.0", runtime: false, targets: :rpi2},
      {:nerves_system_rpi3, "~> 2.0", runtime: false, targets: :rpi3},
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5},
      {:nerves_system_x86_64, "~> 1.24", runtime: false, targets: :x86_64},

      # The Anbernic RG40XXV system. Must ship cairo and freetype for the
      # Scenic driver to link, and Mesa for anything wanting GLES.
      {:nerves_system_rg40xxv,
       path: "../nerves_system_rg40xxv", runtime: false, targets: :rg40xxv}
    ]
  end

  defp docs do
    extras =
      [
        {"docs/index.md", title: "MayonnaiOS", filename: "home"},
        {"docs/wifi.md", title: "Connect to WiFi"},
        {"docs/games-and-cores.md", title: "Upload games and install cores"},
        {"docs/files-and-storage.md", title: "Manage files and storage"},
        {"docs/bluetooth-controller.md", title: "Use as a Bluetooth controller"},
        {"docs/bluetooth-devices.md", title: "Inspect nearby Bluetooth devices"},
        {"docs/sleep-and-power.md", title: "Sleep and power"},
        {"docs/moonlight.md", title: "Stream games with Moonlight"},
        {"docs/ssh-and-iex.md", title: "Use SSH and IEx"},
        {"docs/build-and-flash.md", title: "Build and flash firmware"},
        {"docs/development.md", title: "Develop on the host"},
        {"docs/contributing.md", title: "Contribute"},
        {"docs/pickles.md", title: "Build Pickles"},
        {"docs/repositories.md", title: "Repository responsibilities"},
        {"docs/data-layout.md", title: "On-device data layout"},
        {"docs/retroarch-internals.md", title: "RetroArch internals"},
        {"docs/retroarch-provisioning.md", title: "RetroArch provisioning decision record"},
        {"docs/bluetooth-internals.md", title: "Bluetooth internals"},
        {"docs/hardware-status.md", title: "RG40XXV hardware status"}
      ]
      # Later migration steps add the remaining named guides. Keeping the
      # complete manifest here makes each page join its intended group as soon
      # as its source exists, while this foundation remains buildable alone.
      |> Enum.filter(fn {path, _options} -> File.regular?(path) end)

    [
      formatters: ["html"],
      output: "doc",
      # ExDoc 0.40.3 reserves index.html for its main-page redirect, so the
      # docs/index.md source is emitted as home.html and selected as the main.
      main: "home",
      extra_section: "Guides",
      canonical: "https://kek.github.io/mayonnaios/",
      source_ref: "trunk",
      logo: "docs/assets/mayonnaios-mark.svg",
      favicon: "docs/assets/favicon.svg",
      extras: extras,
      groups_for_extras: [
        "Start here": ["docs/index.md"],
        "Use the device": [
          "docs/wifi.md",
          "docs/games-and-cores.md",
          "docs/files-and-storage.md",
          "docs/bluetooth-controller.md",
          "docs/bluetooth-devices.md",
          "docs/sleep-and-power.md",
          "docs/moonlight.md",
          "docs/ssh-and-iex.md"
        ],
        "Build and develop": [
          "docs/build-and-flash.md",
          "docs/development.md",
          "docs/contributing.md",
          "docs/pickles.md"
        ],
        "Architecture and internals": [
          "docs/repositories.md",
          "docs/data-layout.md",
          "docs/retroarch-internals.md",
          "docs/retroarch-provisioning.md",
          "docs/bluetooth-internals.md"
        ],
        "Hardware status": ["docs/hardware-status.md"]
      ],
      groups_for_modules: [
        "Public and operational APIs": [
          MayonnaiOS,
          MayonnaiOS.AppPartition,
          MayonnaiOS.Assets,
          MayonnaiOS.Audio,
          MayonnaiOS.AutoSleep,
          MayonnaiOS.BootDiagnostics,
          MayonnaiOS.Bundle,
          MayonnaiOS.Console,
          MayonnaiOS.Controller,
          MayonnaiOS.Cores,
          MayonnaiOS.Device,
          MayonnaiOS.Diagnostics,
          MayonnaiOS.Files,
          MayonnaiOS.GamesCard,
          MayonnaiOS.Led,
          MayonnaiOS.Library,
          MayonnaiOS.LowPower,
          MayonnaiOS.Moonlight,
          MayonnaiOS.Pairing,
          MayonnaiOS.Pickles,
          MayonnaiOS.Power,
          MayonnaiOS.Programs,
          MayonnaiOS.Saves,
          MayonnaiOS.Sleep,
          MayonnaiOS.SystemInfo,
          MayonnaiOS.Top,
          MayonnaiOS.Update,
          MayonnaiOS.USBGadget,
          MayonnaiOS.Volume,
          MayonnaiOS.Web,
          MayonnaiOS.WiFi
        ],
        "Device and runtime": [
          MayonnaiOS.Application,
          MayonnaiOS.AppPartition.Startup,
          MayonnaiOS.Audio.Amixer,
          MayonnaiOS.Audio.Mixer,
          MayonnaiOS.Audio.Startup,
          MayonnaiOS.Clock,
          MayonnaiOS.Cores.Startup,
          MayonnaiOS.Dev,
          MayonnaiOS.Game,
          MayonnaiOS.HostRuntime,
          MayonnaiOS.Input,
          MayonnaiOS.Keyboard,
          MayonnaiOS.Launcher.Kill,
          MayonnaiOS.Launcher.Signals,
          MayonnaiOS.Led.Monitor,
          MayonnaiOS.LowPower.Cpus,
          MayonnaiOS.LowPower.Governor,
          MayonnaiOS.LowPower.Radio,
          MayonnaiOS.LowPower.Renderer,
          MayonnaiOS.Status,
          MayonnaiOS.Top.Beam,
          MayonnaiOS.Top.Os,
          MayonnaiOS.Udev
        ],
        UI: [
          MayonnaiOS.Browser,
          MayonnaiOS.Browser.View,
          MayonnaiOS.Launcher,
          MayonnaiOS.Moonlight.App,
          MayonnaiOS.Panel,
          MayonnaiOS.Scene.Controller,
          MayonnaiOS.Scene.Diagnostics,
          MayonnaiOS.Scene.Home,
          MayonnaiOS.Scene.Moonlight,
          MayonnaiOS.Scene.Pairing,
          MayonnaiOS.Scene.Pickle,
          MayonnaiOS.Scene.StatusBar,
          MayonnaiOS.Scene.Top,
          MayonnaiOS.Scene.Update,
          MayonnaiOS.Scene.WiFi,
          MayonnaiOS.Splash,
          MayonnaiOS.Theme,
          MayonnaiOS.Update.App,
          MayonnaiOS.Web.Page,
          MayonnaiOS.WiFi.App,
          MayonnaiOS.WiFi.Editor
        ],
        "Bluetooth internals": [
          ~r/^MayonnaiOS\.Bluetooth\./,
          MayonnaiOS.Controller.Battery,
          MayonnaiOS.Controller.Pad,
          MayonnaiOS.Controller.Report,
          MayonnaiOS.Pairing.Cursor
        ],
        "Pickles internals": [~r/^MayonnaiOS\.Pickles\./]
      ],
      assets: %{"docs/assets" => "assets/mayonnaios"},
      before_closing_head_tag: &before_closing_head_tag/1,
      before_closing_footer_tag: &before_closing_footer_tag/1,
      skip_code_autolink_to: [
        ":proc_lib.init_p/5",
        "MayonnaiOS.Application",
        "MayonnaiOS.Browser.View.full/0",
        "MayonnaiOS.Diagnostics.rtl_status/0",
        "MayonnaiOS.Launcher.await_exit/3",
        "MayonnaiOS.Scene.StatusBar.init/3"
      ]
    ]
  end

  defp before_closing_head_tag(:html) do
    ~s(<link rel="stylesheet" href="assets/mayonnaios/docs.css">)
  end

  defp before_closing_head_tag(_formatter), do: ""

  defp before_closing_footer_tag(:html) do
    """
    <div class="mayonnaios-docs-notice">
      Documentation for current <code>trunk</code>; installed firmware may differ.
      <a href="https://github.com/kek/mayonnaios/issues/new">Report a documentation issue</a>.
    </div>
    """
  end

  defp before_closing_footer_tag(_formatter), do: ""

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://nerves-pack.hexdocs.pm/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []
end
