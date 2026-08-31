# Architectural answers for #68 — Use the full column width for menu items

## Scope and intended result

1. **Decision:** Change entry labels drawn as column rows, including rows in the parent/focused columns, the action sheet, and the right-hand listing preview. Do not change captions, empty-state notes, breadcrumbs, status text, or full-width views. **Rationale:** Those row labels are the menu items named by the issue; the other text has separate layout rules. **Constraint:** Keep non-row truncation behavior unchanged.
2. **Decision:** Render a label unchanged whenever its measured pixel width fits; append an ellipsis only when it does not. **Rationale:** Character count is the source of the aggressive truncation. **Constraint:** The fitted result must stay inside the row’s pixel budget.
3. **Decision:** Preserve all current geometry and typography. **Rationale:** The issue asks the existing columns to use their width, not for a new layout. **Constraint:** Do not change column count, slot width, gutters, row pitch, insets, font sizes, or highlights.
4. **Decision:** Apply the same fitting rule to every node kind. **Rationale:** Visual fit depends on text and adornments, not domain type. **Constraint:** Disabled and broken entries retain only their existing color differences.

## Available width and adornments

5. **Decision:** Define explicit pixel budgets from the existing origins and slot geometry. A normal row starts at `x + 12` and ends 8 px before the slot edge; its leaf-label budget is therefore `@slot - 20` (180 px). **Rationale:** This uses nearly the whole slot while preserving balanced edge padding. **Constraint:** Derive these values from named layout constants rather than embedding unrelated magic numbers in calls.
6. **Decision:** Reserve a right-hand chevron lane for expandable rows. End their labels 8 px before the chevron origin, yielding `@slot - 32` (168 px) with the current `x + 12` label origin and `x + @slot - 12` chevron origin. **Rationale:** The label and affordance must never collide. **Constraint:** Keep the chevron position unchanged.
7. **Decision:** Let leaf rows use the chevron lane, up to the 8 px right padding. **Rationale:** An absent adornment should not waste width; this directly fulfills “all available column width.” **Constraint:** The budget must be selected per node via `Browser.expandable?/1`.
8. **Decision:** Keep the highlight at the full slot width. **Rationale:** It identifies a row, not text bounds. **Constraint:** No highlight changes belong in this issue.
9. **Decision:** Treat the slot’s padded right edge as a hard layout boundary. **Rationale:** Text leaking into gutters makes adjacent columns ambiguous. **Constraint:** Use measured advance widths and retain 8 px padding to absorb rasterization differences.

## Truncation behavior and text handling

10. **Decision:** Replace fixed character-count fitting for menu row labels with measured pixel fitting at the actual renderer size: 18 px for column/action rows and 16 px for preview listing rows. **Rationale:** Proportional glyph widths and differing font sizes make a shared character count inherently wrong. **Constraint:** Pass the exact font size and pixel budget into the helper.
11. **Decision:** Keep the single Unicode ellipsis and return the longest grapheme-safe prefix whose width including `…` fits. **Rationale:** This preserves the established visual language while maximizing readable content. **Constraint:** Measure the final candidate, not the prefix alone.
12. **Decision:** Split and rebuild with `String.graphemes/1`. **Rationale:** Filenames and labels may contain composed Unicode; byte or codepoint slicing can damage them. **Constraint:** Never split a grapheme cluster.
13. **Decision:** Return `…` if it fits when no prefix fits; return an empty string only if even the ellipsis exceeds the budget. **Rationale:** An ellipsis honestly signals omitted content without overflowing. **Constraint:** Empty input remains empty.
14. **Decision:** Use trailing truncation for row labels only. **Rationale:** Names are identified from their beginning in this menu; paths and breadcrumbs already have intentional tail-preserving behavior. **Constraint:** Do not alter `truncate_left/2`.
15. **Decision:** Preserve whitespace exactly. **Rationale:** Presentation should not silently rewrite filenames or configured labels. **Constraint:** The ellipsis replaces overflow only; it does not normalize the source.

## Themes, font metrics, and resilience

16. **Decision:** Measure through the current theme on every graph build. **Rationale:** `Scene.Home` already reads the runtime theme fresh, and a font change must immediately alter fitting. **Constraint:** Do not cache fitted strings across theme changes.
17. **Decision:** Reuse `Theme.width/2`. **Rationale:** It already wraps Scenic’s font metadata and provides the project-standard fallback. **Constraint:** Do not duplicate `Static.meta/1` or `FontMetrics.width/3` inside the scene.
18. **Decision:** Keep graph construction resilient when metadata is unavailable by accepting `Theme.width/2`’s estimate. **Rationale:** Host and test environments must not fail solely because assets are unavailable. **Constraint:** Automated tests in the normal project environment should exercise registered real font metrics.
19. **Decision:** Treat Scenic’s measured advance width as the definition of fit. **Rationale:** It is the existing accepted layout primitive in `Theme` and `StatusBar`; adding bearing analysis would be disproportionate. **Constraint:** Retain the 8 px safety padding rather than inventing a second metrics system.

## Testing and acceptance

20. **Decision:** Add deterministic graph regression cases using (a) a label over 15 characters made of narrow glyphs that now fits unchanged, (b) a wide/long label that still receives an ellipsis, and (c) expandable and leaf labels to prove their distinct budgets. **Rationale:** These cases directly distinguish pixel fitting from the old character cap. **Constraint:** Select fixtures based on `Theme.width/2` so they remain explicit against the bundled font.
21. **Decision:** Assert exact rendered graph strings and separately assert, via `Theme.width/2`, that emitted row strings fit the intended budget. **Rationale:** Exact strings catch regressions in longest-prefix behavior; width assertions capture the layout invariant. **Constraint:** Do not expose a public production helper solely for tests.
22. **Decision:** Cover both 18 px column rows and 16 px right-hand preview listing rows. **Rationale:** Both show menu entry names and currently share the faulty fixed character budget despite different typography. **Constraint:** Preserve their existing origins and font sizes.
23. **Decision:** Use host `mix test` as required verification and document a 640×480 host-window/device visual check as optional follow-up. **Rationale:** Font metrics and graph content are testable headlessly; final raster appearance benefits from visual confirmation but must not block CI. **Constraint:** No hardware-only acceptance gate.
24. **Decision:** Use a simple grapheme-prefix fitter. **Rationale:** At most a few dozen visible labels are processed per repaint, so clarity outweighs premature optimization. **Constraint:** Stop as soon as the next candidate no longer fits; avoid unrelated caching state.

## Compatibility and non-goals

25. **Decision:** Keep browser and launcher behavior untouched; implement in `MayonnaiOS.Scene.Home` plus tests. **Rationale:** This is presentation-only. **Constraint:** No changes to browser node shapes, navigation, cursor state, or launcher processes.
26. **Decision:** Exclude all unrelated character-count truncation. **Rationale:** Each other location has its own semantics and budget; broad replacement would create unrequested risk. **Constraint:** Caption, note, metadata, dialog, status, and other-scene helpers remain as they are.
27. **Decision:** Keep pixel fitting private to `Scene.Home` and reuse only `Theme.width/2` publicly. **Rationale:** Pixel measurement is shared infrastructure, while ellipsis policy and row padding are scene-specific. **Constraint:** Extract a shared fitter later only when a second caller has matching semantics.
