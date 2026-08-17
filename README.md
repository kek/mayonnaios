# MayonnaiOS

Firmware for the Anbernic RG40XXV handheld, written in Elixir on
[Nerves](https://nerves-project.org/).

What muOS and ROCKNIX do with shell scripts, this does with a BEAM supervision
tree. There is no init system, no shell on the console and no package manager:
PID 1 is `erlinit`, and the supervision tree *is* the process model of the
machine. An emulator that dies becomes a restart strategy rather than a black
screen.

Board support lives in a separate repository,
[`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv). This
one is the application: the launcher, the diagnostics, and the mechanism that
gets emulators and games onto the device.

## Status

| | |
|---|---|
| Display | 640×480 panel, Scenic through `cairo-fb` |
| GPU | Mali-G31 MC1 via Panfrost, GLES 3.1, Mesa 26.1.2 |
| Emulation | RetroArch 1.22.2 running a SNES game at 60.10 fps |
| Gamepad | evdev on `event0`, autoconfig accepted by RetroArch |
| Audio | speaker confirmed; boots muted at 0% by design |
| Battery | charge and discharge, both directions |
| Thermal | four zones |
| WiFi | RTL8821CS |
| Bluetooth | controller init, firmware `0x75b8f098` |
| USB gadget | SSH over `usb0` |
| Second SD slot | a 125 GB card enumerates as `mmcblk2` |
| exFAT | a real muOS-formatted card mounts and reads |
| Upload UI | serving on port 80 |

## How it is put together

### Firmware is not content

The rootfs is a read-only squashfs, written whole on every update, in an A/B
pair. Emulators and games do not belong in it: a core update should not reflash
an operating system.

So RetroArch, its cores and your ROMs live on the writable f2fs partition at
`/root`, and `MayonnaiOS.Bundle` puts them there — fetch, **verify the SHA-256
before unpacking**, install into a versioned directory, move a `current`
symlink. Versioned directories mean an install never overwrites the running copy
and a rollback is a symlink move.

The checksums live in `config/target.exs`, in the firmware. A checksum served
from beside the file it describes is not evidence about anything.

### Cores belong to the application, not to the bundle

RetroArch reads cores from exactly one `libretro_directory`, and pointing that
inside the RetroArch bundle makes every core the property of that bundle
version — install one, upgrade RetroArch, and it is gone.

So `/root/retroarch/cores` sits outside every bundle, and `MayonnaiOS.Cores`
rebuilds it from symlinks at each boot: from the cores RetroArch ships and from
any installed separately. It clears before it links, so a core that vanished
upstream cannot survive as a dangling symlink that RetroArch offers and then
fails to load.

### The supervision tree, in order

The order is deliberate and it is about diagnosing a boot that fails. Each entry
is a way of finding out what happened when the one after it never runs.

    Heartbeat        earliest sign of life; needs nothing but sysfs
    USBGadget        the way back in when WiFi does not come up
    Audio.Startup    mixer to 0% and muted, so the device starts silent
    Diagnostics      battery, thermal, RTC, Bluetooth, mixer; owns the volume
                     keys and the headphone-jack switch
    Cores.Startup    relinks the core directory
    Web              the upload page
    Launcher         owns event0 and runs external programs
    BootDiagnostics  last: it reports on a boot that has already happened

## Getting started

The WiFi credentials come from the environment. They are deliberately in no
file, so firmware built without them fails rather than producing an image that
cannot be reached — this device has no accessible serial console, and
unreachable firmware means reflashing the card by hand.

    export RG40XXV_WIFI_SSID="your-ssid"
    export RG40XXV_WIFI_PSK="your-psk"

    export MIX_TARGET=rg40xxv
    mix deps.get
    mix firmware

Then burn a card:

    mix burn

or push to a device that is already running:

    mix upload nerves-<serial>.local

`mix deps.get` downloads the system from its GitHub releases. If no release
matches the tree's checksum it falls back to building Buildroot from source,
which takes about three and a half hours — so a build that looks hung probably
is not.

### On the host

Without `MIX_TARGET`, everything builds for your laptop, which is where the
tests run:

    mix test

98 tests, no hardware required.

## Using the device

### Buttons

As printed on the shell, not as the device tree labels them. This board's device
tree is wrong about A/B *and* about X/Y, so these were established by pressing
them.

    D-pad up/down   move the cursor
    A               launch the selected program
    Menu            back to the home screen
    X               diagnostics readout
    Select + Menu   power off

Menu is the one way out: it stops a running program if there is one and
otherwise leaves diagnostics, so the same press always means "put me back where
I started". The power-off chord is tested first, so a bare Menu can never shut
the device down.

### Getting games onto it

Open the device's hostname from a phone on the same WiFi:

    http://nerves.local/

Pick a file and it uploads. The page also lists the cores RetroArch can see and
offers to install catalogued ones.

There is **no authentication**. Anything on the same network can upload a ROM,
delete one, or install a core — the same trust model as a printer's web page,
which is defensible on a home network and is a decision rather than an
oversight. What keeps it from being worse is `MayonnaiOS.Library`: uploads land
only in configured system directories, and filenames that could escape them are
*rejected* rather than repaired, because a repair silently accepts a request
that was trying to escape.

## The three repositories

| | |
|---|---|
| [`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) | The Buildroot BSP: kernel, device tree, U-Boot, fwup layout. |
| `mayonnaios` | This one: the OTP release and the bundle mechanism. |
| [`retroarch-rg40xxv`](https://github.com/kek/retroarch-rg40xxv) | Cross-builds RetroArch and cores against the system's own sysroot; publishes checksummed tarballs. |
