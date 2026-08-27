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
- Audio out, speaker and headphones, with the volume rocker moving the mixer
- Battery, charge and discharge
- Four thermal zones
- RTL8821CS WiFi and Bluetooth
- USB gadget, for SSH when WiFi is down
- Both SD card slots, Linux and FAT support

Software:

- Scenic UI: a launcher and a diagnostics readout, drawn on the CPU into
  `/dev/fb0`
- A Bluetooth LE gamepad that presents as an Xbox Wireless Controller, so a
  Steam Deck, a Mac or a PC recognises it with no mapping step — a whole BLE
  HID stack in Elixir, with no BlueZ in the image
- A Bluetooth devices app: an LE scan of what is nearby, and the bonds this
  device already holds
- RetroArch, with cores installed and upgraded independently of the firmware
- Checksum-verified bundle install, with versioned directories and rollback
- A web UI for uploading games from a phone
- File management built into that browser: copy, move, rename and delete
  across both cards, with a clipboard instead of a destination to type
- A process readout like `top`, twice: the BEAM's processes by reductions and
  memory, and the Linux ones from `/proc`
- Pickles: small sandboxed Lua apps, installed over the network like games,
  for things like controlling lamps on the LAN or polling a web API. See
  [docs/pickles.md](docs/pickles.md)
- Sleep on the power button: the backlight goes off and any button brings it
  back. Not suspend — this board's only suspend mode would save almost
  nothing, and `MayonnaiOS.Sleep`'s moduledoc has the analysis
- A NeXTSTEP-style column launcher: Games, Files, Apps and System open
  as columns, three on screen, and Files browses the whole filesystem in
  place
- Orderly power off: the Select+Menu chord, or the **Power off** row under
  System
- An indicator LED that means something: quick flashing green while starting,
  solid green running, slow flashing green asleep, blinking red when the
  application fails to start. The yellow light in the other window is the
  PMIC's charge indicator and keeps its own counsel; `MayonnaiOS.Led`'s
  moduledoc has the color map

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
your tree does not match any published release and you are in for a full
system build, which takes a while. That is usually a sign you changed something
under `nerves_system_rg40xxv` — a comment is enough.

## Putting games on it

Open the device from a phone on the same WiFi:

    http://nerves.local/

Pick a file and it uploads. The same page lists the
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

### Pickles

Small Lua apps — lamp remotes, API pollers — run sandboxed inside the
firmware and install the same way games do:

    tar -czf hello.tar.gz -C pickles/hello .
    curl -T hello.tar.gz http://nerves.local/api/pickles/hello

What a pickle can touch is declared in its manifest and enforced by the
sandbox: HTTP, the local network, a small persistent store, timers, the
panel — and nothing else. A pickle with the `ui` capability appears in the
launcher's Apps column and draws on the screen; the others run headless.
[docs/pickles.md](docs/pickles.md) is the guide to writing one; the
`pickle` Claude skill in `.claude/skills/` automates the whole
develop-and-deploy loop.

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

## Moving files around on the device

Pick **Files** in the launcher: copy, move, rename and delete across both
cards, browsing from the ROM roots, the installed bundles, the installed
cores, `/root` and the whole filesystem from `/`. Copy and move go through
a clipboard, since there is nothing to type a destination with.

Two guarantees that are not visible on screen: nothing ever overwrites — an
existing destination is refused, because on this device the file being
replaced is somebody's save — and every copy is fsynced via a `.part` file
renamed into place, so an interrupted copy leaves a `.part` rather than a
ROM that looks complete and fails three hours into a game.
`MayonnaiOS.Files` has the rest, including the path policy and how symlinks
are treated.

## Emulator cores

Cores are installed onto the device rather than built into the firmware, so
adding one is not a reflash.

The web page at `http://nerves.local/` lists every core RetroArch can see and
offers to install the catalogued ones that are missing. From IEx:

    iex> MayonnaiOS.Cores.list()
    iex> MayonnaiOS.Cores.install(:snes9x2010)

`install/1` downloads the tarball, checks its SHA-256 **before** unpacking
anything, and installs into a versioned directory with a `current` symlink —
so an install never overwrites what is running, and undoing one is a symlink
move.

Cores for this device are cross-built in
[`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) against the
same sysroot as the rest of the system; RetroArch's own online core updater is
compiled out, because the libretro buildbot's cores will not load here.

Two things this firmware quietly guarantees, with the full mechanics in
[docs/retroarch-internals.md](docs/retroarch-internals.md):

- **Cores survive upgrades.** RetroArch reads symlinks that are rebuilt at
  every boot, so upgrading RetroArch cannot lose a core and installing a core
  never writes inside a bundle.
- **Saves reach the card within ten seconds.** RetroArch is configured to
  autosave SRAM every ten seconds and the launcher fsyncs the files when a
  game ends — because this handheld is switched off by pulling power, and a
  save that only lands on clean exit is a save that lands on the good days.
  The firmware owns that setting: changing it in RetroArch's Saving menu does
  not survive a reboot.

## Game streaming (Moonlight)

Moonlight Embedded streams a Sunshine or GeForce host to the handheld —
decoded in software on the A53s and drawn through SDL on the same KMS stack
RetroArch uses. It installs the same way RetroArch does, as a bundle:

    iex> MayonnaiOS.Bundle.install(MayonnaiOS.Bundle.spec(:moonlight))

First run is a one-time SSH session, because two things exist only on the
player's side of the fence. Pairing prints a PIN that must be typed into the
host, and the stream cannot start without the host's address — which no
bundle can know, so the launcher passes a config file the player creates:

    /root/bundles/moonlight/current/bin/moonlight pair <host>
    mkdir -p /root/.config/moonlight
    cp /root/bundles/moonlight/current/share/moonlight/moonlight.conf \
       /root/.config/moonlight/moonlight.conf
    echo 'address = <host>' >> /root/.config/moonlight/moonlight.conf

The template carries the hardware-dictated defaults — 720p30, h264, modest
bitrate — and says what to lower first if decode cannot keep up. None of this
has been run on the handheld yet; the
[`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) README lists
what only hardware can answer.

## Using it as a Bluetooth controller

The handheld can be the gamepad instead of the console. Pick **Bluetooth
controller** in the launcher and it advertises itself as an Xbox Wireless
Controller; pair from anything that speaks HID over GATT, and every button
and the stick go there instead of to the launcher. Menu comes back.

- **Steam Deck**: Settings → Bluetooth. It appears as `Xbox Wireless
  Controller` with a gamepad icon — Xbox glyphs, working defaults, nothing to
  map.
- **Windows**: Settings → Bluetooth & devices → Add device → Bluetooth. It
  pairs without a code.
- **macOS**: System Settings → Bluetooth. The GameController framework has
  first-class Xbox support, so anything built on it — Steam included — sees a
  pad it knows.

The host receives the left stick, the D-pad, A/B/X/Y by their printed labels,
LB/RB, the triggers, and View and Menu from Select and Start. **Select and
Start held together are the Xbox button** — on a Steam Deck, the Steam
button.

Two rules worth knowing before anything goes wrong:

- **On macOS, a game that lists the pad but sees no presses is missing the
  Input Monitoring permission** (System Settings → Privacy & Security).
  Enumerating HID devices needs no permission but receiving input does, so
  the symptom looks exactly like a broken controller. Quit Steam completely
  and reopen it after granting.
- **A firmware update that changes the controller's descriptor means
  re-pairing on every host**: forget the device on the host *and* run
  `MayonnaiOS.Controller.unpair()` here. Doing only one of the two leaves a
  host that reconnects, cannot decrypt, and reports a broken device.

The panel shows how far a connection has come — advertising, connected,
paired, subscribed — because those stages all look identical from the other
machine. Everything else, including why the borrowed identity is the right
trade and what it costs, how the no-BlueZ stack works, and the recovery when
hci0 is missing, is in
[docs/bluetooth-controller.md](docs/bluetooth-controller.md).

## Seeing what Bluetooth is nearby

Pick **Bluetooth devices** in the launcher. It runs an active LE scan and
lists what answers, alongside the bonds this device already holds — so
forgetting a bond happens on the device instead of over SSH.

It does not connect headphones: Bluetooth audio is A2DP over BR/EDR, and
none of that transport is here. `MayonnaiOS.Pairing` has the full account.

It holds hci0 for as long as it runs, so it and the controller app are
mutually exclusive.

    iex> MayonnaiOS.Pairing.start()
    iex> MayonnaiOS.Pairing.status()
    iex> MayonnaiOS.Pairing.stop()

## Poking at a running device

SSH gives you an IEx prompt rather than a shell, so the device is inspectable
the way any BEAM node is:

    $ ssh nerves.local

    iex> MayonnaiOS.Bundle.install(MayonnaiOS.Bundle.spec(:retroarch))
    iex> MayonnaiOS.Library.index()
    iex> MayonnaiOS.GamesCard.mounted?()
    iex> MayonnaiOS.Volume.up()
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
| arrows, `h` `j` `k` `l` | D-pad |
| `z` | A — launch the highlighted entry |
| enter | Menu — back to the home screen |
| backspace | Select |
| `p` | the power button — sleep, and any key wakes it |
| escape | Select+Menu, the power-off chord |

`x`, `c`, `v` and `s` are sent too, as B, X, Y and Start. None of this is
conditional on the target, so a USB keyboard plugged into the handheld gets
the same bindings. `p` is the one key that is not a pad button: it sends
`KEY_POWER`, which on the device arrives from `axp20x-pek` rather than from
the gamepad.

Rendering on the host goes through `scenic_driver_local`'s cairo-gtk backend,
which wants `gtk+3`, `cairo`, `pkgconf` and, on macOS, XQuartz. On the device
the same scene code draws straight into `/dev/fb0` instead; the backend follows
`MIX_TARGET`, so nothing in the scenes changes.

The web UI runs on the host as well — point `:rom_roots` and the other paths at
a scratch directory and start `MayonnaiOS.Web` under a supervisor.

## Going deeper

| | |
|---|---|
| [Pickles](docs/pickles.md) | Writing and deploying sandboxed Lua apps |
| [The Bluetooth controller](docs/bluetooth-controller.md) | The borrowed identity and its trade-offs, the no-BlueZ stack, recovery, what is not built yet |
| [RetroArch internals](docs/retroarch-internals.md) | How cores, config and saves are kept honest across upgrades and pulled power |

## The three repositories

| | |
|---|---|
| [`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) | The Buildroot BSP: kernel, device tree, U-Boot, fwup layout. |
| `mayonnaios` | This one: the OTP release and the bundle mechanism. |
| [`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) | Cross-builds the native apps — RetroArch and its cores, Moonlight — against the system's own sysroot; publishes checksummed tarballs. |
