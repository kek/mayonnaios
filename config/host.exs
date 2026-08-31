import Config

# Add configuration that is only needed when running on the host here.

# Host development state is isolated from both the repository sources and the
# device paths. HostRuntime creates these paths before the launcher starts.
host_files = Path.expand("tmp/host/files")
host_backlight = Path.expand("tmp/host/brightness")

config :mayonnaios,
  pickles_root: Path.expand(".pickles"),
  file_roots: [%{key: "host", path: host_files, note: "host development scratch files"}],
  backlight_brightness: host_backlight,
  web_port: 4000,
  # `mix test` stays headless. `iex -S mix` and `mix run --no-halt` in dev
  # start the complete host launcher automatically.
  autostart_ui: config_env() == :dev,
  host_runtime: config_env() == :dev

# One external-process stand-in exercises the same panel handoff and obituary
# path as RetroArch without requiring a host RetroArch build. The remaining
# rows are device-independent Elixir apps; installed UI pickles are appended
# dynamically by MayonnaiOS.Programs.
config :mayonnaios, :programs, [
  %{
    name: "Host program (launcher handoff)",
    path: "/bin/sh",
    args: ["-c", "printf 'host program running\\n'; sleep 1"]
  },
  %{name: "Moonlight settings", app: MayonnaiOS.Moonlight.App},
  %{name: "BEAM processes", app: {MayonnaiOS.Top, :beam}},
  %{name: "OS processes", app: {MayonnaiOS.Top, :os}},
  %{name: "WiFi", app: MayonnaiOS.WiFi.App},
  %{name: "Software update", app: MayonnaiOS.Update.App}
]

# A complete profile keeps host development and tests on the same application
# seams as a target without pretending the laptop has any of this hardware.
config :mayonnaios, :device, %{
  id: :host,
  name: "MayonnaiOS host",
  panel_size: {640, 480},
  inputs: %{
    gamepad: "host-gamepad",
    stick: "host-stick",
    volume: "host-volume",
    headphone: "host-headphone",
    power: "host-power"
  },
  buttons: %{
    launch: :btn_b,
    confirm: :btn_x,
    actions: :btn_x,
    full: :btn_y,
    poweroff_modifier: :btn_select,
    home: :btn_mode,
    up: :btn_dpad_up,
    down: :btn_dpad_down,
    left: :btn_dpad_left,
    right: :btn_dpad_right,
    page_up: :btn_tl,
    page_down: :btn_tr,
    back: :btn_a,
    sleep: :key_power
  },
  leds: %{green: "green:power", red: "green:status"},
  power_supplies: %{battery: "/nonexistent/battery", usb: "/nonexistent/usb"},
  games_card_device: "/nonexistent/games-card",
  backlight: Path.expand("tmp/host/brightness"),
  lid_switch: nil,
  rtc?: true
}

# The extra low-power measures are off on a laptop, and this is a safety
# interlock rather than a preference. `MayonnaiOS.LowPower.Cpus` writes "0" to
# every `/sys/devices/system/cpu/cpuN/online` it finds, and on a Linux
# development machine -- or CI running as root -- those files are real and
# writable. A suite that offlines the machine's own cores would be a worse bug
# than anything it could catch, and on macOS the path is simply absent, so the
# hazard is invisible exactly where this is most often run.
#
# Tests that exercise the measures turn this on explicitly and point
# `:cpu_dir` and `:cpufreq_dir` at a temp tree; see test/low_power_test.exs.
config :mayonnaios, low_power_sleep: false

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://nerves-runtime.hexdocs.pm/readme.html#using-nerves_runtime-in-tests
       # https://nerves-runtime.hexdocs.pm/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}

# Scenic viewport for host development.
#
# The same shape as the one in target.exs, and deliberately the same 640x480:
# a scene that looks right in a differently-sized window is not evidence about
# the panel, and this is the size the device has.
#
# `scenic_driver_local` picks its backend from MIX_TARGET -- cairo-gtk in a
# window here, cairo-fb straight to /dev/fb0 on the device -- so the same
# scene code runs both places without a driver change.
#
# The iteration loop this exists for:
#
#     iex -S mix
#     iex> MayonnaiOS.start_ui()
#     iex> {:ok, vp} = Scenic.ViewPort.info(:main_viewport)
#     ... edit a scene ...
#     iex> recompile()
#     iex> Scenic.ViewPort.set_root(vp, MayonnaiOS.Scene.Home, 0)
#
# recompile/0 alone is not enough: a scene is a process holding a built
# %Scenic.Graph{}, and swapping the module's code does not rebuild it.
# set_root/3 terminates the scene and starts a new one, which is what picks up
# the change. Scene.Home is already written to survive that -- it takes the
# selected index as an argument rather than remembering it -- because the
# Launcher repaints the same way on the device.
#
# set_root/3 takes the %Scenic.ViewPort{} struct, not the registered name, and
# the scene module and its args separately -- `set_root(:main_viewport,
# {Scene, 0})` raises FunctionClauseError with a `nil` third argument, which
# does not point at either mistake. info/1 is what turns the name into the
# struct; keep `vp` bound in the session and it is one line per reload.
config :mayonnaios, :viewport,
  name: :main_viewport,
  size: {640, 480},
  theme: :dark,
  default_scene: MayonnaiOS.Scene.Home,
  drivers: [
    [
      module: Scenic.Driver.Local,
      name: :local,
      window: [title: "MayonnaiOS", resizeable: false]
    ]
  ]

# Backup development uses repository-local scratch data only.
host_backup = Path.expand("tmp/host/backup-card")

config :mayonnaios,
  backup_destination: host_backup,
  backup_sources: [
    %{key: "mayonnaios", path: Path.expand("tmp/host/user-data/mayonnaios")},
    %{
      key: "retroarch",
      path: Path.expand("tmp/host/user-data/retroarch"),
      exclude: [["cores"], ["mayonnaios.cfg"]]
    },
    %{key: "moonlight", path: Path.expand("tmp/host/user-data/moonlight")},
    %{key: "pickles", path: Path.expand("tmp/host/user-data/pickles")}
  ]
