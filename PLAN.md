# Implementation plan for #69 — Give apps meaningful descriptions

## 1. Extend normalized program metadata with optional description lines

**Files:**
- `lib/mayonnaios/programs.ex`
- `test/launcher_test.exs`

**Changes:**
- Add optional `description: [String.t()] | nil` metadata to the `MayonnaiOS.Programs.program/0` type.
- Add one private normalization helper that accepts only a non-empty list containing strings and otherwise returns `nil`.
- Carry the normalized `:description` through every program shape rebuilt by `normalize/1`: module apps, module-plus-argument apps, launcher actions, external paths, and malformed fallback entries.
- Keep the field optional at the input boundary and default it to `nil`, preserving existing callers and test fixtures.
- Update the `Programs` module documentation to identify description lines as presentation metadata and explain why explicit line breaks match the narrow launcher pane.

**Verification:**
- Add focused normalization tests showing that valid description lines survive for app and non-app entries.
- Add edge-case tests showing missing, empty, mixed-type, and non-list descriptions normalize to `nil` without raising.
- Run `mix test test/launcher_test.exs`.

## 2. Render meaningful app descriptions while retaining safe fallback behavior

**Files:**
- `lib/mayonnaios/browser/view.ex`
- `test/browser_view_test.exs`

**Changes:**
- Add a `program_lines/1` clause for firmware apps with non-empty normalized description lines.
- Return the configured purpose lines followed by the existing `A opens it. Menu leaves it.` controls line.
- Keep the existing Top live-preview clause and Pickle-specific clause ahead of ordinary app handling.
- Keep the current generic firmware-app text as the fallback for unannotated extension and test entries.
- Because preview and full view both use `program_lines/1`, do not create a second content path or wrapping implementation.

**Verification:**
- Test that a described app’s preview contains the exact configured lines and controls, and does not contain `An app in this firmware.`.
- Test that the same described app’s full view contains exactly the same lines.
- Test that an unannotated app still receives the generic fallback instead of crashing or showing blank content.
- Retain the existing Top preview test to guard special-clause precedence.
- Run `mix test test/browser_view_test.exs`.

## 3. Supply concise descriptions for every shipped in-scope app

**Files:**
- `config/target.exs`
- `config/host.exs`
- `test/browser_view_test.exs` (representative product-copy assertions, if not completed in step 2)

**Changes:**
- Add explicit, pre-broken description lines to all target app rows that otherwise use the generic firmware-app clause:
  - Moonlight settings: `Configure Moonlight game` / `streaming.`
  - Bluetooth controller: `Use this handheld as a` / `Bluetooth game controller.`
  - Bluetooth devices: `Scan nearby devices and` / `manage Bluetooth pairings.`
  - WiFi: `Join, forget, and inspect` / `WiFi networks.`
  - Software update: `Check for and install new` / `MayonnaiOS releases.`
- Add identical descriptions to the shared Moonlight settings, WiFi, and Software update rows in host config.
- Do not alter Top rows, Pickles, external programs, or launcher-owned actions; each already has specialized rendering or is outside issue scope.
- Keep every configured line at or below the preview renderer’s 26-character limit and each app description to two purpose lines.

**Verification:**
- Review both config lists against the complete in-scope row inventory above; no ordinary shipped firmware app may omit `:description`.
- Run the targeted browser view tests to pin the exact approved copy and controls behavior.
- Optionally start `iex -S mix` and inspect shared host rows in the 640×480 launcher to confirm no purpose line is truncated.

## 4. Run full regression and inspect the design acceptance conditions

**Files:**
- No additional files expected; fix only regressions caused by the metadata shape in the files above and their existing tests.

**Changes:**
- Format all modified Elixir and config files.
- Check exact-map assertions and fixtures for the intentional new normalized field, updating assertions rather than weakening unrelated behavior.
- Confirm the fallback string remains in source for unannotated extensions but is not returned for any shipped in-scope app.

**Verification:**
- Run `mix format --check-formatted`.
- Run `mix test` with the host target (no `MIX_TARGET`).
- Confirm all five target app rows and all three shared host rows carry approved non-empty description lines.
- Confirm the implementation does not change launch behavior, category classification, process previews, Pickle previews, or missing-program status.
