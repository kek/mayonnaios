# Architectural Answers for #70

## Scope and ownership

1. **Decision:** Apply suppression to every external program for which `state.port` is non-`nil`. Do not name or special-case RetroArch. **Rationale:** Input ownership follows the launcher’s external-process lifecycle, and Moonlight or any future native program has the same requirement. **Constraint:** BEAM apps are not covered by this branch because they use `state.app` and explicit forwarding.

2. **Decision:** Suppress every non-global launcher action and state side effect while the port exists, not only cursor movement. **Rationale:** The invariant is that the external program owns ordinary input; enumerating only today’s known browser mutations would let future bindings reintroduce the bug. **Constraint:** Only held-key bookkeeping and explicit global controls may change launcher state.

3. **Decision:** Preserve BEAM app behavior unchanged. **Rationale:** Apps require the Launcher to forward evdev reports because they do not open evdev themselves; external programs read input independently. **Constraint:** The existing `app != nil` input clause remains separate and keeps its current priority after sleeping input.

4. **Decision:** Treat `state.port != nil` as authoritative. **Rationale:** It already defines `running?/0`, idle-sleep eligibility, repaint gating, and the ownership interval. **Constraint:** Suppression continues after a failed stop and ends only after the process is confirmed gone and the port state is cleared.

## Controls that remain active

5. **Decision:** Retain exactly Menu-to-stop/go-home, Select+Menu orderly poweroff, Power sleep, wake-on-any-press with consumption, and configured lid sleep/wake. **Rationale:** These are the established global escape and power controls named by the issue. **Constraint:** Volume remains outside Launcher ownership; no navigation/action binding is implicitly global.

6. **Decision:** Continue tracking Select so Select+Menu works. **Rationale:** The chord depends on held-state ordering. **Constraint:** Select alone performs no launcher action while a port exists.

7. **Decision:** Continue folding all key presses and releases into `state.held`. **Rationale:** Correct edge tracking prevents stale modifiers and preserves current chord semantics. **Constraint:** Updating `held` is bookkeeping, not permission to invoke an ordinary binding.

8. **Decision:** A Power-triggering report is handled only by the launcher’s sleep behavior; no other event in that report may invoke launcher actions. **Rationale:** This matches the existing external-program reality: the native program has its own evdev reader, while the launcher only applies its global power behavior. **Constraint:** Do not forward reports to external programs from Elixir.

9. **Decision:** Preserve the existing sleeping-first rule: Menu while asleep wakes and is consumed; it does not stop the program. **Rationale:** A dark device must make every first press predictably wake-only. **Constraint:** The sleeping `handle_input/2` clause must remain higher priority than external-program dispatch.

10. **Decision:** Preserve lid handling before ordinary input dispatch. **Rationale:** Lid state is a global hardware transition rather than navigation. **Constraint:** Keep `lid_transition/2` in `handle_info/2` ahead of `handle_input/2`.

11. **Decision:** Add no other controls. Unknown and future bindings default to suppressed while a port exists. **Rationale:** An explicit allowlist is safer than inheriting new launcher actions. **Constraint:** A future global control must be deliberately added to the external-program input helper and tested.

## Browser and launcher state guarantees

12. **Decision:** Require equality of the complete browser value across ordinary external-program input. **Rationale:** Cursor, depth, overlay, full view, and messages are one state object and all can affect the exit repaint. **Constraint:** Tests compare the full `Launcher.browser/0` result, not only `selected/0`.

13. **Decision:** Preserve any obituary during ordinary program input; B must not dismiss it. **Rationale:** Dismissal is a launcher action and invisible mutation is exactly the bug class. **Constraint:** The external-program path must not reach `back/1` or `dismiss_obituary/1`.

14. **Decision:** Keep `state.scene` unchanged for ordinary input. Menu may intentionally set it to `:home` as part of stopping. **Rationale:** Scene selection is hidden launcher UI state just like browser selection. **Constraint:** External-program input must not reach ordinary scene-changing bindings.

15. **Decision:** Ordinary presses during a program do not reset an idle timer. **Rationale:** No idle timer is armed while a port exists, and process exit already starts a fresh interval. **Constraint:** Do not call `reset_idle_timer/1` from the external-program input clause.

16. **Decision:** In a mixed report, process global controls and key bookkeeping while suppressing every ordinary event regardless of ordering. **Rationale:** One D-pad event must not become actionable because Menu later clears the port during the same report. **Constraint:** Dispatch the entire report through the external-program reducer selected at entry, rather than falling back to ordinary input midway.

17. **Decision:** Preserve sequential folding for Select+Menu in one report. **Rationale:** It matches current chord semantics and kernel report ordering. **Constraint:** Hold each key before evaluating whether that press is a global trigger.

18. **Decision:** Continue ignoring autorepeat for launcher actions. **Rationale:** Existing behavior is edge-based and avoids repeated stops/sleeps. **Constraint:** Autorepeat must not alter held state or invoke global controls.

## Placement and architecture

19. **Decision:** Add a guarded external-program `handle_input/2` clause before the ordinary clause and delegate its event fold to a small dedicated helper. **Rationale:** This creates one input-ownership boundary before `press/2`, so overlays, full views, browser bindings, and future ordinary actions are all excluded by construction. **Constraint:** Clause order is sleeping, app, external program, ordinary launcher.

20. **Decision:** Keep all existing repaint gates in `browse/2` and `set_root/2`. **Rationale:** Preventing hidden state mutation and preventing framebuffer writes are independent invariants; defense in depth remains necessary for calls not originating in gamepad input. **Constraint:** Do not simplify panel ownership code as part of this issue.

21. **Decision:** Update `MayonnaiOS.Launcher` documentation and stale comments to state that ordinary input is ignored while a native program runs and to enumerate global exceptions. **Rationale:** Current comments explicitly describe cursor and obituary mutation during a game, which would become false and invite regression. **Constraint:** Keep the documentation focused on behavior and ownership, not RetroArch-only policy.

22. **Decision:** Use an explicit helper such as `program_event/2` plus `program_press/2`, rather than a broad call into `press/2`. **Rationale:** The allowlist should be auditable and immune to future additions in `bound/2`. **Constraint:** Reuse existing `hold/2`, `release/2`, `Sleep.trigger?/2`, `enter_sleep/1`, and `home/1`; do not duplicate stop/power logic.

## Testing and verification

23. **Decision:** Add a host regression test that launches a real long-running shell process, snapshots the complete browser, injects ordinary reports, and asserts equality while the process remains running. **Rationale:** Existing tests already establish real-port lifecycle behavior; a real port validates the actual `port != nil` dispatch guard. **Constraint:** Ensure cleanup kills/stops the process even on failure.

24. **Decision:** Cover representative paths rather than every binding individually: D-pad, A, B, X, Y, and a shoulder in one table-driven test. **Rationale:** All are blocked at one dispatch boundary, so exhaustive duplication provides little extra confidence. **Constraint:** Include B with a pre-existing obituary or direct state setup so obituary preservation is observable, and include enough browser depth/content that each tested key would mutate state without the guard.

25. **Decision:** Add a focused assertion that press/release bookkeeping does not leave ordinary keys or Select held. **Rationale:** Suppression must not create stale chord state. **Constraint:** Inspect process state only for `held`; public browser/running APIs remain the behavioral assertions.

26. **Decision:** Add focused running-program tests for Menu stopping and Power sleep/wake consumption; retain or extend the existing poweroff chord test coverage if it does not already exercise a port. **Rationale:** An allowlist needs positive tests as well as suppression tests. **Constraint:** Inject poweroff and backlight seams/files so tests cannot affect the host.

27. **Decision:** Cover suppression after a failed stop in the existing unkillable-process test or a neighboring test. **Rationale:** This proves lifecycle authority remains `port != nil`, not “a stop was attempted.” **Constraint:** Restore the signal seam and kill the real process during cleanup.

28. **Decision:** Verify first with `mix test test/launcher_test.exs`, then run full `mix test`. **Rationale:** All logic is host-testable and the project documents `mix test` as its development verification command. **Constraint:** Hardware validation is a release confidence check, not a prerequisite for coding completion.

29. **Decision:** Perform the stated RetroArch reproduction on hardware when available: navigate to a known row/depth, use D-pad and face buttons in-game, quit through RetroArch, and confirm the complete visible browser position is unchanged. **Rationale:** It validates dual evdev readers and the real lifecycle beyond the host seam. **Constraint:** Record hardware validation separately; do not make automated PRD completion depend on attached hardware.
