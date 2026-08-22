defmodule MayonnaiOS.Scene.FileManager do
  @moduledoc """
  What the panel shows while the file manager has the buttons.

  It draws `MayonnaiOS.FileManager.snapshot/0` and nothing else: no cursor of
  its own, no listing of its own, no path of its own. `set_root/3` terminates
  a scene and starts a new one on every repaint the launcher does, so anything
  remembered here would be lost at the first opportunity -- the same reason
  `MayonnaiOS.Scene.Home` takes its cursor as a start argument.

  It is told when to redraw rather than polling for it. `FileManager.watch/1`
  registers this process, and a snapshot arrives as `{:file_manager, snapshot}`
  when a button has changed something. A poll fast enough to feel like a button
  press would be a `GenServer.call` every few frames for the whole time the app
  is open, for a screen that changes only when someone presses something.

  ## The top strip belongs to the shared bar

  It arrived: `MayonnaiOS.Scene.StatusBar`, mounted by every screen in this
  firmware, drawing battery, WiFi and the clock at the top right. This scene
  reserved the strip before there was anything in it and still does not paint
  above `@status_bar` -- the number now comes from the bar itself rather than
  being a second copy of it, so the reservation and the bar cannot drift.

  ## Why the footer says what the buttons do, on every screen

  Y means a different thing in each view -- the actions sheet while browsing,
  the delete on a confirmation, remove-a-character in the rename editor -- and
  a handheld has no tooltips and no manual. So the bottom line of every view
  spells out A, B and Y for that view. It is the cheapest form of the thing
  this whole project keeps relearning: a control nobody can discover is a
  control nobody has.
  """

  use Scenic.Scene

  alias MayonnaiOS.FileManager
  alias MayonnaiOS.Scene.StatusBar
  alias Scenic.Graph

  import Scenic.Primitives

  @width 640
  @height 480

  # Same palette as Scene.Home and Scene.Diagnostics, so the screens read as
  # one device rather than three programs sharing a panel.
  @bg {12, 14, 22}
  @title {235, 238, 245}
  @head {90, 170, 255}
  @label {150, 165, 195}
  @pass {120, 220, 150}
  @fail {245, 110, 120}
  @wait {235, 190, 90}
  @dim {110, 125, 155}
  @row_bg {26, 34, 52}

  # The strip the shared top bar draws in: battery, WiFi, clock. Nothing is
  # drawn above this line. Text is positioned by its baseline, so the first
  # baseline is far enough below the line that the ascenders clear it too --
  # which is where every other screen's title sits now as well.
  @status_bar StatusBar.height()

  @title_y 50
  @path_y 74
  @space_y 90
  @rule_y 98

  @top 104
  @pitch 26
  @visible 11

  # Two lines per row in the list of places -- the path and what it is for --
  # so the row that says where uploads land says it rather than implying it.
  @place_pitch 44
  @places_visible 6

  @message_y 412
  @footer_rule 430
  @footer_y 452

  # A name longer than this is cut, with the tail kept: ROM filenames differ
  # at the end far more often than at the start.
  @name_chars 46

  # The rename editor draws one character per cell so the caret can sit under
  # exactly one of them. A proportional font gives no way to place a caret
  # honestly; a grid does.
  @cell 15
  @cells 36

  @impl Scenic.Scene
  def init(scene, param, _opts) do
    error = if is_map(param), do: Map.get(param, :error), else: nil

    {:ok, scene |> assign(error: error) |> show(watch())}
  end

  @impl GenServer
  def handle_info({:file_manager, snapshot}, scene), do: {:noreply, show(scene, snapshot)}
  def handle_info(_message, scene), do: {:noreply, scene}

  # The app not running is a state to render rather than crash on: it is what
  # the launcher shows when starting failed, and the reason is then the only
  # useful thing on the panel.
  defp watch do
    FileManager.watch(self())
  rescue
    _error -> :stopped
  catch
    :exit, _reason -> :stopped
  end

  defp show(scene, snapshot), do: push_graph(scene, graph(snapshot, scene.assigns[:error]))

  @doc """
  The height of the strip this scene leaves for the shared top bar.

  Public so a test can assert that nothing is drawn above it, which is the
  only way to keep that true through later edits. The number is
  `MayonnaiOS.Scene.StatusBar.height/0`: the bar owns its own height, and this
  screen asks rather than remembering.
  """
  @spec status_bar() :: pos_integer()
  def status_bar, do: @status_bar

  @doc """
  Build the graph for a snapshot.

  Public because it is the tested surface: no viewport, no driver and no
  framebuffer, so a host test can assert what the panel says for an empty
  directory, a windowed listing, a confirmation and a rename -- the states
  that would otherwise only be checked by looking at the device.
  """
  @spec graph(map() | :stopped, term()) :: Scenic.Graph.t()
  def graph(snapshot, error \\ nil)

  def graph(:stopped, error) do
    base("Files")
    |> text("Not running", font_size: 26, fill: {:color, @fail}, translate: {20, 120})
    |> text(reason(error), font_size: 16, fill: {:color, @label}, translate: {20, 150})
    |> footer("Menu goes back.")
  end

  def graph(%{view: :places} = snapshot, _error) do
    base("Files")
    |> text("Where to look", font_size: 18, fill: {:color, @title}, translate: {20, @path_y})
    |> text("the roots this app can open; nothing else is reachable",
      font_size: 12,
      fill: {:color, @dim},
      translate: {20, @space_y}
    )
    |> rule()
    |> places(snapshot)
    |> message(snapshot)
    |> footer("A opens. Menu leaves.")
  end

  def graph(%{view: :browse} = snapshot, _error) do
    base("Files")
    |> header(snapshot)
    |> listing(snapshot)
    |> message(snapshot)
    |> footer(browse_hint(snapshot))
  end

  def graph(%{view: :actions} = snapshot, _error) do
    base("Files")
    |> text(selected_name(snapshot),
      font_size: 18,
      fill: {:color, @title},
      translate: {20, @path_y}
    )
    |> text(detail(snapshot), font_size: 12, fill: {:color, @dim}, translate: {20, @space_y})
    |> rule()
    |> rows(snapshot.actions, snapshot.action_cursor, fn graph, action, y, _selected? ->
      text(graph, action.label, fill: {:color, @title}, translate: {36, y + 16}, font_size: 16)
    end)
    |> footer("A does it. B goes back.")
  end

  def graph(%{view: :confirm, pending: %{entry: entry}} = snapshot, _error) do
    base("Delete")
    |> text("Delete this?", font_size: 26, fill: {:color, @fail}, translate: {20, 70})
    # The tail of the path, not the head: which directory and which file is
    # about to go is the part being confirmed, and "/root/mnt/games/ROMS/…"
    # would be the half that is the same for everything.
    |> text(truncate_left(path_of(snapshot, entry.name), 60),
      font_size: 16,
      fill: {:color, @title},
      translate: {20, 106}
    )
    |> text(what(entry), font_size: 14, fill: {:color, @label}, translate: {20, 130})
    |> text("There is no undo, and no trash to fish it out of.",
      font_size: 14,
      fill: {:color, @wait},
      translate: {20, 176}
    )
    |> text("This device is switched off by pulling its power.",
      font_size: 14,
      fill: {:color, @dim},
      translate: {20, 198}
    )
    |> text("Y deletes it.", font_size: 20, fill: {:color, @fail}, translate: {20, 250})
    |> text("A, B or any direction cancels -- on purpose: the button that",
      font_size: 14,
      fill: {:color, @label},
      translate: {20, 280}
    )
    |> text("got you here is not the button that does it.",
      font_size: 14,
      fill: {:color, @label},
      translate: {20, 300}
    )
    |> footer("Y deletes. Anything else cancels.")
  end

  # A confirmation with nothing pending cannot happen from the app, but the
  # scene is a separate process reading a snapshot and must not crash on one.
  def graph(%{view: :confirm} = snapshot, error), do: graph(%{snapshot | view: :browse}, error)

  def graph(%{view: :rename, rename: %{chars: chars, caret: caret}} = snapshot, _error) do
    base("Rename")
    |> text(truncate(snapshot.rename.name, 60),
      font_size: 14,
      fill: {:color, @dim},
      translate: {20, @path_y}
    )
    |> rule()
    |> cells(chars, caret)
    |> text("Left and right move. Up and down change the character.",
      font_size: 14,
      fill: {:color, @label},
      translate: {20, 220}
    )
    |> text("Y removes it. A saves the name. B cancels.",
      font_size: 14,
      fill: {:color, @label},
      translate: {20, 242}
    )
    |> message(snapshot)
    |> footer("A saves. B cancels. Y removes a character.")
  end

  # A view this scene has no clause for. The app has five and none of them get
  # here, but the scene is a separate process rendering a snapshot it did not
  # produce, and saying so on the panel beats either crashing or drawing the
  # wrong screen convincingly.
  def graph(%{view: view}, _error) do
    base("Files")
    |> text("Nothing to draw for #{inspect(view)}.",
      font_size: 18,
      fill: {:color, @wait},
      translate: {20, 120}
    )
    |> footer("Menu goes back.")
  end

  # -- pieces -----------------------------------------------------------------

  defp base(title) do
    Graph.build(font: :roboto, font_size: 16)
    |> rect({@width, @height}, fill: {:color, @bg})
    |> StatusBar.mount()
    # The title sits below the bar's strip, not in it.
    |> text(title, font_size: 20, fill: {:color, @title}, translate: {20, @title_y})
  end

  defp rule(graph),
    do: rect(graph, {@width - 40, 2}, fill: {:color, @head}, translate: {20, @rule_y})

  defp footer(graph, hint) do
    graph
    |> rect({@width - 40, 1}, fill: {:color, @dim}, translate: {20, @footer_rule})
    |> text(hint, font_size: 14, fill: {:color, @dim}, translate: {20, @footer_y})
  end

  defp header(graph, snapshot) do
    graph
    |> text(truncate_left(snapshot.dir || "", 58),
      font_size: 18,
      fill: {:color, @title},
      translate: {20, @path_y}
    )
    |> text(space_line(snapshot), font_size: 12, fill: {:color, @dim}, translate: {20, @space_y})
    |> rule()
    |> held(snapshot)
  end

  # Free space for the filesystem this directory is on, not for the device.
  # The roots span more than one -- the writable partition and, with the card
  # in, the games card -- and `/` is a full read-only squashfs that is not
  # reachable from here at all.
  defp space_line(%{space: %{device: device, free: free, total: total}}) do
    "#{device} -- #{size(free)} free of #{size(total)}"
  end

  defp space_line(_snapshot), do: "free space unknown: df said nothing this could parse"

  # What is on the clipboard, top right, because a held file that is not shown
  # is a file someone pastes into the wrong place a minute later.
  defp held(graph, %{clipboard: nil}), do: graph

  defp held(graph, %{clipboard: %{mode: mode, name: name}}) do
    text(graph, "holding: #{truncate(name, 24)} (#{mode})",
      font_size: 12,
      fill: {:color, @wait},
      translate: {330, @space_y}
    )
  end

  defp places(graph, %{places: places, place_cursor: cursor}) do
    window = window(places, cursor, @places_visible)

    {graph, _y} =
      Enum.reduce(window.rows, {graph, @top}, fn {place, index}, {acc, y} ->
        selected? = index == window.cursor

        acc =
          acc
          |> highlight(y, selected?, @place_pitch)
          |> text(place.path,
            font_size: 18,
            fill: {:color, if(selected?, do: @title, else: @label)},
            translate: {36, y + 18}
          )
          |> text(place.note, font_size: 12, fill: {:color, @dim}, translate: {36, y + 34})

        {acc, y + @place_pitch}
      end)

    graph
  end

  defp listing(graph, %{entries: [], readable?: false} = snapshot) do
    text(graph, "This directory cannot be read: #{reason_text(snapshot)}",
      font_size: 16,
      fill: {:color, @wait},
      translate: {20, @top + 20}
    )
  end

  defp listing(graph, %{entries: []}) do
    text(graph, "Empty.", font_size: 16, fill: {:color, @dim}, translate: {20, @top + 20})
  end

  defp listing(graph, %{entries: entries, cursor: cursor}) do
    graph
    |> rows(entries, cursor, &entry_row/4)
    |> position(entries, cursor)
  end

  defp entry_row(graph, entry, y, selected?) do
    graph
    |> text(name_of(entry),
      font_size: 16,
      fill: {:color, name_colour(entry, selected?)},
      translate: {36, y + 17}
    )
    |> text(right_of(entry),
      font_size: 13,
      fill: {:color, right_colour(entry)},
      translate: {466, y + 17}
    )
  end

  defp name_of(%{type: :directory, name: name}), do: truncate(name, @name_chars) <> "/"
  defp name_of(%{name: name}), do: truncate(name, @name_chars)

  defp name_colour(%{broken?: true}, _selected?), do: @fail
  defp name_colour(_entry, true), do: @title
  defp name_colour(%{type: :directory}, false), do: @head
  defp name_colour(_entry, false), do: @label

  # A symlink says so, because in two directories on this device -- the core
  # directory and `bundles/retroarch/current` -- everything is one, and a
  # listing that hides that makes a dangling core look like an installed one.
  defp right_of(%{broken?: true}), do: "broken link"
  defp right_of(%{link: link}) when is_binary(link), do: "link"
  defp right_of(%{type: :directory}), do: "folder"
  defp right_of(%{type: :regular, size: size}), do: size(size)
  defp right_of(%{type: type}), do: to_string(type)

  defp right_colour(%{broken?: true}), do: @fail
  defp right_colour(%{link: link}) when is_binary(link), do: @wait
  defp right_colour(_entry), do: @dim

  # A shared row renderer: one filled rect plus a 4 px accent bar for the
  # selection, which is what stays visible on this panel in daylight.
  defp rows(graph, items, cursor, render) do
    window = window(items, cursor, @visible)

    {graph, _y} =
      Enum.reduce(window.rows, {graph, @top}, fn {item, index}, {acc, y} ->
        selected? = index == window.cursor
        {render.(highlight(acc, y, selected?, @pitch), item, y, selected?), y + @pitch}
      end)

    graph
  end

  defp highlight(graph, _y, false, _pitch), do: graph

  defp highlight(graph, y, true, pitch) do
    graph
    |> rect({@width - 40, pitch - 4}, fill: {:color, @row_bg}, translate: {20, y})
    |> rect({4, pitch - 4}, fill: {:color, @head}, translate: {20, y})
  end

  # Window the list when it outgrows the panel, keeping the cursor on screen.
  # Without this the hundredth ROM in a directory would be selected somewhere
  # nobody can see, and nothing would look wrong.
  defp window(items, cursor, visible) do
    count = length(items)
    cursor = if count == 0, do: 0, else: min(max(cursor, 0), count - 1)
    start = min(max(0, cursor - visible + 1), max(0, count - visible))

    %{rows: items |> Enum.slice(start, visible) |> Enum.with_index(start), cursor: cursor}
  end

  defp position(graph, entries, cursor) do
    count = length(entries)

    if count <= @visible do
      graph
    else
      text(graph, "#{min(cursor + 1, count)} of #{count}",
        font_size: 12,
        fill: {:color, @dim},
        translate: {540, @space_y}
      )
    end
  end

  defp message(graph, %{message: nil}), do: graph

  defp message(graph, %{message: {level, text}}) do
    colour = if level == :error, do: @fail, else: @pass

    text(graph, truncate(text, 70),
      font_size: 14,
      fill: {:color, colour},
      translate: {20, @message_y}
    )
  end

  defp message(graph, _snapshot), do: graph

  defp reason_text(%{message: {_level, text}}), do: text
  defp reason_text(_snapshot), do: "no reason given"

  defp browse_hint(snapshot) do
    case selected_entry(snapshot) do
      %{type: :directory} -> "A opens. B goes up. Y for what can be done here."
      nil -> "B goes up. Y for what can be done here."
      _entry -> "A and Y both show what can be done with this file. B goes up."
    end
  end

  defp selected_entry(%{entries: entries, cursor: cursor}), do: Enum.at(entries, cursor)
  defp selected_entry(_snapshot), do: nil

  defp selected_name(snapshot) do
    case selected_entry(snapshot) do
      nil -> "Actions"
      entry -> truncate(entry.name, 52)
    end
  end

  defp detail(snapshot) do
    case selected_entry(snapshot) do
      nil -> ""
      %{link: link} when is_binary(link) -> "link to #{truncate_left(link, 60)}"
      %{type: :regular, size: size} -> "#{size(size)} in #{truncate_left(snapshot.dir || "", 46)}"
      %{type: type} -> "#{type} in #{truncate_left(snapshot.dir || "", 50)}"
    end
  end

  defp what(%{type: :directory}), do: "A directory. Only an empty one can go."

  defp what(%{link: link}) when is_binary(link),
    do: "A link. Deleting it leaves #{truncate_left(link, 40)} alone."

  defp what(%{type: :regular, size: size}), do: "A file of #{size(size)}."
  defp what(%{type: type}), do: "A #{type}."

  defp path_of(%{dir: dir}, name) when is_binary(dir), do: Path.join(dir, name)
  defp path_of(_snapshot, name), do: name

  # -- the rename grid --------------------------------------------------------

  # One character per cell, and the caret is a box under a cell rather than a
  # bar between two: with a proportional font there is no honest way to draw a
  # bar in the right place, and a caret in the wrong place is worse than none.
  defp cells(graph, chars, caret) do
    count = length(chars)
    # The append slot is a cell too, so a name can be grown at the end.
    start = min(max(0, caret - @cells + 1), max(0, count + 1 - @cells))
    y = 130

    Enum.reduce(0..(@cells - 1), graph, fn column, acc ->
      index = start + column
      x = 24 + column * @cell

      cond do
        index > count ->
          acc

        index == count ->
          acc
          |> caret_box(x, y, index == caret)
          |> text("+", font_size: 18, fill: {:color, @dim}, translate: {x + 3, y + 20})

        true ->
          acc
          |> caret_box(x, y, index == caret)
          |> text(Enum.at(chars, index),
            font_size: 18,
            fill: {:color, @title},
            translate: {x + 3, y + 20}
          )
      end
    end)
  end

  defp caret_box(graph, _x, _y, false), do: graph

  defp caret_box(graph, x, y, true) do
    rect(graph, {@cell, 28}, fill: {:color, @row_bg}, stroke: {1, @head}, translate: {x, y})
  end

  # -- words ------------------------------------------------------------------

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

  # For paths, keep the end: which directory this is matters more than which
  # of the two cards it is on, and the card is on the row above anyway.
  defp truncate_left(text, limit) do
    if String.length(text) > limit do
      "…" <> String.slice(text, String.length(text) - limit + 1, limit)
    else
      text
    end
  end

  defp reason(nil), do: "Start it from the menu."
  defp reason(reason), do: FileManager.why(reason)
end
