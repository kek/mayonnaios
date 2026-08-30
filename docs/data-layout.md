# On-device data layout

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
| `/root/pickles/<name>` | player and MayonnaiOS | Installed Lua applications and their application-owned files. Pickle formats may define their own versioning. |
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
