defmodule MayonnaiOS.Screen do
  @moduledoc """
  The panel's size in pixels, for layout.

  Read from the configured Scenic viewport at compile time, because firmware
  is built for one board and every scene lays itself out from module
  attributes. The board's config file sets the viewport, and
  `MayonnaiOS.Device` refuses to start if the profile's `panel_size`
  disagrees with it, so these numbers are the panel's.

  Scenes take `width/0` and `height/0` into module attributes; anything that
  must fit the panel is derived from those rather than written as a literal.
  """

  @size Application.compile_env!(:mayonnaios, [:viewport, :size])

  @doc "`{width, height}` in pixels."
  @spec size() :: {pos_integer(), pos_integer()}
  def size, do: @size

  @doc "The panel width in pixels."
  @spec width() :: pos_integer()
  def width, do: elem(@size, 0)

  @doc "The panel height in pixels."
  @spec height() :: pos_integer()
  def height, do: elem(@size, 1)
end
