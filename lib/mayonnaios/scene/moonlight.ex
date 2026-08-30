defmodule MayonnaiOS.Scene.Moonlight do
  @moduledoc """
  What the panel shows while `MayonnaiOS.Moonlight.App` has the buttons.

  Draws `MayonnaiOS.Moonlight.App.snapshot/0` and nothing else, told when to
  redraw by `App.watch/1` -- the same arrangement as `MayonnaiOS.Scene.Update`
  and for the same reason: `set_root/3` terminates this scene on every repaint
  the launcher does, so nothing may be remembered here.

  ## One screen or the other

  With the editor open the rows are gone and the character cells have the
  panel. A settings list with a text field being edited inside one of its rows
  would put a caret in a 15 px cell inside a 34 px row on a 640x480 display,
  and there is no reading that. The row being edited is named above the cells
  instead, so nothing is lost but the six values that are not being changed.

  ## The line under the rows is the manual

  A handheld has no tooltips, so the selected row's note is drawn under the
  list: what the address is for, why 30 fps rather than 60, what to lower
  first when the picture stutters. It changes with the cursor, which makes the
  D-pad the way to read the manual as well as the way to change the setting.
  """

  use Scenic.Scene

  alias MayonnaiOS.Moonlight
  alias MayonnaiOS.Moonlight.App
  alias MayonnaiOS.Scene.StatusBar
  alias MayonnaiOS.Theme
  alias Scenic.Graph

  import Scenic.Primitives

  @width 640
  @height 480

  # The shared top bar owns the top of the panel on every screen, so the title
  # starts below it. The height comes from the bar rather than being copied.
  @status_bar StatusBar.height()
  @title_y @status_bar + 20
  @rule_y @status_bar + 30

  @head_y @rule_y + 26
  @top @rule_y + 40
  @pitch 34

  @left 20
  @span @width - 2 * @left
  # Where a row's value starts. Far enough right that the longest label
  # ("Host address") clears it at 18 px in the theme's body font.
  @value_x 220

  @note_y 380
  @message_y 408

  # How many characters fit on a full-width 15 px line, and in the gap between
  # a row's label and the right edge at 18 px. The theme's body font runs
  # about half its size per glyph -- "Host address" is 108 px at 18 -- so
  # these are that arithmetic rather than a guess, and they are what keeps a
  # long hostname or a long errno from running off the panel.
  @line_chars 78
  @value_chars 44

  @footer_rule 446
  @footer_y 466

  # The editor draws one character per cell so the caret can sit under exactly
  # one of them -- the browser's rename editor's argument, and its geometry.
  @cell 15
  @cells 36
  @cells_y @top + 60

  # Every colour comes from the current `MayonnaiOS.Theme` rather than a
  # module attribute, for the reason `MayonnaiOS.Scene.Home` gives: a theme is
  # chosen at runtime and an attribute is a compile-time constant.
  defp font, do: Theme.current().font
  defp bg, do: Theme.current().bg
  defp title, do: Theme.current().title
  defp head, do: Theme.current().head
  defp label, do: Theme.current().label
  defp pass, do: Theme.current().pass
  defp fail, do: Theme.current().fail
  defp wait, do: Theme.current().wait
  defp dim, do: Theme.current().dim
  defp row_bg, do: Theme.current().row_bg

  @impl Scenic.Scene
  def init(scene, _param, _opts) do
    {:ok, show(scene, watch())}
  end

  @impl GenServer
  def handle_info({:moonlight_app, snapshot}, scene), do: {:noreply, show(scene, snapshot)}
  def handle_info(_message, scene), do: {:noreply, scene}

  # The app not running is a state to render rather than crash on, matching
  # `MayonnaiOS.Scene.Update`.
  defp watch do
    App.watch(self())
  rescue
    _error -> :stopped
  catch
    :exit, _reason -> :stopped
  end

  defp show(scene, snapshot), do: push_graph(scene, graph(snapshot))

  @doc """
  The height of the strip this scene leaves for the shared top bar, public so
  a test can assert that nothing is drawn above it.
  """
  @spec status_bar() :: pos_integer()
  def status_bar, do: @status_bar

  @doc """
  Build the graph for a snapshot.

  Public because it is the tested surface: no viewport, no driver and no
  framebuffer, so a host test can assert what the panel says for a device with
  no bundle, an unset address, an open editor and a failed write -- states
  that would otherwise only be findable by holding the device.
  """
  @spec graph(map() | :stopped) :: Scenic.Graph.t()
  def graph(:stopped) do
    base()
    |> text("Not running", font_size: 22, fill: {:color, fail()}, translate: {@left, @top + 20})
    |> footer("Menu goes back.")
  end

  def graph(%{editor: editor} = snapshot) when editor != nil do
    base()
    |> heading(snapshot)
    |> text(editor_label(editor),
      font_size: 18,
      fill: {:color, title()},
      translate: {@left, @top + 24}
    )
    |> cells(editor)
    |> text("Left and right move. Up and down change the character.",
      font_size: 16,
      fill: {:color, label()},
      translate: {@left, @cells_y + 62}
    )
    |> text("Y removes it. A keeps it.",
      font_size: 16,
      fill: {:color, label()},
      translate: {@left, @cells_y + 84}
    )
    |> footer("Nothing is written until the Save row.")
  end

  def graph(snapshot) do
    base()
    |> heading(snapshot)
    |> rows(snapshot)
    |> note(snapshot)
    |> message(snapshot)
    |> footer(footer_words(snapshot))
  end

  defp base do
    Graph.build(font: font(), font_size: 18)
    |> rect({@width, @height}, fill: {:color, bg()})
    |> StatusBar.mount()
    |> text("Moonlight settings",
      font_size: 20,
      fill: {:color, title()},
      translate: {@left, @title_y}
    )
    |> rect({@span, 2}, fill: {:color, head()}, translate: {@left, @rule_y})
  end

  # One line saying what is being edited and whether it has been saved. The
  # bundle being absent comes first when it is: a config file for a program
  # that is not installed is still worth writing, and is also the more useful
  # thing to be told.
  defp heading(graph, snapshot) do
    {words, colour} = heading_words(snapshot)

    text(graph, truncate_left(words, @line_chars),
      font_size: 15,
      fill: {:color, colour},
      translate: {@left, @head_y}
    )
  end

  defp heading_words(%{installed?: false}),
    do: {"Moonlight is not installed. These settings will be waiting when it is.", wait()}

  defp heading_words(%{unsaved?: true}), do: {"Unsaved changes.", wait()}
  defp heading_words(%{source: :file, path: path}), do: {path, dim()}

  defp heading_words(%{source: :template}),
    do: {"The bundle's defaults. Nothing has been saved on this device yet.", dim()}

  defp heading_words(_snapshot),
    do: {"Defaults. Nothing has been saved on this device yet.", dim()}

  # -- the rows -------------------------------------------------------------------

  defp rows(graph, snapshot) do
    App.rows()
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {row, index}, acc ->
      draw_row(acc, row, index, snapshot)
    end)
  end

  defp draw_row(graph, row, index, snapshot) do
    y = @top + index * @pitch
    selected? = index == snapshot.cursor

    graph
    |> row_background(y, selected?)
    |> text(row.label,
      font_size: 18,
      fill: {:color, if(selected?, do: title(), else: label())},
      translate: {@left + 8, y + 22}
    )
    |> row_value(row, y, selected?, snapshot)
  end

  defp row_background(graph, _y, false), do: graph

  defp row_background(graph, y, true) do
    rect(graph, {@span, @pitch - 4}, fill: {:color, row_bg()}, translate: {@left, y})
  end

  # The Save row's "value" is what pressing A on it does, which is the only
  # thing on this screen that touches the disk and so the only one worth
  # spelling out where a value would be.
  defp row_value(graph, %{id: :save}, y, selected?, snapshot) do
    text(graph, save_words(snapshot),
      font_size: 16,
      fill: {:color, if(selected?, do: head(), else: dim())},
      translate: {@value_x, y + 22}
    )
  end

  defp row_value(graph, row, y, selected?, snapshot) do
    value = Moonlight.display(row, snapshot.settings)
    set? = Map.get(snapshot.settings, row.id, "") != ""

    graph
    |> text(truncate(value, @value_chars),
      font_size: 18,
      fill: {:color, value_colour(set?, selected?)},
      translate: {@value_x, y + 22}
    )
    |> arrows(row, y, selected?)
  end

  # An unset value is drawn in the dim colour whether or not the cursor is on
  # it, so "not set" cannot be mistaken for a value that happens to say that.
  defp value_colour(false, _selected?), do: dim()
  defp value_colour(true, true), do: title()
  defp value_colour(true, false), do: label()

  # Little chevrons on the selected choice row, because "left and right change
  # this" is not discoverable from a row that looks exactly like the text rows
  # above and below it.
  defp arrows(graph, %{kind: :choice}, y, true) do
    graph
    |> text("<", font_size: 18, fill: {:color, head()}, translate: {@value_x - 22, y + 22})
    |> text(">", font_size: 18, fill: {:color, head()}, translate: {@left + @span - 24, y + 22})
  end

  defp arrows(graph, _row, _y, _selected?), do: graph

  defp save_words(%{unsaved?: true}), do: "A writes the changes"
  defp save_words(_snapshot), do: "nothing to write"

  # -- the lines under the rows -----------------------------------------------------

  # The selected row's note, which is the manual; see the moduledoc.
  defp note(graph, snapshot) do
    case Enum.at(App.rows(), snapshot.cursor) do
      %{note: words} when is_binary(words) and words != "" ->
        text(graph, words, font_size: 15, fill: {:color, label()}, translate: {@left, @note_y})

      _other ->
        graph
    end
  end

  # A stream needs an address and this screen is where one would notice it is
  # missing, so the absence is said out loud rather than left to the "not set"
  # on a row that may be scrolled past.
  defp message(graph, %{message: nil} = snapshot) do
    if Map.get(snapshot.settings, :address, "") == "" do
      text(graph, "A stream cannot start without a host address.",
        font_size: 15,
        fill: {:color, wait()},
        translate: {@left, @message_y}
      )
    else
      graph
    end
  end

  defp message(graph, %{message: {level, words}}) do
    colour = if level == :error, do: fail(), else: pass()

    text(graph, truncate_left(words, @line_chars),
      font_size: 15,
      fill: {:color, colour},
      translate: {@left, @message_y}
    )
  end

  defp footer_words(%{cursor: cursor}) do
    case Enum.at(App.rows(), cursor) do
      %{kind: :choice} -> "Left and right change it. Menu goes back."
      %{kind: :text} -> "A edits it. Menu goes back."
      _save -> "A saves. Moonlight reads the file when it starts. Menu goes back."
    end
  end

  defp footer(graph, words) do
    graph
    |> rect({@span, 1}, fill: {:color, dim()}, translate: {@left, @footer_rule})
    |> text(words, font_size: 14, fill: {:color, label()}, translate: {@left, @footer_y})
  end

  # -- the editor ---------------------------------------------------------------

  defp editor_label(%{id: id}) do
    case Enum.find(Moonlight.fields(), &(&1.id == id)) do
      %{label: label} -> label
      nil -> to_string(id)
    end
  end

  # One character per cell, and the caret is a box under a cell rather than a
  # bar between two: with a proportional font there is no honest way to draw a
  # bar in the right place, and a caret in the wrong place is worse than none.
  defp cells(graph, %{chars: chars, caret: caret}) do
    count = length(chars)
    # The append slot is a cell too, so a value can be grown at the end.
    start = min(max(0, caret - @cells + 1), max(0, count + 1 - @cells))

    Enum.reduce(0..(@cells - 1), graph, fn column, acc ->
      index = start + column
      x = @left + 4 + column * @cell

      cond do
        index > count ->
          acc

        index == count ->
          acc
          |> caret_box(x, index == caret)
          |> text("+", font_size: 20, fill: {:color, dim()}, translate: {x + 3, @cells_y + 20})

        true ->
          acc
          |> caret_box(x, index == caret)
          |> text(Enum.at(chars, index),
            font_size: 20,
            fill: {:color, title()},
            translate: {x + 3, @cells_y + 20}
          )
      end
    end)
  end

  defp caret_box(graph, _x, false), do: graph

  defp caret_box(graph, x, true) do
    rect(graph, {@cell, 28},
      fill: {:color, row_bg()},
      stroke: {1, head()},
      translate: {x, @cells_y}
    )
  end

  # -- fitting the panel ----------------------------------------------------------

  defp truncate(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit - 1) <> "…", else: text
  end

  # For the heading, which is usually a path: `MayonnaiOS.Scene.Home`'s
  # argument applies unchanged -- the end of a path is the part that says
  # which file, and the start is the part every path on this device shares.
  defp truncate_left(text, limit) do
    if String.length(text) > limit do
      "…" <> String.slice(text, String.length(text) - limit + 1, limit)
    else
      text
    end
  end
end
