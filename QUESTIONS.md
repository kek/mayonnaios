# Product questions for #69 — Give apps meaningful descriptions

Issue: Replace generic app descriptions such as “An app in this firmware. A opens it.” with concise descriptions of what each app does.

## Scope and source of truth

1. Which runnable rows are in scope: only built-in BEAM apps that currently hit the generic `program_lines/1` clause, or also external programs, launcher actions, process monitors, and graphical Pickles that already have specialized descriptions?
2. Must every built-in app have an explicit description, including target-only and host-development rows, or is a fallback acceptable for third-party/test entries that do not provide one?
3. Should descriptions be attached to each program entry in `config/target.exs` and `config/host.exs`, exposed by each app module, or maintained in a central lookup keyed by module?
4. The browser synthesizes Diagnostics, Sleep, Automatic sleep, and Theme rows rather than reading them from program config. Should those launcher-owned actions also receive meaningful descriptions as part of this issue?
5. Should the existing Power off wording be retained, rewritten in the same concise product voice, or treated as outside this issue because it is an action rather than an app?
6. Should the two process-monitor rows retain their live memory preview, even though that means their preview is not a prose description? If so, should their X/full behavior or any static explanatory copy change?
7. Pickles already have manifest descriptions but their launcher preview currently says only that they are sandboxed Lua apps. Should the Pickle manifest description appear in the launcher, and if not, is that explicitly deferred?

## Content and UX

8. What should each shipped app say? In particular, what user-facing one- or two-line copy is expected for Moonlight settings, Bluetooth controller, Bluetooth devices, WiFi, Software update, and any other configured built-in app?
9. Are descriptions intended to explain only the app’s purpose, or may they include important limitations/state such as Bluetooth devices not supporting headphones, Moonlight settings working before Moonlight is installed, or Software update requiring network access?
10. Should the generic controls line (“A opens it. Menu leaves it.”) remain after the meaningful description, or should descriptions replace the generic copy in full?
11. Must preview descriptions fit a fixed number of lines or character width on the 640×480 three-column layout? How should longer copy wrap or be shortened?
12. Should the full view opened with X show exactly the same description and controls as the preview, or may it contain a longer explanation?
13. Should descriptions be sentence strings, arrays of already-broken lines, or text that the view wraps? Which representation best matches the existing Scenic renderer’s behavior?
14. Is localization anticipated, or are English strings in application configuration consistent with the project’s current product language?
15. Should descriptions mention button names (“A”, “Menu”) directly, preserving the project’s current control vocabulary, or should control help remain separate from purpose copy so bindings can evolve independently?

## Behavior and edge cases

16. What should the UI display for an app entry with no description (including tests, local development additions, and future apps): the current generic fallback, a name-derived message, no purpose line, or a visible “No description provided” configuration warning?
17. What should happen for an explicitly empty or whitespace-only description? Should normalization reject it, drop it to the fallback, or display it?
18. If descriptions become a program field, should `MayonnaiOS.Programs.normalize/1` preserve it for all entry shapes (`app`, `{app, arg}`, `action`, and `path`) or only app entries?
19. Should malformed non-string description values be tolerated at boot, converted with `to_string/1`, or treated as configuration errors? The launcher currently favors visible degradation over crashing for malformed program entries.
20. For unavailable external programs, should a meaningful description be shown before the existing path and “Not installed” state, or should installation status continue to take precedence?
21. For module-plus-argument apps such as process monitors and Pickles, is the description per module, per configured row, or supplied dynamically from the argument/manifest?
22. Should host and target configurations use identical descriptions for shared apps to prevent the desktop preview from drifting from the device?

## Architecture, compatibility, and maintenance

23. Is a backward-compatible optional `:description` field required so existing tests and runtime callers that build minimal program maps continue to work?
24. Should the `MayonnaiOS.Programs.program/0` type formally require or optionally include descriptions, and should synthesized browser built-ins use the same normalized shape?
25. Is there value in requiring descriptions through a validation function/test for all production app rows, so a future app cannot silently regress to generic copy?
26. Should the implementation avoid module-specific pattern matching in `MayonnaiOS.Browser.View`, keeping presentation data in normalized program entries and preserving the view as a pure renderer?
27. Are manifest descriptions or config strings trusted display content? Do they need newline/control-character sanitization before Scenic renders them?
28. Could adding a field to normalized program maps affect equality assertions, fixtures, or launch code that expects an exact map shape, and what compatibility behavior is required?

## Acceptance and verification

29. Which exact rows must have asserted meaningful preview copy for acceptance on the target configuration?
30. Should tests verify both `View.preview/2` and `View.full/2`, since both call `program_lines/1`, or is one shared-unit assertion sufficient alongside the pure-function implementation?
31. Should tests assert exact approved copy (strong content contract) or only that each app’s configured description is carried through and the old generic sentence is absent?
32. Is `mix test` on the host sufficient verification, or is a manual 640×480 host-runtime review required to confirm wrapping/readability?
33. Should acceptance explicitly grep/assert that “An app in this firmware.” no longer appears for any shipped app while preserving a safe fallback for unannotated extension/test entries?
