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
- A WiFi settings screen: what is on the air, what the device is configured
  to join, and a character wheel to type a passphrase on — so the network is
  not fixed at build time
- A web UI for uploading games from a phone
- File management built into that browser: copy, move, rename and delete
  across both cards, with a clipboard instead of a destination to type
- A process readout like `top`, twice: the BEAM's processes by reductions and
  memory, and the Linux ones from `/proc`
- Pickles: small sandboxed Lua apps, installed over the network like games,
  for things like controlling lamps on the LAN or polling a web API. See
  [docs/pickles.md](docs/pickles.md)
- Sleep on the power button, or after three minutes idle in the launcher: the
  backlight goes off and any button brings it back. The idle timer pauses
  while charging and while a program or app is active. Not suspend — this
  board's only suspend mode would save almost nothing, and
  `MayonnaiOS.Sleep`'s moduledoc has the analysis
- A NeXTSTEP-style column launcher: Games, Files, Apps and System open
  as columns, three on screen, and Files browses the whole filesystem in
  place
- Orderly power off: the Select+Menu chord, or the **Power off** row under
  System
- An indicator LED that means something: quick flashing green while starting,
  solid green running, slow flashing green asleep, slow blinking red at 20%
  battery, and quick blinking red when the application fails to start. Low
  battery clears at 30% or while charging; failure always wins. The yellow
  light in the other window is the PMIC's charge indicator and keeps its own
  counsel; `MayonnaiOS.Led`'s moduledoc has the color map

## Building and flashing

The WiFi credentials come from the environment, so that firmware without them
fails the build rather than producing an image you cannot reach. They are the
network the device joins on a fresh card; more can be added on the device
afterwards, from the **WiFi** screen below. Set them, pick the target, and
build:

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

## Changing which WiFi it joins

Pick **WiFi** under System. It lists what is on the air with signal, security
and whether this device already knows it, plus any saved network that is out
of range — so a network can be forgotten from the other end of the house.

    D-pad     move the cursor
    A         join it. Open networks join straight away; a secured one you
              have not joined before opens the passphrase wheel
    X         retype the passphrase of a saved network
    Y         forget a saved network. Twice — the first press arms the row

Typing happens on a character wheel, because there is no keyboard: up and
down cycle the character under the caret, left and right move it, and **L1
and R1 jump between lowercase, uppercase, digits and symbols** — which is
the difference between reaching `Q` in two presses and in twenty-six. The
passphrase is shown rather than masked; every character is picked by reading
the wheel, so hiding the result would only hide a mistake made twenty presses
ago.

Two things this screen guarantees, both because this device's only reliable
way in is the radio it is reconfiguring:

- **Joining never replaces the network that already works.** A new network is
  added alongside the ones already configured, most-recently-chosen first, so
  a passphrase picked wrong costs one walk back into range rather than a card
  reflash. The credentials built into the firmware keep working forever.
- **A refused passphrase says so, and is withdrawn again.** `wpa_supplicant`
  reports a rejected key as an event rather than as a silence, so the screen
  can say *the access point refused that passphrase* instead of *something
  did not work* — and the bad network is removed, because one the supplicant
  keeps retrying is one that interrupts the network that does work.

Enterprise (802.1X) and WEP networks appear in the list with what they would
need written on the row, and cannot be joined from here — neither is a
passphrase, and neither can be picked from a wheel. Configure those over SSH
with `VintageNet.configure/2`. `MayonnaiOS.WiFi` has the rest, including what
a join actually writes.

From IEx, if you would rather:

    iex> MayonnaiOS.WiFi.list()
    iex> MayonnaiOS.WiFi.join(%{ssid: "kitchen", security: :wpa_psk}, "a passphrase")
    iex> MayonnaiOS.WiFi.forget("kitchen")

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

**Moonlight settings**, in the System column, is where the stream is set up:
the host's address, the resolution, the frame rate, the bitrate, the codec,
and which app to launch. Saving writes
`/root/.config/moonlight/moonlight.conf`, which is the file the launcher
passes Moonlight on its command line — so what the screen says and what the
stream does cannot drift apart.

- **The first save seeds from the bundle's own template**, so the
  hardware-dictated defaults and the comments explaining them are what a new
  file starts as: 720p30, h264, SDL, a modest bitrate.
- **It edits, it does not regenerate.** A key the screen does not offer —
  `surround`, `rotate`, `packetsize`, anything set over SSH — is copied
  through untouched, comments included.
- **The row is there before the bundle is**, and says so. A config file
  written before the program that reads it arrives is still a config file.
- **Nothing is written until the Save row**, and the header says "unsaved
  changes" until then. A write that fails — read-only filesystem, no space —
  says why, on the panel.
- Moonlight reads the file when it starts, so a change takes effect on the
  next stream rather than the running one.

One step still needs SSH: pairing prints a PIN that has to be typed into the
host, and there is no way to show it on a screen the launcher has handed to
another program.

    /root/bundles/moonlight/current/bin/moonlight pair <host>

None of this has been run on the handheld yet; the
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

The complete development runtime runs on the laptop too, in a window at the
panel's own 640×480 — a scene that looks right at some other size is not
evidence about the device:

    iex -S mix

    # ... edit a scene ...
    iex> recompile()
    iex> MayonnaiOS.reload_ui()

In `dev`, that one command starts Scenic, the real launcher, the keyboard
controller bridge, the web UI on <http://localhost:4000>, and the same Elixir
and Luerl app supervisors used by the device. A short shell command stands in
for an external KMS program so the display-handoff path can be exercised
without installing RetroArch or Moonlight. The Files column is rooted at
`tmp/host/files`, and the worked `hello` pickle is copied once into the
gitignored `.pickles` state so its graphical Lua app is present immediately.
`mix test` stays headless and starts none of these development-only children.

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
| [On-device data layout](docs/data-layout.md) | Which writable paths belong to MayonnaiOS, players, and removable media |
| [RetroArch internals](docs/retroarch-internals.md) | How cores, config and saves are kept honest across upgrades and pulled power |

## The three repositories

| | |
|---|---|
| [`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) | The Buildroot BSP: kernel, device tree, U-Boot, fwup layout. |
| `mayonnaios` | This one: the OTP release and the bundle mechanism. |
| [`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) | Cross-builds the native apps — RetroArch and its cores, Moonlight — against the system's own sysroot; publishes checksummed tarballs. |
