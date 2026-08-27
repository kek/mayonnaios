defmodule MayonnaiOS.Assets do
  @moduledoc """
  Static asset library. Scenic 0.11 resolves fonts and images through a
  compiled asset module rather than at runtime, so text will not render
  without one.

  ## The two fonts this firmware adds

  `assets/fonts/vt323/VT323-Regular.ttf` and
  `assets/fonts/press_start_2p/PressStart2P-Regular.ttf`, each with its own
  `OFL.txt` sitting next to it. Both come straight from Google Fonts'
  upstream repository (`google/fonts`, `ofl/vt323` and `ofl/pressstart2p`),
  which ships genuine TrueType outlines -- Scenic's asset pipeline only
  recognizes `*.ttf`, and `truetype_metrics` only parses the `glyf`-flavoured
  sfnt version tag, so an OpenType/CFF font (`.otf`) silently fails to become
  a usable asset. That ruled out a few otherwise-attractive retro candidates
  (Departure Mono, Spleen) that only ship OTF/BDF/PCF -- worth knowing before
  reaching for another font here.

  `:vt323` is `MayonnaiOS.Theme`'s body font: a CRT-terminal face that stays
  legible at the small sizes this 640x480 panel draws at. `:press_start_2p`
  is the theme's title font -- genuinely 8-bit NES, but roughly 2.8x wider
  per glyph than vt323 (measured with `FontMetrics.width/3`), so it is only
  ever used on fixed, short strings. Nothing in this app pipes arbitrary or
  long text through it; a breadcrumb or a filename would run off the panel.
  """
  # No `alias:` entry for roboto. Scenic's own asset source already registers
  # :roboto and :roboto_mono, and declaring the alias again resolves the path
  # against *this* app rather than against scenic, which warns
  #
  #     Attempted to alias :roboto to unknown asset: "fonts/roboto.ttf"
  #
  # on every compile while still working, because the built-in alias wins.
  use Scenic.Assets.Static,
    otp_app: :mayonnaios,
    sources: [
      "assets",
      {:scenic, "deps/scenic/assets"}
    ],
    alias: [
      vt323: "fonts/vt323/VT323-Regular.ttf",
      press_start_2p: "fonts/press_start_2p/PressStart2P-Regular.ttf"
    ]
end
