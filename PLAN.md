# Implementation plan for #52 — A way to back up user data

All work is host-testable. Production paths are fixed in target configuration; tests and host development use isolated temporary/scratch directories. Implement in this dependency order.

## 1. Define the backup catalog, layout, and preflight model

**Files:**
- Create `lib/mayonnaios/backup.ex`
- Create `test/backup_test.exs`
- Modify `config/target.exs`
- Modify `config/host.exs`

**Work:**
- Add `MayonnaiOS.Backup` with format version 1 and fixed private layout under the configured destination: `current`, `.staging`, and `.previous` within `MayonnaiOS/backup-v1`.
- Define logical source roots for MayonnaiOS settings, RetroArch user data, Moonlight settings, and Pickles. Configure target roots at the approved `/root` paths and host roots beneath `tmp/host`; do not accept source paths from UI input.
- Implement deterministic preflight traversal that includes regular files, dotfiles, and empty directories; records logical root, checked relative components, size, and mtime; records missing roots as absent; and excludes RetroArch `cores` and `mayonnaios.cfg` before traversal.
- Reject symlinks, invalid UTF-8/path components, unsupported file types, and source metadata changes discovered during preflight.
- Return totals for files and bytes and require destination free space for bytes plus 5% and a small manifest allowance. Fail if the games-card destination is absent, not a directory/mount, read-only, or cannot be measured.

**Verify:**
- Tests cover the exact source catalog/exclusions, missing roots, hidden files, empty directories, stable sort order, unsafe names, unexpected symlinks/special files, totals, absent destination, and insufficient/unknown free space.
- Run `mix test test/backup_test.exs`.

## 2. Add a monitored games-card backup lease

**Files:**
- Modify `lib/mayonnaios/games_card.ex`
- Modify `test/games_card_test.exs`

**Work:**
- Add `acquire/1` and `release/1` APIs for one backup owner. Monitor the owner so a crash automatically clears the lease.
- Make acquisition idempotent for the same owner, return `{:error, :busy}` to a second owner, and make `unmount/0` return `{:error, :busy}` while leased.
- Preserve all existing no-card, mount, and unmount behavior when no lease is held.
- Keep lease enforcement in the real device seam, with an injectable/no-op lease callback for host domain tests where `GamesCard` is not supervised.

**Verify:**
- Tests cover acquire/release, competing owners, owner death, unmount refusal, and unchanged unleased behavior.
- Run `mix test test/games_card_test.exs`.

## 3. Implement bounded, durable copying and checksum verification

**Files:**
- Modify `lib/mayonnaios/backup.ex`
- Modify `test/backup_test.exs`

**Work:**
- Stream each preflighted regular file in 64 KiB chunks into a sibling `.part` in `.staging/data/<logical-root>/...`; never load a whole file into memory.
- Re-stat the source immediately before and after copying and require type, size, and mtime to match preflight.
- Compute source SHA-256 while streaming, sync the destination handle while open, close it, rename `.part` to the staging path, then re-read and SHA-256 the destination. Fail if hashes or sizes differ.
- Preserve empty directories, clean a failed file's `.part`, stop the whole run on the first unsafe/mutated/I/O/sync/rename/verification error, and send throttled phase/file/byte progress through a callback.
- Keep filesystem/hash/sync/rename/progress operations injectable where needed to prove failure ordering.

**Verify:**
- Tests cover byte-for-byte copies, hashes, large multi-chunk input, empty directories, mutation before/after read, cancellation, and injected open/read/write/sync/rename/hash failures.
- Instrumented tests assert copy → open-handle sync → rename → destination re-hash ordering and assert that no later file runs after failure.
- Run `mix test test/backup_test.exs`.

## 4. Generate portable metadata only after all files verify

**Files:**
- Modify `lib/mayonnaios/backup.ex`
- Modify `test/backup_test.exs`

**Work:**
- Generate deterministic `SHA256SUMS` entries for paths below `data/` using a desktop-compatible SHA-256 line format.
- Generate deterministic `manifest.json` with format version, completion state, optional synchronized UTC (otherwise `null`), firmware version, device profile, included/absent sources, explicit exclusions, file sizes, and SHA-256 values.
- Stream or encode metadata without loading file contents. Write/sync/rename `SHA256SUMS`, then write/sync/rename `manifest.json` last so its complete state is the validity marker.
- Add a validator that rejects missing/malformed/incomplete manifests, path escapes, duplicate records, unexpected format versions, absent files, and checksum mismatches.

**Verify:**
- Tests assert deterministic JSON/checksum output, synchronized and unsynchronized clock behavior, metadata fields, desktop checksum path syntax, malformed/path-escaping manifests, corruption detection, and that no complete manifest exists after any earlier failure.
- Run `mix test test/backup_test.exs`.

## 5. Publish atomically as the filesystem permits and recover interrupted rotations

**Files:**
- Modify `lib/mayonnaios/backup.ex`
- Modify `test/backup_test.exs`

**Work:**
- Before a run, clean only the owned `.staging` tree and reconcile `current`/`.previous`: prefer a fully validated current backup; restore a valid previous when current is absent/invalid; never delete the sole valid copy.
- After staging validates, rotate within the same filesystem: remove only an obsolete validated `.previous`, rename valid `current` to `.previous`, rename `.staging` to `current`, validate `current`, then remove `.previous`.
- If publication fails, restore `.previous` to `current` where possible and return a structured failure. Refuse unexpected files/non-directories at owned state names rather than recursively deleting them.
- Wrap the full run in games-card lease acquire/release with `after`, best-effort staging cleanup, summary logging, and a structured success result containing destination/file/byte counts.

**Verify:**
- Table-driven tests cover every meaningful current/staging/previous valid/invalid/absent combination and injected failures at each rename/removal/validation point.
- Assert a failed, cancelled, or interrupted run leaves the former current recoverable and never publishes an incomplete manifest.
- Run `mix test test/backup_test.exs test/games_card_test.exs`.

## 6. Add the asynchronous backup app state machine

**Files:**
- Create `lib/mayonnaios/backup/app.ex`
- Create `test/backup/app_test.exs`

**Work:**
- Follow the established `MayonnaiOS.Update.App` protocol: `start/1`, `stop/0`, `input/1`, `scene/0`, `watch/1`, `snapshot/0`, temporary child spec, and `sessions/0`.
- Model `:idle`, `:preflighting`, `:copying`, `:verifying`, `:done`, `:cancelled`, and `:error` snapshots. A starts/retries; Menu is handled by the launcher and app termination means cancellation.
- Run `Backup.run/1` in exactly one linked worker so the GenServer and Scenic remain responsive. Trap/report unexpected worker exits, coalesce progress to a few updates per second, and notify monitored watchers.
- Ensure `terminate/2` stops the linked worker; the domain `after` path releases the games-card lease and cleans staging. A second start returns the existing app process.

**Verify:**
- Tests cover every transition, progress snapshot, retry, watcher lifecycle, one-job behavior, structured error propagation, worker crash, and proof that stopping/leaving kills the worker and releases resources.
- Run `mix test test/backup/app_test.exs`.

## 7. Build the 640×480 backup scene

**Files:**
- Create `lib/mayonnaios/scene/backup.ex`
- Extend `test/backup/app_test.exs`

**Work:**
- Render snapshots only, subscribe through `Backup.App.watch/1`, mount the shared status bar, and follow `Scene.Update`'s stateless graph pattern.
- Idle view lists included categories and explicitly excludes games, installed software, WiFi, and Bluetooth pairings; it warns that A writes to the second card.
- Active views show phase, logical source, files and bytes completed/total, a bounded progress bar, and “Menu cancels; do not remove the card or power off.”
- Done view shows verified counts/destination and safe-unmount guidance. Map all decided errors to concise actionable copy, with a safe fallback for unknown reasons.

**Verify:**
- Graph tests inspect text/primitives for idle, each active phase, zero/known totals, success, cancellation, all user-actionable failures, stopped app, and unknown errors; assert nothing overlaps the status-bar strip.
- Run `mix test test/backup/app_test.exs`.

## 8. Integrate the app into supervision and menus

**Files:**
- Modify `lib/mayonnaios/application.ex`
- Modify `config/target.exs`
- Modify `config/host.exs`
- Modify relevant assertions in `test/browser_test.exs`, `test/host_runtime_test.exs`, and/or launcher tests

**Work:**
- Add `Backup.App.sessions()` to the application supervision tree on host and target.
- Add **Back up user data** as an app row in the System column for target and host.
- Configure host source/destination scratch trees and ensure host runtime creates them without touching repository source files or personal data.
- Confirm existing launcher app ownership pauses automatic sleep, routes gamepad input, and cancels the backup when Menu exits; do not add a second sleep mechanism.

**Verify:**
- Tests prove the row is classified under System, launches the correct app/scene, appears in host development, receives A/Menu through existing launcher behavior, and does not disturb other program ordering.
- Run the focused browser/host/launcher tests, then `mix test`.

## 9. Document the data contract, recovery procedure, and hardware checks

**Files:**
- Modify `README.md`
- Modify `docs/data-layout.md`
- Create `docs/backup.md`

**Work:**
- Document the second-card backup location, included and excluded data, one-backup retention, checksum/manifest format, honest FAT power-loss limits, progress/cancellation, and safe unmount.
- Give a desktop manual recovery procedure: preserve current destination data first, validate `SHA256SUMS`, map each `data/<logical-root>` to its canonical path, copy while affected apps are stopped/device is powered down, and reboot before use.
- State that on-device restore, history, ROMs, WiFi credentials, Bluetooth bonds, and encryption are out of scope.
- Add a manual RG40XXV checklist for exFAT/vFAT, absent/full/read-only/removed cards, large save states, unusual names, cancellation, power loss during copy and each publication phase, next-run recovery, throughput observation, and unmount.

**Verify:**
- Cross-check documentation paths and exclusions against catalog tests.
- Execute the hardware checklist before closing #52 and record observed results in the PR.

## 10. Final project verification

**Files:** no new files expected; correct implementation/tests/docs as failures require.

**Work and verify:**
- Run `mix format --check-formatted`.
- Run `mix compile --warnings-as-errors`.
- Run `mix test`.
- On RG40XXV, execute the documented manual checklist and confirm a desktop can verify `SHA256SUMS` and recover representative RetroArch settings/SRAM/save states, MayonnaiOS settings, Moonlight settings, and Pickle state.
