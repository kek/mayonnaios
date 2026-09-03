> **Documentation for current `trunk`; installed firmware may differ.**

# RetroArch on this device: cores, config and saves

**Status: Verified runtime architecture.** RetroArch bundle operation,
checksum-verified core installation, generated compatibility configuration, and
the save policy have been observed on RG40XXV hardware. This page explains the
mechanics; owners should start with
[Upload games and install emulator cores](games-and-cores.md).

## Prerequisites and task boundary

- Install RetroArch and cores using the [games and cores guide](games-and-cores.md).
- Use [Manage files and storage](files-and-storage.md) before moving libraries or
  removing the second card.
- Use this page to diagnose core discovery, configuration layering, and save
  durability; do not treat internal paths as a replacement owner procedure.

## Where cores end up

RetroArch reads cores from its own default directory,
`/root/.config/retroarch/cores`, and no config file tells it to — that is the
default with nothing set. The directory holds symlinks; the real `.so` files
stay in the RetroArch bundle or under `/root/cores`. So upgrading RetroArch
cannot lose a core, and installing a core never writes inside a bundle.

`MayonnaiOS.Cores.install/1` downloads the tarball, checks its SHA-256
**before** unpacking anything, and installs into a versioned directory under
`/root/cores` with a `current` symlink — so an install never overwrites what
is running, and undoing one is a symlink move. The expected checksum is
compiled into the firmware, not fetched alongside the download: a checksum
served from the same place as the file it describes is not evidence of
anything.

`MayonnaiOS.Cores.sync/0` rebuilds the symlinks and runs at every boot, which
is what makes them follow `current` across an upgrade. Running it by hand is
safe.

RetroArch's own online core updater is compiled out of this build. The
libretro buildbot's cores are linked against a different glibc and sysroot
and will not load here; cores for this device are cross-built in
[`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles) against the
same sysroot as the rest of the system.

## When RetroArch shows no cores at all

The cause is a `libretro_directory` pointing somewhere nothing fills.
RetroArch takes that setting verbatim — it does not check that the directory
exists, the way it does for the save directories — so the symptom is an empty
list and nothing in the log.

Two things put it there, and they need different answers.

A value **left in the player's own config** by an older bundle is removed by
`MayonnaiOS.Cores.clear_stale_directory/0`, which also runs at boot.

A value **the installed bundle sets** is the harder one, because the launcher
passes that bundle's config with `--appendconfig` on every launch. Clearing
at boot then loses: the launch appends the value again, RetroArch reads it,
and writes it back into the player's config on exit. Repaired once per boot,
broken once per launch — which is what RetroArch bundles up to v1.22.2-5 did,
naming `/root/retroarch/cores`, a directory nothing fills.

So a second config is appended after the bundle's own, and `--appendconfig`
merges its files in order, last one winning.
`MayonnaiOS.Cores.write_append_config/0` generates it from
`MayonnaiOS.Cores.dir/0` at boot, so it always names the directory the
symlinks actually go into.

Bundles v1.22.2-6 and later set no core directory at all, and the RetroArch
workflow in [`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles)
asserts that they do not. The appended config stays regardless, because a
bundle is versioned separately and installed independently — a value
persisted by an older bundle outlives that bundle, and no later bundle can
withdraw it.

## The `audio_sync` guard

The appended config also carries `audio_sync = "false"`, which is not a
preference about audio but a guard: a stalled codec otherwise freezes the
game inside `poll()`, and nobody can reach RetroArch's audio menu while the
game is frozen. It is scrubbed out of the player's own config at every boot
by `MayonnaiOS.Cores.clear_persisted_audio_sync/0`, for the reason the next
section gives for `autosave_interval` — so the day the codec is trustworthy,
deleting one line is enough, and no device is left carrying a setting no file
in any repository still contains.

## Saves

RetroArch writes a game's SRAM every ten seconds (`autosave_interval`), and
this firmware asserts that in the same appended config as the core directory.
`autosave_interval = "0"` — RetroArch's own default — writes the `.srm` only
when content closes cleanly, and on a handheld with no clean shutdown that
means a kill or a pulled cable discards every in-game save made since the ROM
was loaded.

Ten seconds costs almost nothing in writes: RetroArch compares the SRAM
against its last copy and writes only when it differs, so the interval
decides how *soon* a save reaches the card, not how often anything is
written.

The setting is scrubbed out of the player's own config at every boot by
`MayonnaiOS.Cores.clear_persisted_autosave/0`, for the same reason
`libretro_directory` is: RetroArch persists whatever `--appendconfig`
supplied as though the player had chosen it, so without the scrub, a value
could not be changed later by any firmware. Changing the interval is editing
one line; there is no device to go and repair afterwards. The cost is that
this firmware owns the setting — changing it in RetroArch's Saving menu does
not survive a reboot.

RetroArch flushes those writes to the kernel and never fsyncs them, and there
is no `sync` on this device, so `MayonnaiOS.Saves.flush/1` fsyncs the save
files at the two moments the launcher knows the program is *gone*: when it is
reaped, and when a deliberate stop has confirmed the process died. A stop
that could not confirm it — the one that reports
`{:error, {:still_running, pid}}` — does not flush. Deliberately: fsyncing
while a game runs could catch an autosave between its truncate and its write,
which is the one way this could destroy the file it exists to protect. A
cable pulled mid-game is covered by the interval and by f2fs writeback, and
by nothing else.

## Success and troubleshooting

A healthy runtime has a complete versioned RetroArch bundle selected by
`current`, core symlinks that resolve to bundle or `/root/cores` artifacts, a
last-wins `mayonnaios.cfg`, and save files fsynced after a confirmed stop.

- **No cores appear:** run `MayonnaiOS.Cores.sync/0`. Inspect
  `MayonnaiOS.Cores.append_config/0` and remove stale player
  `libretro_directory` values with
  `MayonnaiOS.Cores.clear_stale_directory/1`.
- **A bundle keeps restoring a wrong core directory:** confirm it is v1.22.2-6
  or later and that the MayonnaiOS config is the final `--appendconfig` file.
- **A game freezes in audio polling:** retain the firmware-owned
  `audio_sync = "false"` guard while investigating the codec path.
- **Recent in-game save is absent after pulled power:** ten seconds is a maximum
  exposure window, not zero. Confirm the launcher observed process death before
  expecting `MayonnaiOS.Saves.flush/1` to have fsynced it.
- **Installed data appears in an unexpected directory:** reconcile it with
  [On-device data layout](data-layout.md); do not move player settings into a
  versioned bundle.

API reference: `MayonnaiOS.Cores`, `MayonnaiOS.Bundle`, and
`MayonnaiOS.Saves`. The pre-bundle investigation is a separate
[historical provisioning decision record](retroarch-provisioning.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/retroarch-internals.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
