defmodule MayonnaiOS.Assets do
  @moduledoc """
  Static asset library. Scenic 0.11 resolves fonts and images through a
  compiled asset module rather than at runtime, so text will not render
  without one.
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
    ]
end
