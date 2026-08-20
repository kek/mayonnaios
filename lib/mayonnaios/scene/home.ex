defmodule MayonnaiOS.Scene.Home do
  @moduledoc """
  The launcher menu: what can be run, and which entry is selected.

  ## What used to be here

  This scene was a page of demo shapes -- a circle, a square, a triangle, an
  arc and two lines of text -- chosen so each would fail differently: filled
  rects proved the framebuffer blit, the arc proved path rasterisation, the
  text proved freetype was in the image. All three are verified on hardware
  now, and the menu still exercises every one of them (rects for the rows and
  the highlight, text for the names). The shapes were retired rather than
  quietly deleted; there is nothing left to learn from them.

  ## Where the selection comes from

  This scene renders the cursor, it does not own it. `MayonnaiOS.Launcher`
  owns `event0` and therefore the D-pad, and it passes the selected index in
  as the scene's start argument. That has to be the direction of travel:
  `Scenic.ViewPort.set_root/3` terminates this process and starts a new one on
  every repaint, so anything this scene remembered would be lost the moment a
  program exited.

  The list itself is read here from `MayonnaiOS.Programs`, the same
  deterministic source the Launcher indexes into, so the row highlighted on
  screen is the row A will start.
  """

  use Scenic.Scene

  alias Scenic.Graph
  alias MayonnaiOS.Programs
  import Scenic.Primitives

  @width 640
  @height 480

  # Same palette as MayonnaiOS.Scene.Diagnostics, so the two screens read
  # as one device rather than two programs that happen to share a panel.
  @bg {12, 14, 22}
  @title {235, 238, 245}
  @head {90, 170, 255}
  @label {150, 165, 195}
  @wait {235, 190, 90}
  @dim {110, 125, 155}
  @row_bg {26, 34, 52}

  # 34 px of pitch at font_size 20 leaves the rows legible at arm's length on
  # a 640x480 panel held in two hands.
  @top 64
  @pitch 34
  @visible 10

  @impl Scenic.Scene
  def init(scene, param, _opts) do
    # The boot root comes from `default_scene:` in config, which Scenic starts
    # with a nil param -- only the Launcher's own set_root/3 passes the map.
    selected =
      case param do
        %{selected: i} when is_integer(i) -> i
        _ -> 0
      end

    {:ok, push_graph(scene, graph(Programs.list(), selected))}
  end

  @doc """
  Build the menu graph for `programs` with row `selected` highlighted.

  Public because it is the tested surface: it needs no viewport, no driver
  and no framebuffer, so the host test can assert that a menu builds for an
  empty list, one entry, and a selection at the last index -- the three
  shapes that would otherwise only be found by looking at the device.
  """
  @spec graph([Programs.program()], integer()) :: Scenic.Graph.t()
  def graph(programs, selected \\ 0)

  def graph([], _selected) do
    base()
    |> text("No programs configured.", font_size: 20, fill: {:color, @title}, translate: {20, 90})
    |> text("Set config :mayonnaios, :programs in config/target.exs.",
      font_size: 14,
      fill: {:color, @label},
      translate: {20, 116}
    )
  end

  def graph(programs, selected) do
    count = length(programs)
    selected = Integer.mod(selected, count)

    # Window the rows when the list outgrows the panel. Without this a twelfth
    # entry would be selected off-screen and nothing would look wrong.
    start = min(max(0, selected - @visible + 1), max(0, count - @visible))
    rows = Enum.slice(programs, start, @visible)

    # Compare indices, not entries: two entries with the same name and path is
    # a silly config but a legal one, and comparing maps would highlight both.
    {graph, _y} =
      rows
      |> Enum.with_index(start)
      |> Enum.reduce({base(), @top}, fn {program, index}, {g, y} ->
        {row(g, program, y, index == selected), y + @pitch}
      end)

    graph
    |> position(start, count)
  end

  defp base do
    Graph.build(font: :roboto, font_size: 20)
    |> rect({@width, @height}, fill: {:color, @bg})
    |> text("RG40XXV", font_size: 20, fill: {:color, @title}, translate: {20, 28})
    |> rect({@width - 40, 2}, fill: {:color, @head}, translate: {20, 38})
  end

  defp row(graph, program, y, selected?) do
    graph
    |> highlight(y, selected?)
    |> text(program.name,
      fill: {:color, name_colour(program, selected?)},
      translate: {36, y + 21}
    )
    |> missing(program, y)
  end

  # One filled rect plus a 4 px accent bar. A filled row alone is hard to see
  # on a dim panel in daylight; the bar survives it.
  defp highlight(graph, _y, false), do: graph

  defp highlight(graph, y, true) do
    graph
    |> rect({@width - 40, @pitch - 4}, fill: {:color, @row_bg}, translate: {20, y})
    |> rect({4, @pitch - 4}, fill: {:color, @head}, translate: {20, y})
  end

  defp missing(graph, %{installed?: true}, _y), do: graph

  defp missing(graph, _program, y) do
    # Amber, and the word rather than an icon: this is the panel telling
    # whoever holds the device that the firmware and the config disagree.
    text(graph, "not installed", font_size: 14, fill: {:color, @wait}, translate: {470, y + 21})
  end

  defp name_colour(%{installed?: false}, _selected?), do: @dim
  defp name_colour(_program, true), do: @title
  defp name_colour(_program, false), do: @label

  # Only when the list is windowed, and then only as a count: the point is to
  # say that rows exist above or below, not to draw a scrollbar.
  defp position(graph, _start, count) when count <= @visible, do: graph

  defp position(graph, start, count) do
    text(graph, "#{start + 1}-#{min(start + @visible, count)} of #{count}",
      font_size: 14,
      fill: {:color, @dim},
      translate: {520, 28}
    )
  end
end
