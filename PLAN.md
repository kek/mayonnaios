# Implementation plan for #68 — Use the full column width for menu items

## 1. Add pixel-based label fitting to the home scene

**Files:** `lib/mayonnaios/scene/home.ex`

- Replace the row-label use of the fixed `name_chars/0` character budget with a private helper that accepts text, font size, and a pixel budget.
- Implement fitting with `Theme.width/2` and `String.graphemes/1`:
  - return the original text when its measured width fits;
  - otherwise retain the longest grapheme prefix for which `prefix <> "…"` fits;
  - return `"…"` when only the ellipsis fits, and `""` if the budget cannot fit even that.
- Introduce named layout constants or small private budget functions based on the existing 200 px slot geometry, 12 px row-label inset, 8 px right padding, and chevron origin.
- Give expandable column rows a 168 px budget that ends before the chevron and leaf/action rows a 180 px budget that uses the unused chevron lane.
- Keep the current row origin, font size, highlight, chevron position, and color behavior unchanged.
- Leave `truncate/2`, `truncate_left/2`, captions, notes, status lines, dialogs, and full-width views unchanged.

**Verify after this step:**

- Run `mix format --check-formatted lib/mayonnaios/scene/home.ex`.
- Run `mix test test/launcher_test.exs` to confirm existing graph and launcher behavior still passes.

## 2. Apply measured fitting to right-hand menu previews

**Files:** `lib/mayonnaios/scene/home.ex`

- Update the right-hand listing preview’s entry-name rendering to call the same private pixel fitter at its actual 16 px font size.
- Give preview labels the width from their existing `x + 4` origin to 8 px before the slot edge (188 px); preview rows do not draw chevrons, so no chevron lane is reserved.
- Do not change preview captions, empty-state notes, metadata lines, text/file previews, or their existing truncation rules.

**Verify after this step:**

- Run `mix format --check-formatted lib/mayonnaios/scene/home.ex`.
- Run `mix test test/launcher_test.exs` and confirm root and descended-browser preview tests remain green.

## 3. Add regression coverage for full-width fitting and safe truncation

**Files:** `test/launcher_test.exs`

- Add a graph-level test with a menu label longer than the former 15-character cap whose narrow glyphs fit within 180 px; assert the full label appears unchanged.
- Add a wide/long menu label that exceeds the measured budget; assert the graph contains the exact longest fitting grapheme prefix plus `…`, and assert `Theme.width/2` reports the emitted string within its budget.
- Add expandable and leaf row cases that prove the expandable label reserves the chevron lane while the leaf label can use it.
- Add a right-hand preview case that proves entry labels are fitted at 16 px against the preview’s wider 188 px budget rather than the old shared character count.
- Include a composed-Unicode label in the truncation coverage and assert no grapheme is split.
- Reuse the existing graph text extractor; keep production fitting private rather than adding a public API for tests.

**Verify after this step:**

- Run `mix format --check-formatted lib/mayonnaios/scene/home.ex test/launcher_test.exs`.
- Run `mix test test/launcher_test.exs`.
- Run the full host suite with `mix test`.
- Optionally launch `iex -S mix` at the native 640×480 viewport and inspect leaf, expandable, and preview rows to confirm the 8 px padding and chevron separation visually.
