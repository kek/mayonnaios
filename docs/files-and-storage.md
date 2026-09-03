> **Documentation for current `trunk`; installed firmware may differ.**

# Manage files and storage

**Status: Verified.** The Files-column operations and both SD slots are observed
on RG40XXV hardware. User data still needs backups, especially on removable
FAT/exFAT media.

## Prerequisites

- MayonnaiOS is at the launcher.
- Stop a game or other program before changing a file it may have open.
- Back up irreplaceable saves and ROMs before moving or deleting them.

## Browse and act on files

1. Open **Files**. Choose an internal/removable ROM root, installed bundles,
   installed cores, `/root`, or `/`.
2. Use the D-pad to navigate and **A** to enter a directory or view a file.
   Press **X** for a full view; **B** or **X** closes that view.
3. Select an entry and press **Y** for its actions.
4. For **Copy** or **Move**, press **A** on that action, navigate to a destination
   directory, press **Y**, and choose the paste action. A copied item remains on
   the clipboard; a moved item does not.
5. For **Rename**, move the caret with left/right, change a character with
   up/down, remove one with **Y**, and save with **A**. **B** cancels.
6. For **Delete**, choose it in the action sheet and then press **Y** on the
   separate path confirmation. Any other button cancels.

## Success

The status line names the completed copy, move, rename, or deletion, and the
current column refreshes. A failed operation instead shows a reason such as
read-only storage, insufficient space, an existing destination, or a non-empty
directory.

## Storage ownership and durability

The internal ROM root receives browser uploads. The second card is mounted at
`/root/mnt/games`; its `ROMS/<system>` tree is read alongside the internal one.
The Files column may explicitly write either readable root, but removable media
is not a mirror and executables should be copied to internal storage before use.
The canonical path and ownership table is [On-device data layout](data-layout.md).

Nothing overwrites an existing destination. Regular-file copies stream into a
sibling `.part`, fsync the open file, and atomically rename it only when complete.
A cross-filesystem move performs that durable copy before deleting the source,
so interruption can leave two files rather than none. Directory entries
(the rename/delete itself) cannot be fsynced through OTP, and same-filesystem
moves are renames; orderly poweroff remains preferable.

Names cannot traverse out of a configured root, but browsing follows existing
symlinks because active bundles and cores depend on them. Deleting a symlink
deletes only the link; copying a symlink is refused. Directory copies and
cross-filesystem directory moves are not implemented, and deletion only removes
an empty directory. Full policy and return contracts belong to
`MayonnaiOS.Files`.

## Remove the second card safely

1. Stop the emulator or other process using the card.
2. Connect through [SSH and IEx](ssh-and-iex.md).
3. Run:

   ```elixir
   MayonnaiOS.GamesCard.unmount()
   ```

4. Remove the card only after the call returns `:ok` or `{:ok, :not_mounted}`.
   The latter means it was already safe to remove. A busy error means something
   still has a file open.

FAT and exFAT have no journal. Pulling a mounted, read-write card can corrupt a
directory; keep a backup even when an unmount succeeds.

## Troubleshooting

- **Destination exists:** choose another name or explicitly remove the old item;
  MayonnaiOS never overwrites it.
- **`.part` remains:** the copy was interrupted. Verify the source and free space,
  then remove the incomplete part before retrying.
- **Read-only card:** unmount it, check/repair it on another computer, and restore
  from backup if needed.
- **Cannot copy a directory or link:** copy individual regular files from their
  real location.
- **Cannot unmount:** leave the running game/program, then retry
  `MayonnaiOS.GamesCard.unmount/0`.

API reference: `MayonnaiOS.Files`, `MayonnaiOS.Browser`,
`MayonnaiOS.Library`, and `MayonnaiOS.GamesCard`.

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/files-and-storage.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
