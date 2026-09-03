# MayonnaiOS

MayonnaiOS is firmware for the **Anbernic RG40XXV handheld**, built with Elixir
and [Nerves](https://nerves-project.org/). It provides a launcher, device tools,
sandboxed Lua apps called Pickles, and independently installed RetroArch cores
and native programs. The RG40XXV is the only supported physical target; host and
other Mix targets are development or dependency scaffolding, not supported
products.

## Status

- **Verified:** 640×480 display and GPU support, controls, audio, battery and
  thermal readings, WiFi settings, both SD slots, RetroArch/core/save behavior,
  Bluetooth scanning and bond management, and sleep/backlight wake.
- **Experimental:** Bluetooth controller mode (intermittent `hci0` bring-up) and
  additional low-power measures; total sleep savings remain unmeasured.
- **Untested on RG40XXV:** USB gadget cable enumeration and Moonlight streaming.
  Moonlight configuration is host-tested, but a successful handheld stream has
  not been claimed.
- **Unsupported:** outbound Bluetooth pairing and Bluetooth audio.

See the [complete hardware status matrix](https://kek.github.io/mayonnaios/hardware-status.html)
for evidence and limitations. These statuses describe current `trunk`; installed
firmware may differ.

## Documentation

The canonical documentation is <https://kek.github.io/mayonnaios/> (start at
[MayonnaiOS home](https://kek.github.io/mayonnaios/home.html)). Common tasks:

- [Connect to WiFi](https://kek.github.io/mayonnaios/wifi.html)
- [Upload games and install cores](https://kek.github.io/mayonnaios/games-and-cores.html)
- [Manage files and storage](https://kek.github.io/mayonnaios/files-and-storage.html)
- [Use Bluetooth features](https://kek.github.io/mayonnaios/bluetooth-controller.html)
- [Sleep and power](https://kek.github.io/mayonnaios/sleep-and-power.html)
- [Configure Moonlight](https://kek.github.io/mayonnaios/moonlight.html)
- [Use SSH and IEx](https://kek.github.io/mayonnaios/ssh-and-iex.html)
- [Build Pickles](https://kek.github.io/mayonnaios/pickles.html)

## Build and flash

There is **no supported prebuilt firmware image**. Source builds require Elixir
`~> 1.20` with compatible Erlang/OTP, Nerves host tools, an SSH public key in
`~/.ssh`, and
[`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) checked
out at `../nerves_system_rg40xxv`.

WiFi is the only verified remote-access path. Set correct initial credentials
before building; bad credentials can leave the device unreachable and require
reflashing. Do not rely on USB recovery: gadget setup exists, but
RG40XXV cable enumeration has not been observed.

```sh
export MAYONNAIOS_WIFI_SSID="your-ssid"
export MAYONNAIOS_WIFI_PSK="your-psk"
export MIX_TARGET=rg40xxv
mix deps.get
mix firmware
mix burn
```

**`mix burn` is destructive:** verify the selected SD card carefully. Read the
full [build and flash guide](https://kek.github.io/mayonnaios/build-and-flash.html)
before writing media or uploading later firmware.

## Repository map

| Repository | Responsibility |
|---|---|
| [`mayonnaios`](https://github.com/kek/mayonnaios) | This OTP application, launcher, firmware assembly, bundle/core catalogue, and documentation |
| [`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) | Board support, kernel, device tree, U-Boot, Buildroot, fwup layout, and target sysroot |
| [`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) | Cross-built RetroArch, cores, Moonlight, and published native artifacts |

See [repository responsibilities](https://kek.github.io/mayonnaios/repositories.html)
before making a cross-repository change.

## Contributing on the host

Install GTK 3, Cairo, and `pkgconf` (plus XQuartz on macOS). On Debian/Ubuntu,
install `build-essential`, `libcairo2-dev`, `libfreetype6-dev`, `libgtk-3-dev`,
`libmnl-dev`, `libsystemd-dev`, and `pkg-config`, then run:

```sh
MIX_TARGET=host mix test
MIX_TARGET=host iex -S mix
```

The host UI is a development aid, not RG40XXV hardware evidence. See
[development](https://kek.github.io/mayonnaios/development.html) and
[contributing](https://kek.github.io/mayonnaios/contributing.html) for the full
workflow.
