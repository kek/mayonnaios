> **Documentation for current `trunk`; installed firmware may differ.**

# Upload games and install emulator cores

**Status: Verified.** The browser upload, two-library lookup, checksum-verified
core installation, RetroArch launch, and save policy have been observed on the
RG40XXV. RetroArch itself is installed separately and is not in the firmware.

## Prerequisites

- MayonnaiOS and your phone/computer are on the same trusted home LAN.
- The ROM matches one of the systems configured by the firmware.
- To play rather than only upload, install the RetroArch bundle and a compatible
  core built for this system.

## Upload from a browser

1. Open `http://nerves.local/` on the other device.
2. Choose the target system and select the game file.
3. Submit the upload. The request streams to disk rather than holding a whole
   disc image in memory.
4. If the page shows a missing catalogued core, choose its install action.
5. Return to **Games** on the handheld and open the system and game.

**Trust boundary:** the web UI has no authentication and no TLS. Anyone on the
LAN can upload or delete a ROM, install a core, or manage Pickles. Use it only on
a network whose other users and devices you trust.

## Upload with `scp`

SSH file transfer is an alternative:

```console
$ scp game.sfc nerves.local:/root/ROMS/snes/
```

Use plain `scp`, **not `scp -O`**. The latter forces the legacy SCP protocol,
which requires an `scp` executable that is not present in the firmware. Replace
`snes` with the configured system key. See [SSH and IEx](ssh-and-iex.md) for
connection troubleshooting.

## Internal and removable libraries

The internal library is `/root/ROMS/<system>` and is always the upload
destination. A second card's `/root/mnt/games/ROMS/<system>` is merged into the
launcher for reads, so a stock-layout games card can be used without copying its
ROMs. Writes default to internal storage; deletes and explicit Files-column
operations can affect either card. Before removing the second card, stop any
running game and call `MayonnaiOS.GamesCard.unmount/0` as described in
[Manage files and storage](files-and-storage.md).

## Install RetroArch and cores from IEx

The browser is the normal owner path. The equivalent advanced operations are:

```elixir
MayonnaiOS.Bundle.install(MayonnaiOS.Bundle.spec(:retroarch))
MayonnaiOS.Cores.list()
MayonnaiOS.Cores.install(:snes9x2010)
```

`MayonnaiOS.Bundle.install/2` and `MayonnaiOS.Cores.install/1` download to a
staging location, verify the firmware-pinned SHA-256 before extraction, publish
a versioned directory, and switch `current`. They do not overwrite the running
version. Cores must come from
[`mayonnaios_bundles`](https://github.com/kek/mayonnaios_bundles), where they are
cross-built against the device sysroot; RetroArch's incompatible online core
updater is compiled out.

## Success

The upload page reports completion, the game appears under its system in
**Games**, and a core is listed as installed. RetroArch remains greyed out until
its bundle exists. With both bundle and core installed, **A** launches the game.

SRAM is written at most ten seconds after it changes, and the launcher fsyncs
save files after the emulator is confirmed stopped. That reduces loss from
pulled power, but does not replace backups. Firmware owns the ten-second setting;
a change in RetroArch's Saving menu does not survive reboot.

## Troubleshooting

- **Page cannot be reached:** confirm the WiFi screen shows an address; follow
  [Connect to WiFi](wifi.md).
- **Wrong system or extension:** use a configured system row and one of its
  accepted extensions; `MayonnaiOS.Library` is the reference.
- **Game appears but cannot launch:** install RetroArch and a suitable core.
- **No cores in RetroArch:** run `MayonnaiOS.Cores.sync/0`, then see
  [RetroArch internals](retroarch-internals.md) for stale-directory recovery.
- **Second-card game disappears:** check `MayonnaiOS.GamesCard.mounted?/0`
  and the card's `ROMS/<system>` layout.

Architecture: [RetroArch internals](retroarch-internals.md) and
[on-device data layout](data-layout.md). API reference: `MayonnaiOS.Web`,
`MayonnaiOS.Library`, `MayonnaiOS.Bundle`, `MayonnaiOS.Cores`, and
`MayonnaiOS.Saves`.

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/games-and-cores.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
