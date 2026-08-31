# Design questions for #42

## Product scope

1. Is this issue complete only when both **Copy directory** and cross-filesystem **Move directory** work from the on-device Files browser, while same-filesystem moves remain instant renames?
2. Is recursive deletion intentionally out of scope, leaving Delete limited to files, links, and empty directories?
3. May a directory operation contain nested empty directories and regular files only, or are any other entry types supported?
4. Does the feature apply to every configured Files root, including `/`, `/root`, bundles, and cores, subject to the existing filesystem permissions and path boundary?
5. Is only one long-running file operation allowed at a time across the device?

## User flow and controls

6. Should Copy become available on an ordinary directory row in the existing Y actions sheet, with no extra warning before the directory is placed on the clipboard?
7. Should paste begin with a potentially slow preflight scan, or should the UI ask for an additional confirmation because the operation may take minutes?
8. What must remain usable during an operation: A/B, Menu, Power, the power-off chord, cursor movement, browsing, and other apps/programs?
9. What exactly does B do while work is active: request cancellation, leave the current column, or both?
10. Should Menu be allowed to return to the root while copying continues, or should it request cancellation/stay on the progress screen?
11. Should a user be able to start a program, sleep, or power off while a copy is running, or should those actions be blocked until completion/cancellation?
12. Can the clipboard or a second paste be changed while a job is active, or should all mutating file actions be disabled?
13. For a directory copy, should the clipboard remain after success, as it does for regular-file copies? For a move, should it clear only after the source has been deleted successfully?

## Progress and feedback

14. Which phase and quantities must the panel show during preflight and transfer: entries scanned, bytes discovered, files copied, bytes copied, and/or current relative path?
15. Since total bytes are unknown until the preflight walk finishes, what wording should the footer use while scanning?
16. Is byte progress sufficient, or must empty directories and zero-byte files also visibly advance the operation?
17. How often should progress updates repaint the Scenic scene so they are responsive without restarting the root scene for every 64 KB chunk?
18. How are completion, cancellation, and failure reported, and how long do those messages remain visible?
19. If the user browses elsewhere while a job runs, should the focused destination column refresh automatically on completion, or only when reopened?

## Cancellation and lifecycle

20. At what checkpoints must cancellation be honored: between entries, between chunks of a large file, during the preflight walk, and before source deletion for a move?
21. What cleanup is guaranteed after cancellation: remove the current file’s `.part`, remove the operation’s incomplete destination tree, or preserve completed output for diagnosis/resume?
22. What happens if the Launcher, its scene, or the worker process crashes: is the job restarted, abandoned, or explicitly non-restarting?
23. What happens when the games card is removed or remounted during preflight/copy?
24. Is resume after reboot or worker failure required, or is recognizable cleanup/retry sufficient?

## Interrupted and partial copies

25. How is an incomplete directory recognizable after power loss: a destination-level suffix such as `.part`, a marker file, or per-file `.part` names inside the final directory?
26. Should the final directory name appear only after every descendant is complete, by constructing a sibling staging directory and renaming it at the end?
27. If a stale staged tree already exists on the next attempt, should paste refuse it, replace it after explicit cleanup, or resume it?
28. Is automatic cleanup of stale staging trees safe, or must the browser expose them so the user decides?
29. Does “nothing overwrites” apply to both final destination names and all staging names/markers?
30. What durability is required for empty directories and the final staging-directory rename, given OTP cannot fsync directory entries?

## Preflight and capacity

31. Must the complete source tree be walked and its regular-file byte total computed before any destination directory is created?
32. How much free-space headroom beyond source bytes is required for filesystem metadata, especially on exFAT/F2FS and trees containing many small files?
33. If `df` cannot be parsed, should a directory operation proceed like regular-file copy does today, or fail because a minutes-long recursive copy is riskier?
34. Must free space be rechecked during transfer to handle concurrent writes or an imprecise preflight estimate?
35. Should the preflight retain a manifest in memory, stream a second walk during copy, or persist a manifest; what tree size must fit within the device’s 1 GB RAM?
36. How should source changes between preflight and copy be handled (size changes, additions/removals, or replacement by a symlink)?

## Symlinks, entry types, and path safety

37. Should any symlink encountered anywhere in the tree reject the entire operation before the first byte is copied?
38. Should symlinks be copied as links without following, or is refusal the only acceptable policy consistent with `Files.copy/3`?
39. How should sockets, devices, FIFOs, and other non-regular entries be handled: reject the whole tree in preflight or skip with an error?
40. Must every descendant name be passed through the existing `safe_name/1` boundary, including names already present on disk that exceed its 200-byte policy?
41. Must the source and each descendant be re-`lstat`ed immediately before reading to prevent a tree changing into symlinks after preflight?
42. Must a destination inside the source tree, or the source inside the destination tree, be explicitly rejected even when represented through overlapping configured roots?
43. Are symlinked destination directories allowed, given existing navigation follows links and a paste can therefore write through one?

## Copy and move semantics

44. Should recursive copy preserve only bytes and directory shape, or also modes, timestamps, ownership, and other metadata?
45. Does cross-filesystem move delete the source only after the entire staged destination has been promoted to its final name?
46. If destination copy succeeds but recursive source deletion fails, is the result a completed copy plus a failed move, with both trees retained and clearly reported?
47. During source cleanup for a move, what happens if the source changed after its files were copied: refuse deletion, delete only the preflight manifest, or recursively remove the current tree?
48. Should same-filesystem directory move continue to bypass the worker and progress UI as a direct atomic rename?
49. Should regular-file copy/move remain synchronous and unchanged, or use the same background job machinery for a consistent UI?
50. If a directory operation encounters a read or write error, does it stop immediately, collect multiple failures, or continue with unaffected entries?

## Architecture and integration

51. Which process owns job state: Launcher, a dedicated supervised GenServer, or a Task supervised independently of Launcher?
52. Which supervisor should own the worker, and should its restart policy be `:temporary` so a failed operation never starts again automatically?
53. How should progress reach Launcher without letting stale messages from an old job update a newer one (job reference, monitor reference, or registered worker)?
54. Should the browser remain a pure data structure, with operation state held separately in Launcher, or should `Browser.t()` gain a `{:copying, progress}` state?
55. How is cancellation invoked without blocking the Launcher GenServer, and how is worker termination distinguished from graceful cancellation/cleanup?
56. Should `MayonnaiOS.Files` expose a generic recursive operation callback API, a dedicated worker module, or both?
57. Which test seams are needed for `df`, rename, sync, progress throttling, cancellation, and simulated `:exdev` without mounting a second filesystem?

## Acceptance and device validation

58. What host tests are required for nested/empty directories, large files, no-overwrite behavior, preflight ENOSPC, symlink refusal, cancellation cleanup, worker crash, and cross-filesystem move deletion ordering?
59. What Launcher/browser/scene tests pin the action availability, live controls, progress footer, completion refresh, and error language?
60. What hardware checks are required on the actual internal F2FS and games-card exFAT filesystems, including copy speed, free-space accuracy, card removal, cancellation latency, and pulled-power recovery?
61. Is a full `mix test` run the implementation gate, with targeted tests used after each incremental feature?
