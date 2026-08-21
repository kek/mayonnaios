# MayonnaiOS

Firmware for the Anbernic RG40XXV handheld: a launcher, a diagnostics screen and
RetroArch, written in Elixir on [Nerves](https://nerves-project.org/). Games and
emulator cores are installed onto the device after the fact, so adding a core is
not a reflash.

Board support lives in a separate repository,
[`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv). This one
is the application.

## Supported

Hardware:

- 640×480 panel
- Mali-G31 MC1 GPU, via Panfrost and Mesa
- Gamepad, volume keys and headphone-jack detection, through evdev
- Audio out, speaker and headphones
- Battery, charge and discharge
- Four thermal zones
- RTL8821CS WiFi and Bluetooth
- USB gadget, for SSH when WiFi is down
- Both SD card slots, Linux and FAT support

Software:

- Scenic UI: a launcher and a diagnostics readout, drawn on the CPU into
  `/dev/fb0`
- RetroArch, with cores installed and upgraded independently of the firmware
- Checksum-verified bundle install, with versioned directories and rollback
- A web UI for uploading games from a phone

## Building and flashing

The WiFi credentials come from the environment, so that firmware without them
fails the build rather than producing an image you cannot reach. Set them, pick
the target, and build:

    export RG40XXV_WIFI_SSID="your-ssid"
    export RG40XXV_WIFI_PSK="your-psk"
    export MIX_TARGET=rg40xxv

    mix deps.get
    mix firmware

`mix burn` writes an SD card, which is what you want the first time. After that
`mix upload nerves.local` pushes an update over the network to a device that is
already running, which takes seconds rather than a card shuffle. Firmware is
written to whichever of the two slots is not in use, so a bad update reverts on
the next boot instead of leaving you with a brick.

If `mix deps.get` starts compiling Buildroot instead of downloading a system,
your tree does not match any published release and you are in for about three
and a half hours. That is usually a sign you changed something under
`nerves_system_rg40xxv` — a comment is enough.

## Putting games on it

Open the device from a phone on the same WiFi:

    http://nerves.local/

Pick a file and it uploads, with a progress bar. The same page lists the
emulator cores RetroArch can see and offers to install more. Uploads stream
straight to disk, so a several-hundred-megabyte disc image is fine.

There is no authentication — anything on your network can upload a ROM, delete
one or install a core. That is the same trust model as a printer's web page, and
it is a deliberate choice for a device on a home network rather than an
oversight.

`scp` works too, if you would rather:

    scp game.sfc nerves.local:/root/ROMS/snes/

Use plain `scp` and not `scp -O`, which forces a legacy protocol that needs an
`scp` binary the device does not have.

### The second card slot

A card in the second slot is mounted at boot, and its `ROMS/` directory is read
alongside the internal one — so games already on a card from another handheld
appear in the launcher without being copied anywhere. Both cards use the same
`ROMS/<system>` layout, because the card arrives from the stock OS with `ROMS/`
already on it.

Reads span both cards. Writes only ever land on the internal one: the games
card can be out, and an upload that silently went nowhere is worse than one
extra copy. Deleting works on either.

Unmount before pulling the card out —

    iex> MayonnaiOS.GamesCard.unmount()

— because exFAT has no journal and this device is switched off by pulling
power.

## Emulator cores

Cores are installed onto the device rather than built into the firmware, so
adding one is not a reflash.

The web page at `http://nerves.local/` lists every core RetroArch can see and
offers to install the catalogued ones that are missing. From IEx:

    iex> MayonnaiOS.Cores.list()
    iex> MayonnaiOS.Cores.install(:snes9x2010)

`install/1` downloads the tarball, checks its SHA-256 **before** unpacking
anything, and installs into a versioned directory under `/root/cores` with a
`current` symlink — so an install never overwrites what is running, and undoing
one is a symlink move. The expected checksum is compiled into the firmware, not
fetched alongside the download: a checksum served from the same place as the
file it describes is not evidence of anything.

RetroArch's own online core updater is compiled out of this build. The libretro
buildbot's cores are linked against a different glibc and sysroot and will not
load here; cores for this device are cross-built in
[`retroarch-rg40xxv`](https://github.com/kek/retroarch-rg40xxv) against the same
sysroot as the rest of the system.

### Where cores end up

RetroArch reads them from its own default directory,
`/root/.config/retroarch/cores`, and no config file tells it to — that is the
default with nothing set. The directory holds symlinks; the real `.so` files
stay in the RetroArch bundle or under `/root/cores`. So upgrading RetroArch
cannot lose a core, and installing a core never writes inside a bundle.

`MayonnaiOS.Cores.sync/0` rebuilds those links and runs at every boot, which is
what makes them follow `current` across an upgrade. Running it by hand is safe.

If RetroArch shows *no* cores at all, the usual cause is a `libretro_directory`
left in RetroArch's own config by an older bundle — it is taken verbatim, is
not checked against reality, and survives the bundle that set it.
`MayonnaiOS.Cores.clear_stale_directory/0` takes it back out, and boot does the
same.

## Poking at a running device

SSH gives you an IEx prompt rather than a shell, so the device is inspectable
the way any BEAM node is:

    $ ssh nerves.local

    iex> MayonnaiOS.Bundle.install(MayonnaiOS.Bundle.spec(:retroarch))
    iex> MayonnaiOS.Library.index()
    iex> MayonnaiOS.GamesCard.mounted?()
    iex> MayonnaiOS.Audio.run()

`Bundle.install/1` is how RetroArch itself gets onto the device, by the same
fetch-verify-install route as a core. Worth knowing on a freshly flashed card:
RetroArch is not in the firmware, so the launcher shows it greyed out and
unlaunchable until this has run once.

Logs are in `RingLogger`: `RingLogger.next` for what has happened since you last
looked, `RingLogger.attach` to follow along.

## Working on it

Without `MIX_TARGET`, everything builds for your laptop, which is where the
tests run:

    mix test

No hardware required.

The UI runs on the laptop too, in a window at the panel's own 640×480 — a scene
that looks right at some other size is not evidence about the device:

    iex -S mix
    iex> MayonnaiOS.start_ui()

    # ... edit a scene ...
    iex> recompile()
    iex> MayonnaiOS.reload_ui()

`recompile/0` alone changes nothing on screen. A scene is a process holding an
already-built graph, and swapping the module's code does not rebuild it;
`reload_ui/2` restarts the root scene, which is what picks the edit up.

A keyboard drives the launcher. `MayonnaiOS.Keyboard` turns each keystroke into
the same evdev report the gamepad produces, so the bindings, the wrap-around
and the launch path being exercised are the device's own code rather than a
host-only path:

| | |
|---|---|
| arrows, `j` / `k` | D-pad |
| `z` | A — launch the highlighted entry |
| `c` | X — the diagnostics screen |
| enter | Menu — back to the home screen |
| backspace | Select |
| escape | Select+Menu, the power-off chord |

`x` and `v` are sent too, as B and Y, and do nothing — the launcher binds
neither. None of this is conditional on the target, so a USB keyboard plugged
into the handheld gets the same bindings.

Rendering on the host goes through `scenic_driver_local`'s cairo-gtk backend,
which wants `gtk+3`, `cairo`, `pkgconf` and, on macOS, XQuartz. On the device
the same scene code draws straight into `/dev/fb0` instead; the backend follows
`MIX_TARGET`, so nothing in the scenes changes.

The web UI runs on the host as well — point `:rom_roots` and the other paths at
a scratch directory and start `MayonnaiOS.Web` under a supervisor.

## The three repositories

| | |
|---|---|
| [`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) | The Buildroot BSP: kernel, device tree, U-Boot, fwup layout. |
| `mayonnaios` | This one: the OTP release and the bundle mechanism. |
| [`retroarch-rg40xxv`](https://github.com/kek/retroarch-rg40xxv) | Cross-builds RetroArch and cores against the system's own sysroot; publishes checksummed tarballs. |
