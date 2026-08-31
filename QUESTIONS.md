# Product questions for #68 — Use the full column width for menu items

## Scope and intended result

1. Does “every menu item” mean the selectable row labels in all three launcher panes—the parent column, focused column, and right-hand listing preview—or should captions, empty-state notes, action-sheet rows, breadcrumbs, status text, and full-width views change too?
2. Should a label remain unchanged whenever its rendered glyphs fit, with an ellipsis added only when the rendered text would cross the row’s actual right-hand boundary?
3. Is preserving the current three-column geometry, font sizes, row pitch, left inset, gutters, highlights, and overall visual style a requirement, so this is strictly a label-fitting fix rather than a column-layout redesign?
4. Is the desired behavior identical for all menu node kinds (categories, places, directories, files, programs, settings, and actions), including disabled or broken entries?

## Available width and adornments

5. What exact horizontal space belongs to a row label: from the existing `x + 12` text origin to the slot edge, less a small visual right padding?
6. For expandable rows, must the existing right-aligned chevron keep dedicated space so labels can never overlap it?
7. For non-expandable rows, should the label use the space where the absent chevron would have been, allowing leaf names to render farther right than expandable names?
8. Should the selected-row highlight continue spanning the full 200 px slot regardless of the fitted label length?
9. Do neighboring column gutters and separator hairlines remain hard clipping boundaries, even if a glyph’s metrics or fallback estimate is imperfect?

## Truncation behavior and text handling

10. Should fitting be based on the current theme font’s measured pixel width at each renderer’s actual font size, replacing the current fixed 15-character budget?
11. When truncation is required, should the implementation retain the current trailing single-character ellipsis (`…`) and choose the longest grapheme-safe prefix for which prefix plus ellipsis fits?
12. Must Unicode grapheme clusters be preserved so accented text, emoji, and non-ASCII filenames are never split into invalid or visually broken fragments?
13. How should a pathological case be handled when even the ellipsis does not fit—empty output, ellipsis only, or the first grapheme?
14. Is end truncation always correct for menu labels, including filenames, while the existing left truncation for paths and breadcrumbs remains unchanged?
15. Should whitespace be preserved exactly, or may trailing whitespace be removed before adding an ellipsis?

## Themes, font metrics, and resilience

16. Must fitting work against `Theme.current().font` so future themes with different body fonts automatically get correct results?
17. Should the existing `Theme.width/2` measurement API be reused, including its fallback estimate when Scenic font metadata is unavailable, rather than introducing scene-specific font-metrics lookup?
18. If font metadata is unavailable, is conservative truncation acceptable, provided graph construction still succeeds on the host and labels do not visibly cross their bounds?
19. Does the solution need to account for font overhang/bearing beyond the advance width, or is Scenic’s `FontMetrics.width/3` advance measurement the project’s accepted definition of “fits”?

## Testing and acceptance

20. Which representative names demonstrate the bug on hardware and should become regression cases—for example narrow-glyph names that exceed 15 characters but fit, wide-glyph names that still require truncation, and expandable versus leaf entries?
21. Should graph-level tests assert the exact rendered strings for both fitting and truncated labels, while a focused helper test verifies measured width stays within each row’s pixel budget?
22. Should acceptance cover both the focused column and the right-hand preview listing, since they currently render at different font sizes (18 px and 16 px)?
23. Is a host `mix test` run sufficient for automated verification, with a manual 640×480 host-window or device check recommended to confirm the visual padding and chevron separation?
24. Are there performance constraints from measuring multiple candidate prefixes on each repaint, or is a simple implementation acceptable for at most ten visible rows per pane?

## Compatibility and non-goals

25. Must browser navigation, cursor/windowing behavior, node data, and launcher state remain untouched, keeping the change entirely inside presentation code and tests?
26. Should this issue explicitly avoid changing unrelated character-count truncation in captions, empty-state notes, metadata previews, status lines, dialogs, and other scenes?
27. Is adding a reusable pixel-fitting helper to `MayonnaiOS.Theme` desirable for future callers, or should the behavior remain private to `MayonnaiOS.Scene.Home` until another scene needs it?
