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
- A Bluetooth LE gamepad, so the handheld can be the controller for a Steam
  Deck or a PC — a whole BLE HID stack in Elixir, with no BlueZ in the image
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

If RetroArch shows *no* cores at all, the cause is a `libretro_directory`
pointing somewhere nothing fills. RetroArch takes that setting verbatim — it
does not check that the directory exists, the way it does for the save
directories — so the symptom is an empty list and nothing in the log.

Two things put it there, and they need different answers.

A value **left in the player's own config** by an older bundle is removed by
`MayonnaiOS.Cores.clear_stale_directory/0`, which also runs at boot.

A value **the installed bundle sets** is the harder one, because the launcher
passes that bundle's config with `--appendconfig` on every launch. Clearing at
boot then loses: the launch appends the value again, RetroArch reads it, and
writes it back into the player's config on exit. Repaired once per boot,
broken once per launch — which is exactly what the RetroArch bundle installed
here does, naming `/root/retroarch/cores` in a comment block that refers to a
module this project renamed away from.

So a second config is appended after the bundle's own, and `--appendconfig`
merges its files in order, last one winning.
`MayonnaiOS.Cores.write_append_config/0` generates it from `MayonnaiOS.Cores.dir/0`
at boot, so it always names the directory the symlinks actually go into.
Fixing the bundle would be tidier and is worth doing in
[`retroarch-rg40xxv`](https://github.com/kek/retroarch-rg40xxv) — but a bundle
is versioned separately and installed independently, so relying on it to *not*
set something is the arrangement that already failed once.

## Using it as a Bluetooth controller

The handheld can be the gamepad instead of the console. Pick **Bluetooth
controller** in the launcher and it advertises itself as a BLE HID gamepad;
pair from a Steam Deck, a Windows machine, a phone or anything else that
speaks HID over GATT, and every button goes there instead of to the launcher.
Menu comes back.

The panel shows how far along it is, because the four stages all look
identical from the other machine — a controller that does nothing:

    Advertising            on the air, nobody has connected
    Host connected         a host is talking to us, still in the clear
    Paired and encrypted   the HID service is readable
    Reports subscribed     the host is receiving button presses

If it stops at *connected*, the pairing was not finished on the host. If it
stops at *paired*, the host has not decided the device is a gamepad.

### Pairing

**Steam Deck**: Settings → Bluetooth, and it appears as `MayonnaiOS
Controller` with a gamepad icon. Steam Input treats it as a generic
controller, so the buttons want mapping once, per game or globally.

**Windows**: Settings → Bluetooth & devices → Add device → Bluetooth. It
pairs without a code — see below for why there is no code — and shows up in
`joy.cpl` as a 10-button gamepad with a hat switch.

The D-pad is a hat switch and nothing else. It was briefly also reported as
a pair of X/Y axes, so that games which only read a stick would work; on a
Mac that made Steam take the axes for a stick and drive the mouse pointer
with them, so a D-pad press moved the character *and* the cursor at once.
One control declared twice gets consumed twice.

**Changing the report descriptor means re-pairing.** A host reads it once,
when it pairs, and caches it forever after — so a firmware update that
changes the button layout does nothing at all until the device is removed on
the host and `MayonnaiOS.Controller.unpair()` has run here. Reports parsed
against a stale descriptor are worse than no change: the bytes have moved
underneath the host.

### When a game does not see it

Pairing and connecting are one thing; a game deciding this is a controller
is another, and the second is entirely up to the host.

On macOS, check first that Steam has **Input Monitoring** permission, in
System Settings → Privacy & Security. Enumerating HID devices needs no
permission on macOS but *receiving input from them* does, so an application
without it shows the controller in its device list and then behaves as
though every button were stuck up. Steam has to be quit completely and
reopened after the permission is granted. This looks exactly like a broken
controller and is not one — the browser gamepad testers work throughout,
because the browser has the permission.

Steam also has a switch for generic gamepads in its controller settings, and
it is not on by default. Without it an unrecognised pad reaches Steam's desktop
layout — which is what moves the mouse and types arrow keys — rather than
the game. With it on, the pad can be given a layout like any other
controller.

A game that uses SDL, which is most of them, needs more than that. SDL's
controller API matches a device against a database keyed by its USB vendor
and product numbers, and this device's are not in it — so SDL sees a
joystick rather than a game controller, and a game that only asks for game
controllers sees nothing at all.

### On macOS, Steam Input cannot bridge that gap

This one is worth knowing before spending an evening on it. If the pad
drives Steam's Big Picture interface but no game responds, nothing is
broken and no amount of Steam configuration will change it.

Steam Input feeds a game by emulating a controller the game already
understands — an Xbox pad through a driver on Windows, a virtual device
through uinput on Linux. macOS offers Steam neither, so for a game that does
not integrate the Steam Input API directly, Steam's only outputs are
keyboard and mouse. Turning "Enable Steam Input" on for such a game changes
nothing, because there is no virtual controller for it to switch on.

Two things work, and both are configured on the Mac rather than here:

- Bind the pad to the game's *keyboard* controls in its Steam controller
  configuration. Keyboard emulation is the output path macOS does allow.
- Give the game an SDL mapping. `gamepadtool` generates the whole
  `SDL_GAMECONTROLLERCONFIG` line by asking you to press each button; it
  goes in the game's launch options, and the game's own SDL then sees a
  proper gamepad with Steam uninvolved. The same line submitted to SDL's
  community database fixes it everywhere, permanently, for anyone.

Claiming a well-known controller's vendor and product numbers would also
work, and for the same reason — it makes SDL recognise the device without
Steam in the middle. `MayonnaiOS.Bluetooth.HOGP` deliberately does not.
Where the impersonated controller has a driver rather than just a database
entry, as Xbox and PlayStation pads do, the host stops reading this
device's descriptor altogether and parses its reports against that
controller's fixed layout — so the whole report format would have to be
reproduced, and a mistake in it produces scrambled buttons that the host is
certain are correct. An SDL mapping reaches the same place without any of
that, and without a device that lies about what it is.

Pairing is *Just Works*: no passkey, no confirmation, exactly like every
commercial BLE gamepad. That means no protection against someone active on
the air at the moment of pairing. It is written down here rather than left
implicit, because it is a real property of the device and the reason it is
acceptable is that the link carries button presses.

Once paired the keys are kept, so the next connection needs nothing. To
undo it, forget the device on the host **and** clear the keys here:

    iex> MayonnaiOS.Controller.unpair()

Doing only one of the two leaves a host that reconnects, cannot decrypt, and
reports a broken device.

### From IEx

    iex> MayonnaiOS.Controller.start()
    iex> MayonnaiOS.Controller.status()
    %{advertising: true, connected: false, encrypted: false, subscribed: false,
      name: "MayonnaiOS Controller", address: "...", sent: 0,
      dropped: %{disconnected: 0, unencrypted: 0, unsubscribed: 0, no_credits: 0},
      ...}
    iex> MayonnaiOS.Controller.stop()

`sent` climbing while buttons are pressed is the proof that reports are going
out. The `dropped` counters say why they are not: `unsubscribed` for the first
second of every connection is normal, `no_credits` is not.

### There is no BlueZ on this device, and none was added

The whole stack is Elixir, on top of the raw HCI user channel that
`MayonnaiOS.Bluetooth.HCISocket` already used for the diagnostics probe —
L2CAP, ATT, GATT, the HID profile and the pairing, about fifteen hundred
lines under `lib/mayonnaios/bluetooth/`. Nothing was added to the Buildroot
system and no kernel option was changed.

That is not a stunt. `# CONFIG_BT_LE is not set` in this kernel's config
means the in-kernel Bluetooth stack does no LE at all, so the ordinary route
— BlueZ over the kernel's own L2CAP sockets — would have needed a BSP change
and a three-and-a-half hour Buildroot rebuild. A user channel switches the
kernel stack off for that controller anyway and hands over raw HCI, so what
the kernel can and cannot do above HCI stops mattering: the controller is a
Bluetooth 5.0 dual-mode part and speaks LE perfectly well when asked
directly.

Everything above the socket is a pure function over binaries and is tested
on a laptop, including the pairing arithmetic — `c1` and `s1` are checked
against the sample data in the Core specification, which is the only way to
know the byte order is right. `mix test` covers it with no hardware.

While the app runs it holds hci0, so `MayonnaiOS.Diagnostics.probe_bluetooth/0`
answers `:eusers` until it is stopped. That is the same device being used for
something, not a fault.

What is deliberately not implemented is LE Secure Connections; a central that
asks for it is answered with a pairing response that does not offer it, and
every host tested falls back to legacy pairing. A host in Secure Connections
Only mode would answer `Pairing Failed 0x03` instead, and
`MayonnaiOS.Bluetooth.SMP`'s moduledoc says what adding it would take.

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

## Not done yet

**The analog stick.** The shell has one and nothing in this firmware can see
it. Linux is not being told it exists: the `adc-joystick` driver is not built
(`CONFIG_JOYSTICK_ADC`), there is no joystick node in the device tree, and no
ADC driver for the H700 for such a node to read. Confirmed on the device
rather than inferred: `InputEvent.enumerate/0` shows three input devices —
fifteen gamepad keys, two volume keys, the headphone switch — and no `ev_abs`
anywhere. No amount of work in this repository changes that; it is a device
tree node and two kernel options in
[`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv).

The reason it was missed is legible in the device tree itself. This board's
DTS extends mainline's `sun50i-h700-anbernic-rg35xx-plus.dts`, and the RG35XX
Plus has no stick — so the inherited description is complete and correct for
a device that is not quite this one. Everything the two boards share came
across; the one control they do not share is the one that is missing.

Once it is there, the work on this side is small and known. The Bluetooth
report descriptor gains X and Y axes fed by `ABS_X` and `ABS_Y`, taking the
report from three bytes back to five, and whichever input device the driver
creates has to be read alongside `event0` — `MayonnaiOS.Launcher` owns that
one today and would own the stick's too, forwarding both to the app.

Worth being precise about why those axes are correct when the ones removed in
the commit before this were a bug: the axes that had to go were the *D-pad*
reported a second time, so one press moved a character and a mouse cursor at
once. A stick reporting stick positions is not that.

**Pairing devices *to* the handheld.** The controller app is this device
advertising itself to a host — the peripheral role. Scanning for headphones or
another gamepad and pairing them to this device is the central role, and none
of it is here.

It is a separate app rather than a setting on the existing one, because very
little is shared. Scanning, connecting and pairing all run the other way
round: `MayonnaiOS.Bluetooth.SMP` answers a pairing today and would need the
initiator half of one, and `MayonnaiOS.Bluetooth.GATT` is a server where a
central needs a client. What does carry over unchanged is everything below
that — `Bluetooth.Host`, the HCI codec, L2CAP framing, and the pairing
arithmetic, which is role-independent.

Discovery itself is cheap: LE scanning is three HCI commands and an event, and
BR/EDR inquiry is much the same, so a list of what is nearby is a small piece
of work. The expensive part is what happens *after* pairing, because a bonded
device does nothing until there is a profile to use it with. Audio means A2DP,
which is SDP, AVDTP and an SBC encoder. A paired gamepad means a HID host and
then some way to present it to Linux as an input device, since RetroArch reads
evdev and nothing in this VM can hand it a device node without the kernel's
help.

So the honest first version of that app is discover, pair, and say what a
device claims to be — with the profiles as separate work after it, and worth
deciding one at a time whether each is worth having.

## The three repositories

| | |
|---|---|
| [`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) | The Buildroot BSP: kernel, device tree, U-Boot, fwup layout. |
| `mayonnaios` | This one: the OTP release and the bundle mechanism. |
| [`retroarch-rg40xxv`](https://github.com/kek/retroarch-rg40xxv) | Cross-builds RetroArch and cores against the system's own sysroot; publishes checksummed tarballs. |
