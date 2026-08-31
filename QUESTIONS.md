# Design questions for #52 — A way to back up user data

Issue #52 asks for a way to back up user data—such as settings and game saves—from the first SD card to the second SD card. The questions below identify the decisions needed before implementation.

## Product scope and user goal

1. Is the first release a one-way, manually triggered backup from `/root` on the OS card to the games card, or must it also support restoring a backup on-device?
2. Is the backup intended primarily for disaster recovery after replacing/reflashing the first card, for moving to another MayonnaiOS device, or for routine point-in-time protection? Which of those scenarios must the first version demonstrably support?
3. Should the feature back up only mutable user data, or everything under the writable `/root` partition?
4. Which data is explicitly in scope: RetroArch configuration, SRAM saves, save states, Moonlight configuration, WiFi configuration, Bluetooth bonds, installed Pickles and their state, ROMs, downloaded bundles, and downloaded emulator cores?
5. Which data is explicitly excluded because it is reproducible, too large, device-specific, secret, unsafe to transplant, or already lives on the second card?
6. Does “user data” include configuration owned outside the paths currently documented in `docs/data-layout.md`, and how will newly introduced user-data paths become part of future backups without silently being omitted?
7. Is a backup tied to the current firmware/device profile, or should it carry enough metadata to reject or warn about restore onto an incompatible firmware version or target?

## On-device UX

8. Where should this appear: as a new **Backup** app in the System column, as an action in Files, or elsewhere?
9. What must the initial screen explain before starting—for example, that the second card must remain inserted, that backup writes may take time, and that the card is FAT/exFAT and should be unmounted before removal?
10. Must the user confirm before a backup begins? If so, which physical button and wording should be used, consistent with destructive/long-running actions elsewhere in the launcher?
11. What progress should be visible: current phase or path, files completed, bytes copied, percentage, elapsed time, and/or indeterminate activity?
12. May the user cancel an in-progress backup? If cancellation is supported, what artifacts remain and how are they represented on the next run?
13. Can the user leave the screen while a backup runs, and should automatic sleep be inhibited until the operation finishes?
14. What should the completion view report: timestamp, total files/bytes, skipped files, backup destination, and verification result?
15. Which failures need distinct, actionable messages on the 640×480 display: no second card, card not mounted, read-only remount, insufficient space, source changing, I/O error, invalid destination, or verification failure?
16. Should host development mode expose the screen against scratch directories so the full interaction can be exercised without SD-card hardware?

## Backup identity, layout, and retention

17. What directory on the second card owns backups, and how should it avoid colliding with the card's existing `ROMS/` layout and files from other handhelds?
18. Should each run create an immutable timestamped snapshot, maintain one replaceable “latest” backup, or use another retention scheme?
19. If snapshots are retained, is pruning manual, automatic by count, automatic by free space, or out of scope?
20. If only one logical backup is retained, must the previous known-good backup survive until the new backup is fully complete and verified?
21. Should backup contents be a browsable directory tree, a single archive, or a manifest plus files? What trade-off is preferred between easy inspection on another computer, preserving metadata, streaming on a 1 GB device, and robust interrupted writes?
22. What metadata must accompany a backup: format version, creation time, firmware version, device ID/profile, included roots, file sizes, checksums, and completion state?
23. The device may not have trustworthy wall-clock time. How should backups be named and ordered when the RTC/time is absent or unset?
24. Should hidden files and empty directories be preserved? Which permissions, timestamps, symlinks, and other metadata matter when the destination is exFAT/vFAT and cannot represent Unix metadata faithfully?
25. How should symlinks be treated: preserved as metadata, followed only within approved roots, or rejected? In particular, how do we prevent links such as bundle/core `current` links from escaping scope or duplicating large reproducible content?

## Consistency and safety

26. Must games and other programs be stopped before backup so RetroArch saves/configuration and Pickle state cannot change during copying?
27. Should the operation explicitly flush known mutable files before reading them, and can it provide a consistent snapshot without filesystem snapshot support on f2fs?
28. Is a best-effort file-by-file view acceptable, or must a backup fail if any source file changes while it is read?
29. How will destination writes survive pulled power: per-file `.part` files and fsync, a staging directory, a final atomic publication marker, checksums, or a combination?
30. Given that OTP cannot fsync directory entries and FAT/exFAT has no journal, what durability claim can the UI and documentation honestly make?
31. How should a subsequent run handle stale `.part` files or an incomplete staging directory from a power loss?
32. Must every file be checksum-verified after writing, or is successful streaming plus fsync sufficient? If checksums are used, should they be stored in a manifest for later restore verification?
33. What should happen when a destination path already exists? May backup replace files inside its own private staging area while continuing to preserve the project's general “never overwrite user files” rule?
34. How is free space checked before starting, including filesystem overhead and source growth? Is a preflight size scan required, and what safety margin should be reserved?
35. What should happen if the games card disappears, becomes read-only, or is externally unmounted during backup?
36. Must `MayonnaiOS.GamesCard.unmount/0` refuse while backup owns the card, or is ordinary open-file/mount behavior enough coordination?
37. Are secrets such as WiFi credentials or Bluetooth bond keys included? If they are, does an unencrypted removable-card backup fit the product's trust model, or is encryption/passphrase input required?
38. What path-validation boundary prevents backup configuration or crafted source entries from writing outside the dedicated destination or reading beyond the approved source set?

## Restore and compatibility

39. If restore is in scope, is it all-or-nothing or can the user select categories/files?
40. Must restore preserve the current data until the incoming backup is completely validated and staged, and what rollback is possible when there is not enough room for both copies?
41. Which services/apps must be stopped and restarted around restore, and which restored settings require a reboot?
42. How are conflicts handled: replace current files after explicit confirmation, keep current files, restore under alternate names, or refuse the entire operation?
43. How should restore handle a backup produced by a newer firmware, an older schema, another hardware target, or a partially corrupt card?
44. Is restoring WiFi/bond/device-specific state permitted across devices, or should those categories be omitted or guarded by device identity?
45. If restore is not in the first release, what documented and tested manual recovery process makes the produced backup useful, and how does the format leave room for a later on-device restore?

## Architecture and operation

46. Should backup be a dedicated service/domain module plus a thin Scenic app, rather than extending `MayonnaiOS.Files`, whose contract intentionally rejects recursive long-running copies?
47. Should the operation execute in its own supervised process so Scenic input/rendering remains responsive, and what is the concurrency policy if the user attempts to start a second backup?
48. How should progress and completion be exposed to the UI—messages to one session, subscriptions, polling, or a job status API—and what happens if the UI process exits?
49. What configuration points are needed for approved source paths, backup destination, chunk size, and test seams without allowing arbitrary production paths?
50. What logging is required for support while avoiding logging secret file contents or excessive per-file noise?
51. Are backups expected to be portable to a desktop using ordinary tools, and must the README document inspection, copying off-card, safe unmount, and recovery steps?

## Verification and acceptance

52. What maximum data size and file count should the design support, and is there an acceptable memory ceiling or throughput target on the RG40XXV?
53. Which host tests are required for inclusion/exclusion rules, path traversal and symlink handling, deterministic manifests, low-space preflight, cancellation, source mutation, stale staging recovery, and every injected read/write/sync/rename failure?
54. How will tests prove ordering guarantees—for example, that each file is complete before publication and that the overall completion marker is written only after all data and metadata are durable?
55. Which hardware scenarios must be validated manually: exFAT and vFAT, no card, full card, read-only remount, removal/power loss mid-copy, large save states, untrusted filenames, and unmount after completion?
56. What is the minimum acceptance criterion for #52: a successful backup initiated entirely with gamepad controls, visibly reported, safely interruptible, and recoverable by a documented procedure?
