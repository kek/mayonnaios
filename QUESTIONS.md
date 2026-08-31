# Design Questions for #70

## Scope and ownership

1. Is the requested suppression intended for every external program represented by a non-`nil` launcher `port` (RetroArch, Moonlight, host-development stand-ins, and future native programs), rather than being conditional on RetroArch or a program capability?
2. Does this issue apply only to launcher-owned navigation/action state, or should it also prevent every non-global launcher side effect while an external program runs, including obituary dismissal, scene changes, file overlays, theme changes, and attempted launches?
3. Should BEAM apps continue using their existing separate input-forwarding behavior, with this change limited to external `Port` programs?
4. Is `state.port != nil` the authoritative definition of “an external program owns input,” matching panel ownership from successful launch until confirmed process exit, including the interval in which a stop failed because the OS process survived SIGKILL?

## Controls that remain active

5. Which controls are explicitly global while an external program runs? The issue names Menu-to-stop and existing sleep/power behavior; should the exact retained set be:
   - Menu by itself: stop the running program and return home,
   - Select+Menu: orderly power off,
   - Power: sleep,
   - any press while asleep: wake and consume the press,
   - lid close/open: sleep/wake where configured?
6. Should Select alone be tracked while a program runs so that a later Menu press can still form the Select+Menu chord, even though Select must not otherwise affect launcher state?
7. Should releases for all keys continue updating `state.held` while the program runs, to prevent stale held keys and false chords after the program exits?
8. When Power sleeps during a game, should all other events in the same evdev report be swallowed by the launcher, preserving the current behavior and leaving only the external program’s own evdev reader to observe them?
9. While asleep with a program running, should a Menu press wake only and be consumed—as today—rather than also stopping the program?
10. Should lid-switch transitions remain handled before ordinary input suppression, exactly as they are now?
11. Are there any other controls that must remain available while a program runs, such as volume (currently owned by another process), or should unknown/future launcher bindings default to suppressed until deliberately classified as global?

## Browser and launcher state guarantees

12. Is the acceptance guarantee strict structural equality of `state.browser` before launch and after arbitrary gamepad presses during the program, except for changes caused by unrelated system refreshes, or is preserving only the focused cursor/path sufficient?
13. Must an existing obituary remain unchanged while a program runs, so B cannot dismiss it invisibly before the exit-time repaint?
14. Should `state.scene` remain unchanged while ordinary input is suppressed, except when Menu intentionally changes it to `:home` before stopping?
15. Should suppressed presses reset any launcher idle timer? The timer is currently disabled while `port != nil`; on exit a fresh timer is armed, so is no timer interaction the intended rule?
16. If multiple key events arrive in one report—for example D-pad plus Menu—should the launcher process only the global controls and ignore the ordinary events regardless of their order in the report?
17. If Select and Menu press events arrive in the same report, should sequential held-set folding continue to determine whether that report powers off, consistent with existing chord semantics?
18. Should autorepeat remain ignored universally, including Menu and Power, while an external program runs?

## Placement and architecture

19. Should suppression happen at the external-program input dispatch boundary (`handle_input/2` or an adjacent helper), before `press/2`, so browser overlays/full views and future ordinary bindings cannot accidentally mutate state while `port != nil`?
20. Should the current defensive repaint gates in `browse/2` and `set_root/2` remain even after state mutation is prevented, because panel ownership and input suppression are separate safety guarantees?
21. Should the launcher module documentation be updated to replace statements that imply external-program presses may move hidden launcher state and to enumerate the retained global controls?
22. Is there value in extracting an explicit “program input” reducer/helper to make the allowlist auditable, or should the implementation use a minimal guarded clause in the existing input reducer?

## Testing and verification

23. Should the regression test launch a real long-running host process through the existing launcher test harness, record the complete browser value, inject D-pad and face-button press/release reports, and assert the browser is unchanged while `Launcher.running?/0` remains true?
24. Which ordinary input cases must be covered explicitly: D-pad movement, A launch/descend, B back/obituary dismissal, X full view, Y overlay/actions, shoulders paging, and unknown keys?
25. Should tests also assert that releases are still tracked and cleared while the program runs, avoiding stale `held` state after exit?
26. Should retained controls have focused regression tests in the same running-program context: Menu stops, Select+Menu powers off, Power sleeps, and wake consumes its triggering press?
27. Should a failed stop (`{:error, {:still_running, pid}}`) be tested to prove suppression continues because `port` remains non-`nil` and the panel remains held?
28. Is host `mix test test/launcher_test.exs` sufficient for feature verification, followed by the full `mix test` suite, or is hardware validation with RetroArch also required before considering the implementation complete?
29. On hardware, should acceptance explicitly repeat the issue reproduction using both D-pad and face buttons, then quit through RetroArch and verify the same browser depth, focused row, overlays/full view, and obituary state return?
