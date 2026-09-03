# User-data backup

**Back up user data** in the System column writes one portable backup to
`MayonnaiOS/backup-v1/current` on the second card. It includes MayonnaiOS and
RetroArch settings and saves, Moonlight settings, and Pickles. It excludes
ROMs/games, installed software, generated RetroArch cores and
`mayonnaios.cfg`, WiFi credentials, and Bluetooth bonds.

Files are streamed through 64 KiB buffers into a private staging directory,
fsynced, SHA-256 checked after writing, and published only after
`manifest.json` is durable. The previous valid backup remains recoverable
through publication. FAT/exFAT cannot make the whole rotation power-loss
atomic; the next run reconciles valid `current` and `.previous` copies.

Menu cancels while the backup screen is open. Do not remove the card or power
off during work. After success, safely unmount the games card before removing
it.

## Desktop recovery

1. Power the handheld down and preserve the whole backup directory before
   changing it.
2. In `current`, run `sha256sum -c SHA256SUMS`.
3. With affected applications stopped, copy each directory below `data/` to
   its canonical path: `mayonnaios` to `/root/.config/mayonnaios`,
   `retroarch` to `/root/.config/retroarch`, `moonlight` to
   `/root/.config/moonlight`, and `pickles` to `/root/pickles`.
4. Reboot before using the restored files.

On-device restore, backup history, encryption, ROM backup, WiFi credentials,
and Bluetooth bonds are intentionally out of scope.

## Handheld checklist

On an RG40XXV, test exFAT and vFAT cards; absent, full, read-only, and removed
cards; large save states and unusual valid names; cancellation; power loss
during copying and each publication rename; next-run recovery; desktop
checksum verification; observed throughput; and safe unmount. Record firmware,
filesystem, fixture hashes, and outcomes in the implementation PR.
