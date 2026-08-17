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

A working device, not a finished product. The line between "verified on the
hardware" and "written but unproven" is kept deliberately, because the most
expensive mistakes in this project have all been assumptions reported as
observations.

**Verified on the device:**

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

**Not yet verified:**

- **The handoff.** RetroArch launches and runs, but nobody has watched it exit
  and Scenic resume with the panel intact. `Launcher` pushes the viewport after
  a program exits, because Scenic only writes `/dev/fb0` when its graph
  changes — but that is code, not evidence.
- **A core installed from the device's own UI.** The install path is proven
  against the real release from a host; not yet by pressing the button.
- **The games card as a library.** It mounts. Nothing mounts it at boot, and
  `Library` still reads `/root/roms`.

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

Every mechanism was forced by what the image actually contains, which was
checked rather than assumed:

    tar absent   xz absent   gzip absent   curl absent   wget absent

There is no archive tool and no HTTP client on this device. Fetching is
`:httpc`, unpacking `:erl_tar`, hashing `:crypto` — all OTP, present because the
BEAM is. `:erl_tar` reads gzip and not xz, which is the only reason bundles are
`.tar.gz`.

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

Y is deliberately unbound. It played an audio test while audio was the open
question on this board; that question is answered, and a key that makes a noise
when brushed in a pocket is not worth keeping.

### Getting games onto it

Open the device's hostname from a phone on the same WiFi:

    http://nerves-<serial>.local/

Pick a file and it uploads. The page also lists the cores RetroArch can see and
offers to install catalogued ones.

There is **no authentication**. Anything on the same network can upload a ROM,
delete one, or install a core — the same trust model as a printer's web page,
which is defensible on a home network and is a decision rather than an
oversight. What keeps it from being worse is `MayonnaiOS.Library`: uploads land
only in configured system directories, and filenames that could escape them are
*rejected* rather than repaired, because a repair silently accepts a request
that was trying to escape.

Uploads stream to disk as the raw body of a `PUT` rather than being posted as a
multipart form, because `Plug.Upload` writes to `/tmp`, `/tmp` here is a tmpfs,
and a 700 MB disc image would go through RAM on a board with 1 GB of it.

`scp` also works, over the SFTP subsystem. Plain `scp`, never `scp -O`, which
forces a legacy protocol needing an `scp` binary the device does not have.

### From IEx

SSH gives an IEx prompt, not a shell:

    iex> MayonnaiOS.Bundle.install(MayonnaiOS.Bundle.spec(:retroarch))
    iex> MayonnaiOS.Cores.install(:snes9x2010)
    iex> MayonnaiOS.Cores.sync()
    iex> MayonnaiOS.Library.index()
    iex> MayonnaiOS.Audio.run()          # plays a test tone

## Where things live on the device

    /                              read-only squashfs, A/B pair
    /root                          f2fs, writable, mounted exec
    /root/bundles/<name>/<version> installed bundles, with a `current` symlink
    /root/cores/<name>/<version>   separately installed cores
    /root/retroarch/cores          symlinks; RetroArch's libretro_directory
    /root/retroarch/{saves,states} RetroArch's writable directories
    /root/roms/<system>            the game library

Anything written there needs an `fsync`. There is no `sync` on this device —
not the binary, not a busybox applet — and a handheld gets switched off by
holding a button. A set of ROMs was lost to exactly that once, so
`Library.receive_upload/4` calls `:file.sync/1` before closing.

## The three repositories

| | |
|---|---|
| [`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) | The Buildroot BSP: kernel, device tree, U-Boot, fwup layout. |
| `mayonnaios` | This one: the OTP release and the bundle mechanism. |
| [`retroarch-rg40xxv`](https://github.com/kek/retroarch-rg40xxv) | Cross-builds RetroArch and cores against the system's own sysroot; publishes checksummed tarballs. |

RetroArch is built in its own repository rather than as a Buildroot package
because Nerves passes exactly one `BR2_EXTERNAL` tree and bind-mounts only
`nerves_system_br` and the system package — a package in a sibling repository is
invisible to the build. The answer was not to relocate the package but to stop
making it one.

The board support earns its own repository too: the RG40XXV is LPDDR3 where the
RG35XX H700 defconfig says LPDDR4, and DRAM init is compiled into SPL, so an
image for one cannot boot the other. That sits below any runtime selection,
which is why `nerves_system_rg40xxv` keeps a conventional name forever while the
portable half gets the interesting one.

## Portability

The mechanism is not board-specific: the supervision tree over external
programs, the bundle format, the `current` symlink upgrade and rollback, the
library, the upload UI. What is board-bound, and would want a per-target
configuration module, is the evdev codes and button layout, the panel resolution
and rotation, the AXP717 sysfs paths for battery and backlight, and the writable
partition being f2fs at `/root`.

Other H700 Anbernics are the obvious near neighbours. The `rpi5` and `x86_64`
targets in `mix.exs` exist for host and CI development and should not shape the
abstraction.

## The name

Mayonnaise already ends in the sound "OS", so the suffix is swallowed rather
than bolted on — unlike MustardOS, which is Name+OS. Lowercase `mayonnaios` is
used for anything that becomes a path, a URL, an atom or a filename;
`MayonnaiOS` is the module namespace and the spelling for humans.

Every thematically apt name turned out to be taken, several times, in this exact
domain: Calypso, Argos and Albatross all collide, and AlbatrOS is specifically a
games-console Linux distribution. The absurd one was free, which is roughly the
point.
