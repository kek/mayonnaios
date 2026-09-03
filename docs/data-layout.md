> **Documentation for current `trunk`; installed firmware may differ.**

# On-device data layout

**Status: Verified architecture.** These paths describe the current RG40XXV
runtime and are compatibility interfaces, not a cleanup proposal.

## Prerequisites and task boundary

Owners should use [Manage files and storage](files-and-storage.md) for panel
operations, card removal, and backup warnings, and
[Upload games and install cores](games-and-cores.md) for library tasks. Use this
page when diagnosing ownership, writing migration code, or deciding where a new
kind of persistent data belongs.

The writable application partition is mounted at `/root`. MayonnaiOS keeps
its own visible data directly below that directory, keeps third-party player
settings under the players' conventional `.config` paths, and keeps removable
media below `/root/mnt`. These names are part of the user interface because
the Files column exposes them.

The current paths are intentionally retained. Renaming them would require a
boot-time migration on every existing device and would make stock-formatted
games cards less interchangeable, without changing what any directory means.

## Canonical paths

| Path | Owner | Contents and rule |
|---|---|---|
| `/root/ROMS/<system>` | player | Internal ROM library. `ROMS` stays uppercase to match stock-formatted games cards. |
| `/root/mnt/games` | system | Mount point for the second SD card. A mount point is infrastructure, not application data. |
| `/root/mnt/games/ROMS/<system>` | player | Removable ROM library, with the same layout as the internal library. |
| `/root/bundles/<name>/<version>` | MayonnaiOS | Versioned native application bundles. `current` selects the active version and `installed.json` records it. |
| `/root/cores/<name>/<version>` | MayonnaiOS | Versioned installed libretro cores, using the same bundle mechanism and `current` link. |
| `/root/pickles/<name>` | player and MayonnaiOS | Installed Pickle manifest and Lua code; an install replaces this directory as one unit. |
| `/root/pickles/.state/<name>.json` | player and MayonnaiOS | `mayo.storage` state, kept outside the code directory so it survives reinstall/upgrade and removed when the Pickle is deleted. |
| `/root/bluetooth/bonds.bin` | MayonnaiOS | Unversioned paired-host keys. |
| `/root/.config/retroarch` | RetroArch | Player-owned configuration and support files, including the `cores` compatibility directory. MayonnaiOS manages only the documented generated files and core symlinks inside it. |
| `/root/.config/moonlight` | Moonlight | Player-owned Moonlight configuration. |

## Rules

- Visible top-level names are data MayonnaiOS owns or deliberately exposes to
  the player. Dot-directories are reserved for another program's conventional
  configuration paths; MayonnaiOS does not hide its own data merely because it
  is internal.
- The two cards use the same `ROMS/<system>` shape. Code may merge those roots
  for browsing, but must preserve which card owns each file. Other MayonnaiOS
  data is not mirrored onto the removable card unless a feature explicitly
  defines that behavior.
- Downloaded executable content is versioned by directory and activated with a
  `current` symlink. Mutable player data—ROMs, saves, settings, bonds, and
  Pickle state—is unversioned and updated in place with the durability rules of
  the component that owns it.
- `bundles` and `cores` deliberately remain siblings. They share the same
  versioned installer, but core discovery and synchronization have a separate
  lifecycle from runnable application bundles; nesting one under the other
  would make their ownership less clear without enabling shared behavior.
- `/root/mnt` contains mount points only. New removable filesystems belong
  there; persistent application directories do not.
- A future rename is a data migration, not a config-only edit. It must be
  idempotent, preserve old data when either side is ambiguous, survive loss of
  power, and ship before readers switch to the new path. Until such a migration
  exists, these paths are stable compatibility interfaces.

## Success and troubleshooting

A layout change is successful only when old and new firmware can identify the
owner of every path, existing devices retain ambiguous data, activation links
still select complete versioned installs, and task guides name the same paths.

- If a second-card game is absent, check `MayonnaiOS.GamesCard.mounted?/0` and
  `/root/mnt/games/ROMS/<system>`; do not redirect uploads to removable storage.
- If RetroArch cannot see a core, inspect its compatibility symlinks and follow
  [RetroArch internals](retroarch-internals.md), rather than moving installed
  `.so` files into player config.
- If Pickle state vanished after an upgrade, check `.state/<name>.json`; code and
  state intentionally have different replacement lifecycles. See
  [Build Pickles](pickles.md).
- Treat a rename as a power-loss-safe migration. A config edit by itself strands
  data on installed devices.

Relevant references: `MayonnaiOS.Files`, `MayonnaiOS.Library`,
`MayonnaiOS.Bundle`, `MayonnaiOS.Cores`, `MayonnaiOS.GamesCard`, and
`MayonnaiOS.Pickles.Store`.

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/data-layout.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
