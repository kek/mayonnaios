defmodule MayonnaiOS.Assets do
  @moduledoc """
  Static asset library. Scenic 0.11 resolves fonts and images through a
  compiled asset module rather than at runtime, so text will not render
  without one.
  """
  use Scenic.Assets.Static,
    otp_app: :mayonnaios,
    sources: [
      "assets",
      {:scenic, "deps/scenic/assets"}
    ],
    alias: [roboto: "fonts/roboto.ttf"]
end
