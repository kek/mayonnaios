defmodule ScenicRg40xxv.MixProject do
  use Mix.Project

  @app :scenic_rg40xxv
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
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {ScenicRg40xxv.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

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

      # The Anbernic RG40XXV system. Points at the worktree that carries the
      # cairo/freetype and Mali changes; repoint to ../nerves_anbernic once
      # that branch is merged to trunk.
      {:nerves_system_rg40xxv,
       path: "/Users/ke/src/nerves_anbernic/.claude/worktrees/gpu-and-cairo",
       runtime: false,
       targets: :rg40xxv}
    ]
  end

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
