# Implementation plan for #42

## 1. Add recursive-tree preflight to the Files boundary

**Files:** `lib/mayonnaios/files.ex`, `test/files_test.exs`

- Introduce internal/public location-based types for a recursive manifest entry and tree summary; keep raw absolute paths private to `MayonnaiOS.Files`.
- Add a preflight function that resolves source/destination locations, rejects a root source, verifies that the source is a real directory, verifies every destination ancestor with `lstat`, and rejects source/destination containment even when configured roots overlap.
- Walk with `File.lstat/1`, validate every relative component through `safe_name/1`, and collect only directories and regular files. Reject nested symlinks and all special types without following them.
- Record relative component lists, type, size, mtime, inode, and device; calculate total bytes and total entries; capture destination filesystem identity when `df` provides it.
- Add injectable stat/space/cancellation/progress seams where host tests need them.

**Verify:** Run `mix test test/files_test.exs`. Cover nested and empty directories, zero-byte files, invalid descendant names, nested links, special entries, missing/unreadable paths, symlink destination ancestors, overlapping roots, summary totals, and cancellation before any destination is created.

## 2. Enforce recursive free-space policy before writing

**Files:** `lib/mayonnaios/files.ex`, `test/files_test.exs`

- Add the recursive-copy headroom policy: file bytes plus the larger of 16 MiB or 1% of file bytes.
- Require a successful destination space measurement for recursive work; return a distinct `:space_unknown` error instead of inheriting regular-file copy’s permissive behavior.
- Compare required bytes before staging creation and expose errors through the existing Files reason vocabulary.
- Recheck room before each regular file against remaining work so concurrent writes fail safely.

**Verify:** Run `mix test test/files_test.exs`. Test exact headroom boundaries, percentage headroom for large totals, unknown `df`, initial ENOSPC, and a simulated free-space drop between files; assert no stage/final directory is left after preflight failure.

## 3. Implement staged recursive directory copy

**Files:** `lib/mayonnaios/files.ex`, `test/files_test.exs`

- Add a recursive copy executor that consumes the preflight manifest and creates `<destination-name>.part` beside the final destination without overwriting either name.
- Put a private MayonnaiOS marker in the staging root before descendants are written. Use that marker as the authority for app-owned cleanup.
- Re-`lstat` each source entry before use and require its recorded identity/type/size/mtime to match. Build directories in dependency order.
- Stream every regular file in existing 64 KiB chunks to its own `.part`, fsync the open handle, and rename it into place; report bytes, entries, and relative path through a callback.
- After all entries, perform a final source-manifest verification, rename the staging root to the final name in the same destination directory, then remove the private marker. Never expose the final name for a partial tree.
- Stop at the first error and perform best-effort validated staging cleanup. Keep detailed phase/path errors for logs and Browser wording.

**Verify:** Run `mix test test/files_test.exs`. Assert nested byte fidelity, empty-directory creation, per-file fsync-before-rename, progress counters, final promotion ordering, source mutation detection, final/stage collision refusal, write/read/rename failures, no final directory on failure, and no unvalidated recursive cleanup.

## 4. Add cooperative cancellation and stale-stage recovery

**Files:** `lib/mayonnaios/files.ex`, `test/files_test.exs`

- Poll cancellation between scanned entries, between every 64 KiB chunk, before promotion, and before cleanup/destructive phases.
- On cancellation remove the current file part and recursively remove only a staging tree whose marker exactly validates; return a terminal cancelled result.
- Add location-based `incomplete_stage?/1` and discard APIs for a visible `<name>.part` directory. Refuse recursive removal if the marker is absent, malformed, or no longer belongs to that staging path.
- Preserve and report a marked stage when cleanup itself fails so pulled-power recovery remains recognizable.

**Verify:** Run `mix test test/files_test.exs`. Cancel during scanning and in the middle of a large file, assert bounded checkpoint behavior and cleanup, simulate cleanup failure, and prove that a user-created `*.part` directory without the marker can never be recursively discarded.

## 5. Extend Move with safe cross-filesystem directory semantics

**Files:** `lib/mayonnaios/files.ex`, `test/files_test.exs`

- Keep successful same-filesystem directory rename unchanged and synchronous.
- When directory rename returns `:exdev`, run the same preflight/staged-copy path as Copy.
- Verify the complete source manifest again before deletion. Delete only matching manifest files and then directories bottom-up; refuse unexpected or changed entries.
- Begin source cleanup only after destination promotion. If cleanup fails, retain the complete destination and source and return a distinct “copied, source not removed” failure.
- Ensure cancellation is checked before source deletion and during bottom-up cleanup without ever rolling back a complete destination.

**Verify:** Run `mix test test/files_test.exs`. Inject `:exdev`; assert destination promotion precedes source deletion, success removes the source, cancellation before cleanup preserves it, changed/unexpected source children are never deleted, cleanup failure retains both trees, and same-filesystem rename still bypasses recursion.

## 6. Add a temporary supervised Files worker

**Files:** `lib/mayonnaios/files/worker.ex` (new), `lib/mayonnaios/application.ex`, `test/files_worker_test.exs` (new)

- Implement `MayonnaiOS.Files.Worker` as a temporary DynamicSupervisor child with `sessions/0`, following the project’s existing session-supervisor pattern.
- Accept Copy, cross-filesystem Move fallback, and validated stale-stage discard jobs using Files locations and an owner pid.
- Monitor the owner; owner loss requests cooperative cancellation/cleanup instead of restarting or orphaning the job.
- Tag every scanning/progress/result message with worker pid and an opaque job ref. Coalesce ordinary progress to at most one message per 250 ms while always emitting phase and terminal transitions.
- Add the empty worker DynamicSupervisor to the application tree on host and target.

**Verify:** Run `mix test test/files_worker_test.exs test/app_partition_test.exs`. Test child restart policy, owner monitoring, tagged messages, throttling with an injectable clock, graceful cancel, worker failure/`:DOWN`, and one terminal result. Confirm the application supervision tree starts on host.

## 7. Make Browser represent async commands and progress without doing process work

**Files:** `lib/mayonnaios/browser.ex`, `test/browser_test.exs`

- Extend `Browser.t()` with serializable operation presentation and pending-command data while preserving Browser as a pure value.
- Offer Copy for real directory entries, continue refusing symlinks, and make Paste produce a command describing source, destination, and mode rather than synchronously walking a directory.
- Keep regular-file Copy/Move routed to their existing synchronous functions when Launcher drains the command; recursive commands are delegated to Worker.
- While an operation is active, suppress selection mutations, clipboard changes, and additional paste requests. Preserve read-only navigation/full view.
- Recognize validated marked `*.part` directories and offer `Discard incomplete …` through the existing two-button destructive confirmation; emit an async discard command rather than deleting in Browser.
- Add pure helpers to start/update/finish/cancel operation presentation and apply terminal clipboard/message semantics.

**Verify:** Run `mix test test/browser_test.exs`. Pin directory Copy availability, link refusal, command contents, single-job gating, unchanged regular-file behavior, copy/move clipboard outcomes, progress state transitions, stale-stage discard visibility/confirmation, and refusal for ordinary `.part` directories.

## 8. Orchestrate workers and responsive controls in Launcher

**Files:** `lib/mayonnaios/launcher.ex`, `test/launcher_test.exs`

- Add active Files job state containing worker pid/ref/monitor and source/destination parent metadata; never store process handles in Browser.
- Drain Browser operation commands after overlay input. Run existing regular-file operations synchronously, preserve direct directory rename, and start Worker only for recursive Copy, `:exdev` Move, or stale-stage discard.
- Paint the scanning state before starting the slow work. Accept only progress/result/`:DOWN` messages matching the active pid and job ref; ignore stale messages.
- Coalesce repaint behavior through worker updates, apply terminal Browser messages/clipboard semantics, and refresh an affected focused source/destination column.
- Reserve B for cooperative cancellation while active; allow directions, shoulders, A for directory/file browsing, and Menu-to-root. Block programs/ROM launch, BEAM apps, sleep, poweroff, file actions, and clipboard mutation with an explanatory message.
- Keep idle sleep disarmed while a recursive job exists and rearm it after terminal handling.

**Verify:** Run `mix test test/launcher_test.exs test/browser_test.exs`. Test immediate input responsiveness, B cancel without navigation, Menu-to-root, allowed inspection/navigation, blocked launch/sleep/poweroff/mutations, progress ordering, stale-message rejection, worker crash handling, focused-column refresh, one active job, and idle-timer behavior.

## 9. Render honest operation status and controls

**Files:** `lib/mayonnaios/scene/home.ex`, `test/launcher_test.exs`

- Render scanning as entry/byte totals found with no percentage.
- Render copying/moving with completed/total bytes, completed/total entries, and a safely truncated relative path; render cleanup and cancelling phases explicitly.
- Give active operation status precedence on the footer/status area and always label `B cancels` until cancellation is requested. Keep the held clipboard visible.
- Add Browser reason strings for recursive errors such as unknown space, changed source, unsupported descendant, unsafe destination, existing stage, and incomplete source cleanup.

**Verify:** Run the graph-text tests in `mix test test/launcher_test.exs`. Assert exact scanning/copying/cancelling/completed/error language, bounded long paths, B hint, no false percentage during scan, and precedence over ordinary hints.

## 10. Update documentation and run end-to-end verification

**Files:** `README.md`, `lib/mayonnaios/files.ex` moduledoc, `lib/mayonnaios/browser.ex` moduledoc, `lib/mayonnaios/launcher.ex` moduledoc; optionally `docs/data-layout.md` only if the marker becomes a stable on-card format

- Replace the “directories deliberately not implemented” documentation with the recursive-operation contract: preflight, one job, symlink refusal, no overwrite, staging, per-file fsync, cancellation, and non-atomic cross-filesystem Move.
- Document that general recursive Delete remains unsupported and that only marked incomplete staging trees can be discarded recursively.
- Document the controls and the pulled-power result, without claiming directory-entry fsync or resume.
- Run formatter and the complete host suite.

**Verify:** Run `mix format --check-formatted` and `mix test`. Review the diff for stale claims that directories cannot be copied/moved across filesystems.

## 11. Validate on the handheld before claiming hardware completion

**Files:** no source change unless hardware findings require it

- Use expendable nested ROM data with recorded hashes on internal F2FS and games-card exFAT.
- Copy and move in both directions; verify hashes, empty directories, clipboard behavior, progress repaint rate, and that same-filesystem directory Move remains immediate.
- Cancel during scan and during one large file; verify B responds promptly and no final/marked stage remains after successful cleanup.
- Remove the games card during work and verify a precise failure with no writes into the bare mountpoint.
- Pull power during a file and immediately before final promotion; reboot, verify no incomplete final-looking tree, identify the marked `.part` tree, and discard it from the device UI.
- Simulate/observe insufficient space and confirm preflight refuses before writing.

**Verify:** Record the tested firmware revision, filesystems, fixture hashes, and outcomes in the implementation PR. Hardware validation is additive to, not a replacement for, the full host test suite.
