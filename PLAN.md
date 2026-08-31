# Implementation Plan for #70

## 1. Establish the external-program input ownership boundary

**Files:**
- Modify `lib/mayonnaios/launcher.ex`

**Changes:**
- Add a guarded `handle_input/2` clause for launcher states whose external `port` is non-`nil`.
- Place it after the existing sleeping and BEAM-app clauses but before ordinary launcher input, preserving the dispatch priority: wake handling, app forwarding, external-program globals, normal navigation.
- Fold the entire incoming evdev report through one external-program-specific reducer selected at report entry. Track key presses and releases with the existing `hold/2` and `release/2` helpers; ignore autorepeat and non-key events.
- Add a small external-program press helper with an explicit allowlist:
  - evaluate the existing `Sleep.trigger?/2` and call `enter_sleep/1`,
  - route the configured Menu key through the existing `home/1`, which already distinguishes Menu, Select+Menu, successful stop, and failed stop,
  - ignore every other press.
- Do not call `press/2`, `bound/2`, browser overlay/full-view handlers, or `reset_idle_timer/1` from this path.
- Keep the complete report in the external-program reducer even if Menu successfully stops the process midway, so later ordinary events in the same report cannot fall through to launcher navigation.
- Keep the existing `browse/2`, `set_root/2`, panel ownership, stop escalation, and BEAM-app paths unchanged.

**Verify after this step:**
- Run `mix format --check-formatted lib/mayonnaios/launcher.ex`.
- Run `mix compile --warnings-as-errors` to catch clause-order, unused-helper, and type/compile issues.

## 2. Add the core hidden-browser-state regression test

**Files:**
- Modify `test/launcher_test.exs`

**Changes:**
- Reuse or extend the existing real `/bin/sh` long-running-process harness in the “stopping a program” area so the test exercises an actual non-`nil` port and guarantees process cleanup on failure.
- Navigate to a browser state where D-pad, B, X, Y/A as applicable, and shoulder inputs would normally have observable effects; launch the shell and snapshot the complete `Launcher.browser/0` value.
- Inject representative ordinary press/release reports (D-pad, A, B, X, Y, and a shoulder), asserting after each that:
  - `Launcher.running?/0` remains true,
  - the complete browser value remains equal to the pre-input snapshot.
- Set or arrange an obituary where necessary and assert B does not dismiss it while the external program owns input.
- Inspect only the internal `held` set for a focused bookkeeping assertion: completed ordinary and Select press/release pairs leave no stale keys held.
- Add a mixed-report case containing ordinary input and Menu to prove ordinary events in the same report are never dispatched after the stop changes `port` to `nil`.

**Verify after this step:**
- Run `mix format --check-formatted test/launcher_test.exs`.
- Run the focused test file: `mix test test/launcher_test.exs`.
- Confirm the new regression test fails against the old dispatch behavior and passes with the ownership clause.

## 3. Prove the global-control allowlist while a program runs

**Files:**
- Modify `test/launcher_test.exs`

**Changes:**
- Add a running-program Menu test that injects the configured Menu press and verifies the real child process is gone, `Launcher.running?/0` is false, and the launcher returns home without applying unrelated input.
- Add a Select+Menu test with the injectable `poweroff` callback, proving Select is tracked and the chord remains globally active while the port exists without invoking host poweroff.
- Add a Power test using a temporary backlight file: Power enters sleep during a running program, the next ordinary press wakes and is consumed, and the browser remains unchanged while the program continues running.
- Extend the existing unkillable-process scenario: after `stop_program/0` returns `{:error, {:still_running, pid}}`, inject ordinary navigation/action input and assert the complete browser remains unchanged, the port remains active, and the panel remains held. Then restore the signal seam and clean up.
- Keep tests deterministic with existing injectable timeouts, signal modules, power callback, temporary files, and `on_exit` cleanup.

**Verify after this step:**
- Run `mix format --check-formatted test/launcher_test.exs`.
- Run `mix test test/launcher_test.exs` and ensure all process, panel, sleep, app-forwarding, and browser tests pass.

## 4. Align launcher documentation with the new invariant

**Files:**
- Modify `lib/mayonnaios/launcher.ex`

**Changes:**
- Update the module documentation’s input-ownership discussion to say that, while an external port exists, ordinary navigation/action input is ignored by the launcher even though its evdev reader still receives reports.
- Document the explicit exceptions: Menu stop, Select+Menu poweroff, Power/lid sleep behavior, and wake-on-any-press consumption.
- Correct stale comments that currently say the cursor, scene, or obituary may mutate during a game, including the comments around program exit naming, `dismiss_obituary/1`, `browse/2`, and `set_root/2`.
- Explain that repaint gates remain as independent framebuffer safety, not as permission to mutate hidden browser state.

**Verify after this step:**
- Run `mix format --check-formatted lib/mayonnaios/launcher.ex test/launcher_test.exs`.
- Search the launcher documentation for claims that game-time ordinary input still moves hidden launcher state and remove or qualify all such claims.

## 5. Run full automated and optional hardware verification

**Files:**
- No additional files expected.

**Automated verification:**
- Run `mix compile --warnings-as-errors`.
- Run `mix test test/launcher_test.exs`.
- Run the complete host suite with `mix test`.
- Run `mix format --check-formatted` for the project.

**Hardware verification when an RG40XXV with RetroArch is available:**
- Navigate to a known game row and record the browser category, depth, and selected row.
- Launch the game, exercise D-pad, face buttons, and shoulders in RetroArch, then quit through RetroArch’s own menu.
- Confirm the launcher returns to exactly the same browser depth and row, with no unexpected full view, overlay, message, or obituary change.
- Repeat once using Menu to stop the game and confirm the explicit global escape still works; test Power sleep/wake separately and confirm the wake press does not act on the launcher.
