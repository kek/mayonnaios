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
  device already has, with forgetting one moved off the IEx prompt and onto
  the handheld
- RetroArch, with cores installed and upgraded independently of the firmware
- Checksum-verified bundle install, with versioned directories and rollback
- A web UI for uploading games from a phone
- A file manager on the device: copy, move, rename and delete across both
  cards, with a clipboard instead of a destination to type
- Pickles: small sandboxed Lua apps, installed over the network like games,
  for things like controlling lamps on the LAN or polling a web API. See
  [docs/pickles.md](docs/pickles.md)
- Sleep on the power button: the backlight goes off and any button brings it
  back. Not suspend — only `s2idle` exists here, it aborts inside rtw88's SDIO
  suspend handler, and with no cpuidle driver the cores are in a bare WFI
  either way, so a successful one would save almost nothing
- Orderly power off, two ways: the Select+Menu chord, and a **Power off** row
  at the bottom of the menu — A asks, Y answers, anything else keeps it on,
  which is the file manager's delete rule applied to the other irreversible
  thing on the device

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
under
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

### Pickles

Small Lua apps -- lamp remotes, API pollers -- run sandboxed inside the
firmware and install the same way games do:

    tar -czf hello.tar.gz -C pickles/hello .
    curl -T hello.tar.gz http://nerves.local/api/pickles/hello

What a pickle can touch is declared in its manifest and enforced by the
sandbox: HTTP, the local network, a small persistent store, timers, the
panel -- and nothing else. A pickle with the `ui` capability appears on the
launcher menu and draws on the screen; the others run headless.
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

Pick **Files** in the launcher. It opens on a short list of the places worth
looking at — the ROM roots from `:rom_roots`, the installed bundles, the
installed cores, and `/root` — and browsing starts inside one of them. It is an
app rather than a program: a module in this firmware, no external process, no
screen handed over.

    D-pad up/down     move
    D-pad left/right  a screen at a time
    A                 open a directory, or the actions for a file
    B                 back
    Y                 the second verb; the bottom line says what it is
    Menu              leave

Copy, move, rename and delete. Copy and move are a clipboard, because there is
nothing to type a destination with: pick the file, walk to where it should go,
press Y and paste it. Renaming is a character picker for the same reason —
slow, and reachable from the device, which a text field would not have been.

Nothing overwrites. A destination that already exists is refused rather than
replaced, because on this device the file being replaced is somebody's save.

**Deleting asks, and the answer is not the button that asked.** A opens the
confirmation and **Y** carries it out; A cancels, as does B and as does any
direction. There is no undo and no trash on a handheld that is switched off by
pulling its power, so a second press of the same button would not be a
confirmation. A directory with anything in it is refused outright.

Free space is shown for the filesystem the current directory is on, not for the
device: the roots span the writable partition and, with a card in, the games
card, and one number would be wrong for whichever it was not measuring. `/` is
a full read-only squashfs and is not reachable from the app at all.

Every copy is fsynced before it counts as done — there is no `sync` on this
device, and an unsynced write survives exactly as long as the page cache. Bytes
go to a `.part` file beside the destination, get fsynced, and are then renamed
into place, so an interrupted copy leaves a `.part` rather than a ROM that
looks complete and fails three hours into a game.

Paths are built from a root key and checked names; nothing takes a path.
`MayonnaiOS.Files` rejects a name rather than cleaning it, the same line
`MayonnaiOS.Library` takes for uploads, and its moduledoc has the one honest
caveat: symlinks already in the tree are followed for reading, because
`bundles/retroarch/current` is one and the core directory is nothing but them.
Deleting a link removes the link and never its target.

This has been run on the handheld. Behind it are 76 host tests and a target
compile; the panel layout was checked as a graph before it was checked on the
glass.

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
[`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) against the same
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
broken once per launch — which is what RetroArch bundles up to v1.22.2-5 did,
naming `/root/retroarch/cores`, a directory nothing fills.

So a second config is appended after the bundle's own, and `--appendconfig`
merges its files in order, last one winning.
`MayonnaiOS.Cores.write_append_config/0` generates it from `MayonnaiOS.Cores.dir/0`
at boot, so it always names the directory the symlinks actually go into.

That same file carries `audio_sync = "false"`, which is not a preference about
audio but a guard: a stalled codec otherwise freezes the game inside `poll()`,
and nobody can reach RetroArch's audio menu while the game is frozen. It is
scrubbed out of the player's own config at every boot by
`MayonnaiOS.Cores.clear_persisted_audio_sync/0`, for the reason the next section
gives for `autosave_interval` — so the day the codec is trustworthy, deleting
one line is enough, and no device is left carrying a setting no file in any
repository still contains.
The bundle has since been fixed: v1.22.2-6 and later set no core directory at
all, and the RetroArch workflow in
[`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) asserts that they
do not. The appended config stays regardless, because a bundle is versioned
separately and installed independently — a value persisted by an older bundle
outlives that bundle, and no later bundle can withdraw it.

### Saves

RetroArch writes a game's SRAM every ten seconds
(`autosave_interval`), and this firmware asserts that in the same
appended config as the core directory — because the device was found with
`autosave_interval = "0"`, RetroArch's own default, which writes the `.srm`
only when content closes cleanly. On a handheld with no clean shutdown, that
means a kill or a pulled cable discards every in-game save made since the ROM
was loaded. It did, repeatedly, to a Chrono Trigger file.

Ten seconds costs almost nothing in writes: RetroArch compares the SRAM
against its last copy and writes only when it differs, so the interval decides
how *soon* a save reaches the card, not how often anything is written.

The setting is scrubbed out of the player's own config at every boot by
`MayonnaiOS.Cores.clear_persisted_autosave/0`, for the same reason
`libretro_directory` is: RetroArch persists whatever `--appendconfig` supplied
as though the player had chosen it, so without the scrub, a value could not be
changed later by any firmware. Changing the interval is editing one line;
there is no device to go and repair afterwards. The cost is that this firmware
owns the setting — changing it in RetroArch's Saving menu does not survive a
reboot.

RetroArch flushes those writes to the kernel and never fsyncs them, and there
is no `sync` on this device, so `MayonnaiOS.Saves.flush/1` fsyncs the save
files at the two moments the launcher knows the program is *gone*: when it is
reaped, and when a deliberate stop has confirmed the process died. A stop that
could not confirm it — the one that reports `{:error, {:still_running, pid}}`
— does not flush. Deliberately: fsyncing while a game runs could catch an
autosave between its truncate and its write, which is the one way this could
destroy the file it exists to protect. A cable pulled mid-game is covered by
the interval and by f2fs writeback, and by nothing else.

## Game streaming (Moonlight)

Moonlight Embedded streams a Sunshine or GeForce host to the handheld —
decoded in software on the A53s and drawn through SDL on the same KMS stack
RetroArch uses. It installs the same way RetroArch does, as a bundle:

    iex> MayonnaiOS.Bundle.install(MayonnaiOS.Bundle.spec(:moonlight))

The menu row exists before the bundle does; until the install it renders as
not installed.

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
[`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) README lists what
only hardware can answer — the software decode budget and the gamepad mapping
under SDL first among them.

## Using it as a Bluetooth controller

The handheld can be the gamepad instead of the console. Pick **Bluetooth
controller** in the launcher and it advertises itself as an Xbox Wireless
Controller — Microsoft's numbers, the real pad's name, and that pad's HID
descriptor byte for byte; pair from a Steam Deck, a Mac, a Windows machine, a
phone or anything else that speaks HID over GATT, and every button and the
stick go there instead of to the launcher. Menu comes back.

The identity is the point. An earlier firmware said honestly who it was, and
this section was a page of workarounds for what that honesty cost: SDL
matches controllers against a database keyed by vendor and product numbers,
an unlisted device is a joystick rather than a gamepad, and a game that asks
only for gamepads saw nothing at all — with Steam on macOS unable to bridge
the gap, because it has no virtual controller there to bridge it with.
Claiming the identity of the one pad every host tests against gets all of
those code paths for free: recognised on sight, correct glyphs, no mapping
step. `MayonnaiOS.Controller.Report` has the full account, including why the
borrowed layout must be byte-exact and the test that pins all 283 bytes of
it against a capture from a real pad.

The panel shows how far along it is, because the four stages all look
identical from the other machine — a controller that does nothing:

    Advertising            on the air, nobody has connected
    Host connected         a host is talking to us, still in the clear
    Paired and encrypted   the HID service is readable
    Reports subscribed     the host is receiving button presses

If it stops at *connected*, the pairing was not finished on the host. If it
stops at *paired*, the host has not decided the device is a gamepad.

### Pairing

**Steam Deck**: Settings → Bluetooth, and it appears as `Xbox Wireless
Controller` with a gamepad icon. SteamOS knows exactly what that is: Xbox
glyphs, working defaults, nothing to map.

**Windows**: Settings → Bluetooth & devices → Add device → Bluetooth. It
pairs without a code — see below for why there is no code — and comes up as
an Xbox controller.

**macOS**: System Settings → Bluetooth. The GameController framework has
first-class Xbox support, so anything built on it — Steam included — sees a
pad it knows. The one macOS-specific trap is in the next section.

What the host receives: the left stick, the D-pad as a hat switch, A/B/X/Y
by their printed labels, LB and RB from L1 and R1, the triggers fully pulled
or fully released from L2 and R2 — they are switches on this shell — and
View and Menu from Select and Start. **Select and Start held together are
the Xbox button**, which on a Steam Deck is the Steam button; the first
half-pressed leaks one brief View or Menu press while the chord forms, and
`MayonnaiOS.Controller.Report` has the account of why that beats a timer. The right stick, the stick clicks, the
Share button and the Xbox button are declared because the real pad declares
them, and they rest untouched forever; rumble is accepted from the host and
dropped, because there is no motor and a refused write reads as a fault
where a silent one reads as a dead motor.

**This firmware update means re-pairing, on every host.** A host reads the
report descriptor once, when it pairs, and caches it forever after — so a
host paired with the previous firmware's three-byte pad will parse the new
sixteen-byte reports against the old layout and report garbage with total
confidence. Remove the device on the host and run
`MayonnaiOS.Controller.unpair()` here; the same applies to any future
descriptor change.

### When a game does not see it

On macOS, check that Steam — or the game — has **Input Monitoring**
permission, in System Settings → Privacy & Security. Enumerating HID devices
needs no permission on macOS but *receiving input from them* does, so an
application without it shows the controller in its device list and then
behaves as though every button were stuck up. Steam has to be quit
completely and reopened after the permission is granted. This looks exactly
like a broken controller and is not one — the browser gamepad testers work
throughout, because the browser has the permission.

Everything else this section used to prescribe — Steam's generic-gamepad
switch, per-game keyboard bindings, hand-rolled `SDL_GAMECONTROLLERCONFIG`
lines — was the cost of not being recognised, and went with the cause. What
is still true: a game with no controller support at all still has none, and
Steam Input on macOS still cannot fabricate a virtual controller for such a
game. It never could; this device just no longer needs it to.

### What claiming the identity costs

The previous firmware refused to borrow a real controller's numbers, and the
reason it wrote down was correct: a host with a driver for the claimed pad
stops reading the descriptor and parses reports against that pad's fixed
layout, so any deviation is scrambled buttons the host is certain are
correct. That is an argument against claiming the numbers while shipping
your own layout. It is not an argument against shipping the layout too,
which is what this firmware does — the drivers' fixed belief is now a
correct belief, and the test suite holds the descriptor byte-for-byte
against a capture from a real pad, so a drift is a failing test rather than
a scrambled A button.

What is genuinely given up: the device now says it is something it is not,
to hosts and to anyone reading a Bluetooth device list, and controls it does
not have — the right stick, rumble — are promised and permanently inert. A
host that someday probes deeper than any known host does, say for firmware
versions over Microsoft's accessory protocol, will find the seams; nothing
on macOS, SteamOS, Windows or a phone does that today. The trade is written
down here rather than left implicit, because it was made on purpose and the
thing bought with it is the section above shrinking to one paragraph.

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
      name: "Xbox Wireless Controller", address: "...", sent: 0,
      dropped: %{disconnected: 0, unencrypted: 0, unsubscribed: 0, no_credits: 0},
      ...}
    iex> MayonnaiOS.Controller.stop()

`sent` climbing while buttons are pressed is the proof that reports are going
out. The `dropped` counters say why they are not: `unsubscribed` for the first
second of every connection is normal, `no_credits` is not.

### There is no BlueZ on this device, and none was added

The whole stack is Elixir, on top of the raw HCI user channel that
`MayonnaiOS.Bluetooth.HCISocket` already used for the diagnostics probe —
L2CAP, ATT, GATT, the HID profile and the pairing, some forty-seven hundred
lines under `lib/mayonnaios/bluetooth/`. Nothing was added to the Buildroot
system and no kernel option was changed.

That is not a stunt. `# CONFIG_BT_LE is not set` in this kernel's config
means the in-kernel Bluetooth stack does no LE at all, so the ordinary route
— BlueZ over the kernel's own L2CAP sockets — would have needed a BSP change
and a full Buildroot rebuild. A user channel switches the
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

### When hci0 is not there at all

`:enodev` is a fault, and an intermittent one. The Bluetooth half of the
RTL8821CS is UART-attached, so the kernel binds `hci_uart_h5` to a serdev
child of `serial@5000400` and that bind is what produces hci0, eleven seconds
into an ordinary boot. Once, on 2026-08-25, it did not: the driver was bound,
`/sys/class/bluetooth` was empty, and `dmesg` for the whole boot carried not
one RTL line — no probe error, no timeout, nothing to read. Both Bluetooth
apps then fail to start with `:enodev`, which from the couch is a menu entry
that does nothing.

Rebinding the driver fixes it, and `MayonnaiOS.Bluetooth.Host` now does that
once before reporting `:enodev`, so the device recovers without a reboot and
without SSH. `MayonnaiOS.Bluetooth.Serdev` has the account. By hand it is:

```elixir
iex> MayonnaiOS.Bluetooth.Serdev.revive()
:ok
```

Why the bring-up occasionally no-ops in silence is not understood. The
recovery is verified; the cause is still open.

What is deliberately not implemented is LE Secure Connections; a central that
asks for it is answered with a pairing response that does not offer it, and
every host tested falls back to legacy pairing. A host in Secure Connections
Only mode would answer `Pairing Failed 0x03` instead, and
`MayonnaiOS.Bluetooth.SMP`'s moduledoc says what adding it would take.

## Seeing what Bluetooth is nearby

Pick **Bluetooth devices** in the launcher. It runs an active LE scan and
lists what answers — name, signal strength, rows ageing out as devices stop
advertising — alongside the bonds this device already holds. **A** arms a row
and a second **A** forgets it, which is the one action on the screen. That is
the reason it exists: undoing a pairing was an IEx call until now, which made
the only way to forget a host on a handheld with no keyboard an SSH session
from another machine.

**It does not connect headphones, and the first line on the screen says so.**
Bluetooth audio is A2DP, which runs over BR/EDR and needs, in order: BR/EDR
HCI, connection-oriented L2CAP, an SDP client, AVDTP signalling, an SBC
encoder, and something to route a game's audio into the stream. None of those
are here — `MayonnaiOS.Bluetooth.HCI` implements no BR/EDR command at all, and
there is no PulseAudio, PipeWire or `bluez-alsa` in the image either. So the
app scans and lists rather than offering a Connect button, and
`MayonnaiOS.Bluetooth.Scan` reads the BR/EDR flag out of each advertisement so
that the row for a pair of headphones says which transport it would need.
`MayonnaiOS.Pairing` has the full account.

It holds hci0 for as long as it runs, so it and the controller app are
mutually exclusive; the launcher's one-app-at-a-time rule is what enforces
that, which is why both are menu entries and neither is in the boot
supervision tree.

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
| `c` | X — the diagnostics screen |
| enter | Menu — back to the home screen |
| backspace | Select |
| `p` | the power button — sleep, and any key wakes it |
| escape | Select+Menu, the power-off chord |

`x`, `v` and `s` are sent too, as B, Y and Start, and do nothing — the launcher
binds none of them. Left and right do nothing on the home screen either, whose
menu is one column, but they reach whatever app the launcher has handed the
buttons to: the Files app pages a screenful at a time with them. None of this
is conditional on the target, so a USB
keyboard plugged into the handheld gets the same bindings. `p` is the one key
that is not a pad button: it sends `KEY_POWER`, which on the device arrives
from `axp20x-pek` rather than from the gamepad.

Rendering on the host goes through `scenic_driver_local`'s cairo-gtk backend,
which wants `gtk+3`, `cairo`, `pkgconf` and, on macOS, XQuartz. On the device
the same scene code draws straight into `/dev/fb0` instead; the backend follows
`MIX_TARGET`, so nothing in the scenes changes.

The web UI runs on the host as well — point `:rom_roots` and the other paths at
a scratch directory and start `MayonnaiOS.Web` under a supervisor.

## Not done yet

**Initiating a pairing.** The Bluetooth devices app finds what is nearby and
manages the bonds this device already has — but every one of those bonds was
made by a host pairing *to* the handheld. Pairing outward, this device
choosing something and bonding with it, is the central role and is not here.

Below the roles, nothing has to change: `Bluetooth.Host`, the HCI codec, L2CAP
framing and the pairing arithmetic are all role-independent, and the scan that
would find the device to pair with already runs. What is missing is the half
of each protocol that faces the other way — `MayonnaiOS.Bluetooth.SMP` answers
a pairing today and would need the initiator half of one, and
`MayonnaiOS.Bluetooth.GATT` is a server where a central needs a client.

**The profiles after it**, which are the expensive part, because a bonded
device does nothing until there is a profile to use it with. Audio means A2DP:
SDP, AVDTP and an SBC encoder over a BR/EDR transport this firmware does not
have, and then a way to route a game's audio into the stream, which means
another package in the image and therefore a system rebuild. A paired gamepad
means a HID host and then some way to present it to Linux as an input device,
since RetroArch reads evdev and nothing in this VM can hand it a device node
without the kernel's help.

Worth deciding one at a time whether each is worth having. The app is built so
that adding one is a profile under `MayonnaiOS.Bluetooth` and a row action in
`MayonnaiOS.Scene.Pairing`, and nothing else has to move.

## The three repositories

| | |
|---|---|
| [`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) | The Buildroot BSP: kernel, device tree, U-Boot, fwup layout. |
| `mayonnaios` | This one: the OTP release and the bundle mechanism. |
| [`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) | Cross-builds the native apps — RetroArch and its cores, Moonlight — against the system’s own sysroot; publishes checksummed tarballs. |
