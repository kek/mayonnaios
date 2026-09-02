> **Documentation for current `trunk`; installed firmware may differ.**

# Build and flash firmware

There is **no supported prebuilt firmware image**. Building from source is the
only supported installation route for the Anbernic RG40XXV handheld.

## Prerequisites

- Elixir `~> 1.20`, as required by `mix.exs`, and a compatible Erlang/OTP. This
  repository does not currently pin an OTP version, so do not infer one from a
  contributor's machine.
- The Nerves bootstrap archive and normal Nerves host tools.
- A checkout of
  [`nerves_system_rg40xxv`](https://github.com/kek/nerves_system_rg40xxv) at
  `../nerves_system_rg40xxv` relative to this checkout. The dependency is a
  sibling path dependency, not a package Mix can substitute.
- At least one SSH public key matching `~/.ssh/id_{rsa,ecdsa,ed25519}.pub`.
- The initial WiFi SSID and WPA-PSK in `MAYONNAIOS_WIFI_SSID` and
  `MAYONNAIOS_WIFI_PSK`.
- An SD card that may be erased, and a card reader, for the first flash.

WiFi is currently the only verified remote-access path. The firmware implements
USB CDC-ECM gadget setup, but cable enumeration has not been observed on the
RG40XXV. Bad initial WiFi credentials can therefore require reflashing the card.

## First build

**Context: run from the MayonnaiOS repository on the build host.**

```console
$ export MAYONNAIOS_WIFI_SSID="your-ssid"
$ export MAYONNAIOS_WIFI_PSK="your-psk"
$ export MIX_TARGET=rg40xxv
$ mix deps.get
$ mix firmware
```

`config/target.exs` is evaluated even by target `mix deps.get`, so the SSH key
and both WiFi variables must exist before dependency retrieval. Because the
RG40XXV system is a path dependency, Mix must also be able to read the sibling
checkout. If Mix builds the system instead of using a published artifact, expect
a full Nerves/Buildroot build; changes in the system tree, including comments,
can change its artifact identity.

**Success:** `mix firmware` completes and reports the generated MayonnaiOS
firmware image. A missing-key, missing-environment-variable, or missing-path
error means no usable image was produced; fix that prerequisite rather than
bypassing the guard.

## Write the first SD card

Back up anything needed from the card. `mix burn` is destructive and asks which
detected device to write.

**Context: same target-configured build-host shell; insert the destination card.**

```console
$ mix burn
```

Read the detected device and confirmation prompt carefully. Do not guess a raw
device name or select a computer's system disk.

**Success:** Nerves reports that the firmware was burned successfully. Eject the
card cleanly, place it in the RG40XXV's first slot, and boot. The device should
join the configured network and answer at its unique mDNS hostname or, when only
one device advertises it, `nerves.local`.

If it does not join WiFi, recheck the build-time SSID/PSK and reflash. Do not
plan recovery around `usb0` until USB enumeration is physically verified.

## Upload later firmware over WiFi

Build the new firmware first with the same target and credential context. Then
upload only to a running device whose identity you have checked.

**Context: target-configured build-host shell, with the handheld awake and on the
same trusted WiFi network.**

```console
$ mix firmware
$ mix upload nerves.local
```

Use the device's unique hostname or IP address instead of `nerves.local` when
more than one Nerves device is present. Upload writes the inactive firmware
slot; Nerves' startup guard validates application startup and can roll back a
firmware that fails that guard. It cannot prove every UI or hardware feature is
healthy, so check the panel and the task you changed after reboot.

**Success:** the upload completes, the handheld reboots into the new firmware,
and the launcher starts. If SSH authentication fails, that firmware does not
contain the matching public key. If the device is unreachable because WiFi does
not work, reflash the SD card.

For board-support changes, use the owning repository's procedures rather than
copying them here; see [Repository responsibilities](repositories.md). For
ordinary host work, continue with [Develop on the host](development.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/build-and-flash.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
