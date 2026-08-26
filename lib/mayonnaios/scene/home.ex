defmodule MayonnaiOS.Scene.Home do
  @moduledoc """
  The home screen: the column browser, drawn NeXTSTEP-style.

  ## Where the columns come from

  This scene renders `MayonnaiOS.Browser` and owns none of it.
  `MayonnaiOS.Launcher` owns the gamepad and therefore every cursor, and it
  passes the whole browser in as the scene's start argument. That has to be
  the direction of travel: `Scenic.ViewPort.set_root/3` terminates this
  process and starts a new one on every repaint, so anything this scene
  remembered would be lost the moment a program exited.

  ## What the panel shows

  The breadcrumb line names every open level even when only the deepest
  columns fit on the panel, so a one-column view still says where it is.
  Below it, the last one, two or three levels -- the browser's `columns`
  setting, cycled with Y -- drawn side by side. The cursor lives in the
  rightmost column; in the columns left of it the highlighted row is the one
  that is open, which is how a column browser shows where you came from.

  The footer names the buttons, because a handheld has no tooltips: the same
  rule as `MayonnaiOS.Scene.FileManager`, and the same bottom line carries
  the power-off question and a program's obituary when there is one -- the
  panel asking or reporting outranks it labelling.
  """

  use Scenic.Scene

  alias MayonnaiOS.Browser
  alias MayonnaiOS.Scene.StatusBar
  alias Scenic.Graph
  import Scenic.Primitives

  @width 640
  @height 480

  # The shared top bar owns the top of the panel on every screen, so this one
  # starts its breadcrumb below it rather than at the top edge. The height
  # comes from the bar rather than being copied, so moving it moves every
  # screen.
  @status_bar StatusBar.height()
  @title_y @status_bar + 20
  @rule_y @status_bar + 30

  # Same palette as MayonnaiOS.Scene.Diagnostics and Scene.FileManager, so
  # the screens read as one device rather than three programs sharing a panel.
  @bg {12, 14, 22}
  @title {235, 238, 245}
  @head {90, 170, 255}
  @label {150, 165, 195}
  @wait {235, 190, 90}
  @dim {110, 125, 155}
  @row_bg {26, 34, 52}

  # The column area: captions first, rows below, ten to a column. Ten rows of
  # 26 px pitch end well clear of the message lines and the footer, which is
  # where the power-off question and an obituary go.
  @top @rule_y + 16
  @caption_y @top + 10
  @rows_top @top + 20
  @pitch 26
  @visible 10

  @left 20
  @span @width - 40
  @gutter 12

  @footer_rule 430
  @footer_y 452

  @impl Scenic.Scene
  def init(scene, param, _opts) do
    # The boot root comes from `default_scene:` in config, which Scenic starts
    # with a nil param -- only the Launcher's own set_root/3 passes the map.
    browser =
      case param do
        %{browser: %{levels: _} = browser} -> browser
        _ -> Browser.new()
      end

    confirming = match?(%{confirming: true}, param)

    obituary =
      case param do
        %{obituary: %{} = obituary} -> obituary
        _ -> nil
      end

    {:ok, push_graph(scene, graph(browser, confirming, obituary))}
  end

  @doc """
  Build the column graph for a browser.

  Public because it is the tested surface: it needs no viewport, no driver
  and no framebuffer, so a host test can assert what the panel says for the
  root column, a deep descent, each column-count setting, the power-off
  question and an obituary -- the shapes that would otherwise only be found
  by looking at the device.
  """
  @spec graph(Browser.t(), boolean(), map() | nil) :: Scenic.Graph.t()
  def graph(browser, confirming \\ false, obituary \\ nil) do
    base()
    |> breadcrumb(browser)
    |> columns(browser)
    |> notice(browser, confirming, obituary)
  end

  defp base do
    Graph.build(font: :roboto, font_size: 16)
    |> rect({@width, @height}, fill: {:color, @bg})
    |> StatusBar.mount()
    |> rect({@span, 2}, fill: {:color, @head}, translate: {@left, @rule_y})
  end

  # Every open level by name, however many columns are drawn. The tail is
  # kept when it runs long: where you are matters more than where you began,
  # and the root is always one Menu press away.
  defp breadcrumb(graph, browser) do
    trail = browser |> Browser.trail() |> Enum.join(" > ")

    text(graph, truncate_left(trail, 64),
      font_size: 18,
      fill: {:color, @title},
      translate: {@left, @title_y}
    )
  end

  defp columns(graph, browser) do
    levels = Browser.visible(browser)
    count = length(levels)
    width = div(@span - @gutter * (count - 1), count)

    levels
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {level, index}, acc ->
      x = @left + index * (width + @gutter)

      acc
      |> separator(x, index)
      |> column(level, x, width, index == count - 1)
    end)
  end

  # A hairline between columns, so two listings never read as one.
  defp separator(graph, _x, 0), do: graph

  defp separator(graph, x, _index) do
    rect(graph, {1, @rows_top + @visible * @pitch - @top},
      fill: {:color, @row_bg},
      translate: {x - div(@gutter, 2) - 1, @top}
    )
  end

  defp column(graph, level, x, width, focused?) do
    graph
    |> caption(level, x, width, focused?)
    |> rows(level, x, width, focused?)
  end

  # The column's name, and -- for the focused column when the listing is
  # windowed -- where the cursor is in it, as a count rather than a scrollbar.
  defp caption(graph, level, x, width, focused?) do
    count = length(level.entries)

    position =
      if focused? and count > @visible, do: "  #{level.cursor + 1} of #{count}", else: ""

    text(graph, truncate(level.title, name_chars(width)) <> position,
      font_size: 12,
      fill: {:color, @dim},
      translate: {x, @caption_y}
    )
  end

  # An empty column says why it is empty -- "Empty.", "No pickles installed.",
  # or what went wrong reading it -- where its rows would have been.
  defp rows(graph, %{entries: [], note: note}, x, width, _focused?) do
    text(graph, truncate(note || "Empty.", name_chars(width) + 14),
      font_size: 13,
      fill: {:color, @dim},
      translate: {x, @rows_top + 16}
    )
  end

  defp rows(graph, %{entries: entries, cursor: cursor}, x, width, focused?) do
    window = window(entries, cursor, @visible)

    {graph, _y} =
      Enum.reduce(window.rows, {graph, @rows_top}, fn {node, index}, {acc, y} ->
        {row(acc, node, x, width, y, index == window.cursor, focused?), y + @pitch}
      end)

    graph
  end

  defp row(graph, node, x, width, y, selected?, focused?) do
    graph
    |> highlight(x, width, y, selected?, focused?)
    |> text(truncate(node.name, name_chars(width)),
      font_size: 16,
      fill: {:color, name_colour(node, selected? and focused?)},
      translate: {x + 12, y + 17}
    )
    |> marker(node, x, width, y)
  end

  # One filled rect for the open row in any column; the accent bar only in
  # the focused one, so a glance says which column the D-pad is moving.
  defp highlight(graph, _x, _width, _y, false, _focused?), do: graph

  defp highlight(graph, x, width, y, true, focused?) do
    graph = rect(graph, {width, @pitch - 4}, fill: {:color, @row_bg}, translate: {x, y})

    if focused? do
      rect(graph, {4, @pitch - 4}, fill: {:color, @head}, translate: {x, y})
    else
      graph
    end
  end

  # The right edge of a row: a chevron on anything that opens as another
  # column, words on the leaves that have something to say -- a size, a link,
  # a binary the image does not have.
  defp marker(graph, node, x, width, y) do
    if Browser.expandable?(node) do
      text(graph, ">", font_size: 14, fill: {:color, @dim}, translate: {x + width - 12, y + 17})
    else
      case detail(node, width) do
        "" ->
          graph

        words ->
          text(graph, words,
            font_size: 12,
            fill: {:color, detail_colour(node)},
            translate: {x + width - 96, y + 16}
          )
      end
    end
  end

  # Details need room; the narrow three-column setting drops them and keeps
  # the names, which is the trade the person cycling columns chose.
  defp detail(_node, width) when width < 240, do: ""

  defp detail(%{kind: :program, program: %{installed?: false}}, _width), do: "not installed"
  defp detail(%{kind: :file, entry: %{broken?: true}}, _width), do: "broken link"
  defp detail(%{kind: :file, entry: %{link: link}}, _width) when is_binary(link), do: "link"
  defp detail(%{kind: :file, entry: %{type: :regular, size: size}}, _width), do: size(size)
  defp detail(%{kind: :file, entry: %{type: type}}, _width), do: to_string(type)
  defp detail(_node, _width), do: ""

  defp detail_colour(%{kind: :program, program: %{installed?: false}}), do: @wait
  defp detail_colour(%{kind: :file, entry: %{broken?: true}}), do: @wait
  defp detail_colour(_node), do: @dim

  defp name_colour(%{kind: :file, entry: %{broken?: true}}, _selected?), do: @wait
  defp name_colour(_node, true), do: @title
  defp name_colour(%{kind: :program, program: %{installed?: false}}, _selected?), do: @dim

  defp name_colour(%{kind: kind}, false) when kind in [:category, :place, :dir], do: @head
  defp name_colour(_node, false), do: @label

  # How many characters fit a column at this width, at font 16 with the
  # highlight inset on the left and the chevron or detail on the right.
  defp name_chars(width) when width >= 500, do: 52
  defp name_chars(width) when width >= 240, do: 22
  defp name_chars(_width), do: 18

  # Window the rows when a listing outgrows its column, keeping the cursor on
  # screen. Without this the hundredth ROM in a directory would be selected
  # somewhere nobody can see, and nothing would look wrong.
  defp window(items, cursor, visible) do
    count = length(items)
    cursor = if count == 0, do: 0, else: min(max(cursor, 0), count - 1)
    start = min(max(0, cursor - visible + 1), max(0, count - visible))

    %{rows: items |> Enum.slice(start, visible) |> Enum.with_index(start), cursor: cursor}
  end

  # -- the bottom line ----------------------------------------------------------

  # One notice at a time, on the footer line. The power-off question wins
  # over an obituary: it is the panel asking for a decision, and the obituary
  # keeps -- it is still in the Launcher's state, and comes back the moment
  # the question is answered. With nothing to ask or report, the line labels
  # the buttons.
  defp notice(graph, _browser, true, _obituary) do
    graph
    |> footer_rule()
    |> text("Power off? Y switches off. Any other button keeps it on.",
      font_size: 16,
      fill: {:color, @wait},
      translate: {@left, @footer_y}
    )
  end

  defp notice(graph, browser, false, nil) do
    hint =
      "A opens. B closes a column. Y cycles columns (#{browser.columns}). " <>
        "X diagnostics. Menu goes to the top."

    graph
    |> footer_rule()
    |> text(hint, font_size: 13, fill: {:color, @dim}, translate: {@left, @footer_y})
  end

  # Why the last program died, quoted from its own last words. The headline
  # is amber like the power-off question -- the panel reporting, not asking --
  # and the quoted lines are dim so the reason reads before the evidence.
  # Status nil is a spawn that raised rather than a program that exited; the
  # words are then the exception's, and "exited" would be a lie.
  defp notice(graph, _browser, false, %{name: name, status: status, lines: lines}) do
    headline =
      case status do
        nil -> "#{name} would not start. B clears this."
        status -> "#{name} exited (#{status}). B clears this."
      end

    graph = footer_rule(graph)

    lines
    # Two lines and 88 characters: what fits between the rows and the
    # headline at this font.
    |> Enum.take(-2)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {line, up}, g ->
      text(g, String.slice(line, 0, 88),
        font_size: 13,
        fill: {:color, @dim},
        translate: {@left, @footer_rule - 8 - up * 18}
      )
    end)
    |> text(headline, font_size: 16, fill: {:color, @wait}, translate: {@left, @footer_y})
  end

  defp footer_rule(graph) do
    rect(graph, {@span, 1}, fill: {:color, @dim}, translate: {@left, @footer_rule})
  end

  # -- words --------------------------------------------------------------------

  # Powers of 1024 with df's one-letter units, because that is what the rest
  # of this project's numbers are quoted in.
  defp size(nil), do: ""
  defp size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp size(bytes) do
    {value, unit} =
      cond do
        bytes >= 1024 * 1024 * 1024 -> {bytes / (1024 * 1024 * 1024), "G"}
        bytes >= 1024 * 1024 -> {bytes / (1024 * 1024), "M"}
        true -> {bytes / 1024, "K"}
      end

    "#{:erlang.float_to_binary(value, decimals: 1)}#{unit}"
  end

  defp truncate(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit - 1) <> "…", else: text
  end

  # For the breadcrumb, keep the end: where you are matters more than where
  # you began.
  defp truncate_left(text, limit) do
    if String.length(text) > limit do
      "…" <> String.slice(text, String.length(text) - limit + 1, limit)
    else
      text
    end
  end
end
