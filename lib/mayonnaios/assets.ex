defmodule MayonnaiOS.Assets do
  @moduledoc """
  Static asset library. Scenic 0.11 resolves fonts and images through a
  compiled asset module rather than at runtime, so text will not render
  without one.

  ## The fonts this firmware adds

  Each face lives under `assets/fonts/<name>/` with its own licence file
  sitting next to it. The Google Fonts faces use `OFL.txt`; Pixel Operator
  ships `LICENSE.txt` from its DaFont bundle, currently CC0 1.0. Scenic's
  asset pipeline only recognizes `*.ttf`, and `truetype_metrics` only parses
  the `glyf`-flavoured sfnt version tag, so an OpenType/CFF font (`.otf`)
  silently fails to become a usable asset. That rules out a few
  otherwise-attractive retro candidates (Departure Mono, Spleen) that only
  ship OTF/BDF/PCF -- worth knowing before reaching for another font here.

  `:pixel_operator` is `MayonnaiOS.Theme`'s body font: the larger HB face
  from the Pixel Operator bundle, chosen after device testing because it keeps
  the pixel shape cleaner at launcher sizes. `:dot_gothic_16` remains
  available to themes as the previous body face. `:vt323` is a narrower
  CRT-terminal alternative (~0.4 em) kept available to themes.
  `:press_start_2p` is the theme's title font -- genuinely 8-bit NES, but far
  wider still per glyph (measured with `FontMetrics.width/3`), so it is only
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
      pixel_operator: "fonts/pixel_operator/PixelOperatorHB.ttf",
      dot_gothic_16: "fonts/dot_gothic_16/DotGothic16-Regular.ttf",
      vt323: "fonts/vt323/VT323-Regular.ttf",
      press_start_2p: "fonts/press_start_2p/PressStart2P-Regular.ttf"
    ]
end
