# Architectural answers for #69 — Give apps meaningful descriptions

## Scope and source of truth

1. **Scope is the built-in BEAM app rows that currently receive “An app in this firmware.”** External programs, launcher actions, process monitors, and Pickles already follow distinct presentation paths and are not part of this narrowly worded issue.
2. **Every shipped target app that uses the generic clause must have an explicit description.** Unannotated extension and test entries retain a backward-compatible generic fallback; they must not make the launcher crash.
3. **Store descriptions on program entries.** `config/target.exs` and `config/host.exs` are already the source of truth for row names, order, category, and launch behavior. A central module lookup would split one row across two registries and fail for multiple rows using one module.
4. **Do not expand this issue to synthesized launcher actions.** Diagnostics, Sleep, Automatic sleep, and Theme do not trigger the quoted generic app copy. Their action wording can be improved separately without coupling it to app metadata.
5. **Retain Power off wording.** It has deliberate action-specific behavior and is outside this issue.
6. **Retain live process previews unchanged.** They are more meaningful than static prose and are selected by the existing `{MayonnaiOS.Top, which}` clause. No X/full behavior changes are needed.
7. **Defer Pickle manifest descriptions.** Pickles already receive explicit type/help copy rather than the firmware-app fallback. Surfacing untrusted manifest copy, deciding line handling, and changing `program_rows/0` deserve separate scope.

## Content and UX

8. **Use approved, purpose-first copy on the shipped target rows:**
   - Moonlight settings: `Configure Moonlight game` / `streaming.`
   - Bluetooth controller: `Use this handheld as a` / `Bluetooth game controller.`
   - Bluetooth devices: `Scan nearby devices and` / `manage Bluetooth pairings.`
   - WiFi: `Join, forget, and inspect` / `WiFi networks.`
   - Software update: `Check for and install new` / `MayonnaiOS releases.`
   Shared host rows use the same copy. These are concise, user-facing, and fit the narrow pane by construction.
9. **Describe purpose, not every limitation.** Detailed caveats belong on the app screen and in existing docs. The preview is glanceable navigation help, not documentation.
10. **Keep the controls line after the description.** Purpose copy replaces only “An app in this firmware.”; `A opens it. Menu leaves it.` still tells the user how the selected row behaves.
11. **Represent descriptions as pre-broken lines of at most 26 characters and normally at most two lines.** The current preview renderer truncates at 26 characters and does not wrap. Explicit lines make target copy deterministic at 640×480.
12. **Preview and full view use the same lines.** Both already call `program_lines/1`; introducing a second long-description system would add content drift for no requirement.
13. **Use `description: [String.t()]`.** An array matches the renderer contract and makes intentional narrow-pane breaks explicit. Do not add wrapping in this issue.
14. **English config strings are correct.** The project has no localization infrastructure and all current launcher copy is English.
15. **Keep controls separate.** Description lines explain purpose; `Browser.View` appends the binding line. This preserves one source for controls if bindings change.

## Behavior and edge cases

16. **Keep the current generic fallback for missing descriptions.** Tests, local additions, and third-party program maps remain compatible. Production coverage will ensure shipped generic app rows do not use it.
17. **Treat an empty list as missing and use the fallback.** Do not display blank purpose copy. Configuration should provide non-empty literal lines for shipped rows.
18. **Preserve `:description` in every normalized entry shape.** Although this issue consumes it for apps, normalization should not silently discard declared row metadata based on launch mechanism. This also makes the field coherent for future work.
19. **Accept only a list of strings; otherwise normalize to `nil`.** The project favors visible degradation, so malformed values reach the generic fallback rather than crashing at boot. Do not call `to_string/1` on arbitrary terms.
20. **Leave unavailable external-program precedence unchanged.** Adding purpose copy to external programs is outside scope; the existing path and installation failure remain the useful information.
21. **Descriptions are per configured row.** Module-plus-argument apps can have different purposes. Existing special cases for Top and Pickles continue to win before generic app rendering.
22. **Shared host and target apps must use identical copy.** Duplicate the literals in both configs for now; a test should compare behavior or exact copy where practical. Avoid introducing a new shared config abstraction for five short strings.

## Architecture, compatibility, and maintenance

23. **Make `:description` optional and default it to `nil`.** Existing minimal program maps and callers remain valid.
24. **Add optional `description: [String.t()] | nil` to `MayonnaiOS.Programs.program/0`.** Synthesized built-ins may carry `nil`; they use action-specific rendering and need no new text in this issue.
25. **Add targeted production-config coverage, not a runtime validator.** Tests should demonstrate each shipped generic app row has non-empty description lines. A boot-time validation mechanism is disproportionate and conflicts with graceful degradation.
26. **Do not pattern-match app modules for copy in `Browser.View`.** The view should render normalized metadata. Module-specific content belongs only where behavior is genuinely dynamic, as with Top and Pickles.
27. **No new sanitization is needed for trusted firmware config literals.** Pickle manifest descriptions remain deferred specifically because they are external content. Normalization’s list-of-strings check prevents arbitrary terms.
28. **Expect exact-map tests to require updates only if they assert normalized shape.** Adding the field is intentional and backward compatible at runtime; launch code reads named keys and will ignore it.

## Acceptance and verification

29. **Acceptance rows are Moonlight settings, Bluetooth controller, Bluetooth devices, WiFi, and Software update.** These are all target-configured app rows that otherwise reach the generic app clause. Host copy must cover its shared subset: Moonlight settings, WiFi, and Software update.
30. **Test both the shared rendering helper’s observable paths through preview and full view.** At minimum, assert a described app yields description plus controls in preview and the same lines in full; also retain one fallback test for an unannotated app.
31. **Assert exact approved copy for representative rendering and explicit non-empty metadata for every shipped app.** Exact strings are product content and should not drift accidentally; also assert the old generic sentence is absent from described rows.
32. **`mix test` is required and sufficient for merge.** A quick `iex -S mix` visual check is recommended because line width is a UI property, but it is not a required automated verification command.
33. **Do not remove the fallback string from the source.** Assert that every shipped in-scope app bypasses it. Keeping a safe fallback is an architectural requirement, not incomplete acceptance.
