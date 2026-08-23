import Config

# Add configuration that is only needed when running on the host here.

# Pickles on the host go under the working directory rather than /root, so
# `iex -S mix` can exercise the whole install/run loop on a laptop. Tests
# override this per-test with a tmp directory.
config :mayonnaios, pickles_root: ".pickles"

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
