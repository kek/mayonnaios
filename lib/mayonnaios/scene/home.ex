defmodule MayonnaiOS.Scene.Home do
  @moduledoc """
  The home screen: the column browser, drawn NeXTSTEP-style, three columns.

  ## Where the columns come from

  This scene renders `MayonnaiOS.Browser` and owns none of it.
  `MayonnaiOS.Launcher` owns the gamepad and therefore every cursor, and it
  passes the whole browser in as the scene's start argument. That has to be
  the direction of travel: `Scenic.ViewPort.set_root/3` terminates this
  process and starts a new one on every repaint, so anything this scene
  remembered would be lost the moment a program exited.

  ## What the panel shows

  The breadcrumb line names every open level, so the line still says where
  you are when the parents have scrolled off. Below it, a fixed grid of
  three slots: the focused column in the center -- the only cursor the D-pad
  moves -- its parent on the left (its highlighted row is the one that is
  open, which is how a column browser shows where you came from; at the
  root, where there is no parent, the slot carries the
  `MayonnaiOS.SystemInfo` panel), and on the right the preview of whatever
  the cursor is on:
  the contents of a directory, the head of a file, the metadata of a
  program, a narrow slice of the process readout.

  The actions sheet rides in the preview's slot, because in this UI "a list
  to pick from" and "a column" are the same thing. The full view that X
  opens, the delete confirmation and the rename editor take the whole column
  area instead: one wide column is the full view's point, a question
  deserves the room, and a character grid needs it.

  ## Images

  An image -- a preview thumbnail or the full view -- reaches the driver as
  a streamed texture: the compressed bytes go into `Scenic.Assets.Stream`
  under a fixed id and a rect is filled from it, scaled to fit its box. The
  driver decodes them itself (stb_image in scenic_driver_local), which is
  why no decoder lives in this VM. Staging can fail -- bytes past the view's
  cap, no Scenic running, a file the decoder refuses -- and the box then
  says so instead of drawing nothing.

  ## Why the footer says what the buttons do, on every screen

  Y means a different thing in each state -- the actions sheet while
  browsing, the delete on a confirmation, remove-a-character in the rename
  editor -- and a handheld has no tooltips and no manual. So the bottom line
  spells the buttons out for the state on screen, and the same line carries
  the power-off question and a program's obituary when there is one: the
  panel asking or reporting outranks it labelling.
  """

  use Scenic.Scene

  alias MayonnaiOS.{Browser, Files, Panel, SystemInfo, Theme}
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

  # The font and every colour below come from the current `MayonnaiOS.Theme`
  # rather than being module attributes, because a theme is chosen at
  # runtime (`Theme.set/1`, or the System menu's Theme row) and a module
  # attribute is a compile-time constant -- it could not change without a
  # rebuild. Reading `Theme.current()` here instead means this scene draws
  # in whatever theme is current at the moment it is asked to draw, which is
  # every redraw: nothing here is cached across one.
  defp font, do: Theme.current().font
  defp title_font, do: Theme.current().title_font
  defp bg, do: Theme.current().bg
  defp title, do: Theme.current().title
  defp head, do: Theme.current().head
  defp label, do: Theme.current().label
  defp pass, do: Theme.current().pass
  defp fail, do: Theme.current().fail
  defp wait, do: Theme.current().wait
  defp dim, do: Theme.current().dim
  defp row_bg, do: Theme.current().row_bg

  # The column area: a fixed grid of three slots, captions first, rows below,
  # ten to a column. Fixed rather than sized to how many levels are open, so
  # the layout never jumps as columns open and close. Ten rows of 26 px pitch
  # end well clear of the status line and the footer.
  @top @rule_y + 16
  @caption_y @top + 10
  @rows_top @top + 20
  @pitch 26
  @visible 10

  @left 12
  @span @width - 24
  @gutter 8
  @slots 3
  @slot div(@span - @gutter * (@slots - 1), @slots)

  # One line between the columns and the footer: an operation's message when
  # there is one, otherwise what the selected entry is -- its size, its link
  # target, the free space of the filesystem it sits on.
  @message_y 412

  @footer_rule 430
  @footer_y 452

  # The rename editor draws one character per cell so the caret can sit under
  # exactly one of them. A proportional font gives no way to place a caret
  # honestly; a grid does.
  @cell 15
  @cells 36

  # The full view's table: monospace, because listings and hexdumps are
  # columns of figures, and one line per text primitive. 13 px Roboto Mono
  # runs about 7.8 px per glyph, so 76 characters fill the span.
  @mono :roboto_mono
  @full_pitch 19
  @full_chars 76
  # The info full view draws in the theme's body font, which is wider than
  # @mono: 72 glyphs at 17 px is what fits @span.
  @info_chars 72

  # Where streamed textures go, one fixed id per box. Fixed, so a new image
  # replaces the old one instead of leaking a texture per file browsed.
  @preview_stream "browser_preview"
  @full_stream "browser_full"

  # Uptime and BEAM memory are cheap and useful at menu speed. Filesystem
  # space is slower, particularly on the removable card, so it is collected
  # every tenth refresh rather than on every repaint.
  @refresh_ms 30_000
  @disk_refresh_ticks 10

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

    refresh_ms = max(1, param_value(param, :refresh_ms, @refresh_ms))
    disk_refresh_ticks = max(1, param_value(param, :disk_refresh_ticks, @disk_refresh_ticks))
    disk_reader = param_value(param, :disk_reader, &SystemInfo.disk_lines/0)

    panel_builder =
      param_value(param, :panel_builder, fn disk_lines ->
        SystemInfo.panel(disk_lines: disk_lines)
      end)

    disk_lines = disk_reader.()
    system_panel = panel_builder.(disk_lines)
    schedule_refresh(refresh_ms)

    scene =
      assign(scene,
        browser: browser,
        confirming: confirming,
        obituary: obituary,
        refresh_ms: refresh_ms,
        disk_refresh_ticks: disk_refresh_ticks,
        refresh_tick: 0,
        disk_reader: disk_reader,
        panel_builder: panel_builder,
        disk_lines: disk_lines,
        system_panel: system_panel
      )

    {:ok, Panel.draw(scene, graph(browser, confirming, obituary, system_panel))}
  end

  @impl GenServer
  def handle_info(:refresh_system_panel, scene) do
    schedule_refresh(scene.assigns.refresh_ms)

    if Panel.held?() do
      {:noreply, scene}
    else
      tick = scene.assigns.refresh_tick + 1

      disk_lines =
        if rem(tick, scene.assigns.disk_refresh_ticks) == 0 do
          scene.assigns.disk_reader.()
        else
          scene.assigns.disk_lines
        end

      system_panel = scene.assigns.panel_builder.(disk_lines)

      scene =
        assign(scene, refresh_tick: tick, disk_lines: disk_lines, system_panel: system_panel)

      {:noreply,
       Panel.draw(
         scene,
         graph(
           scene.assigns.browser,
           scene.assigns.confirming,
           scene.assigns.obituary,
           system_panel
         )
       )}
    end
  end

  def handle_info(_message, scene), do: {:noreply, scene}

  defp param_value(%{} = param, key, default), do: Map.get(param, key, default)
  defp param_value(_param, _key, default), do: default

  # Rescheduled by hand so a slow filesystem read cannot accumulate timer
  # messages behind it. The timer belongs to the scene process and disappears
  # when the launcher re-roots the viewport.
  defp schedule_refresh(refresh_ms) do
    Process.send_after(self(), :refresh_system_panel, refresh_ms)
  end

  @doc """
  Build the graph for a browser.

  Public because it is the tested surface: it needs no viewport, no driver
  and no framebuffer, so a host test can assert what the panel says for the
  root column, a deep descent, the actions sheet, the delete confirmation,
  the rename editor, the power-off question and an obituary -- the shapes
  that would otherwise only be found by looking at the device.
  """
  @spec graph(Browser.t(), boolean(), map() | nil, SystemInfo.panel()) :: Scenic.Graph.t()
  def graph(
        browser,
        confirming \\ false,
        obituary \\ nil,
        system_panel \\ SystemInfo.panel()
      ) do
    base()
    |> breadcrumb(browser)
    |> held(browser)
    |> body(browser, system_panel)
    |> status_line(browser)
    |> notice(browser, confirming, obituary)
  end

  defp base do
    Graph.build(font: font(), font_size: 18)
    |> rect({@width, @height}, fill: {:color, bg()})
    |> StatusBar.mount()
    |> rect({@span, 2}, fill: {:color, head()}, translate: {@left, @rule_y})
  end

  # Every open level by name, however many columns are drawn. The tail is
  # kept when it runs long: where you are matters more than where you began,
  # and the root is always one Menu press away.
  defp breadcrumb(graph, browser) do
    trail = (Browser.trail(browser) ++ full_crumb(browser)) |> Enum.join(" > ")

    text(graph, truncate_left(trail, 48),
      font_size: 20,
      fill: {:color, title()},
      translate: {@left, @title_y}
    )
  end

  # The full view is one deeper than the deepest column, and the line should
  # say so: it is the current place the way every level above it is.
  defp full_crumb(%{full: %{title: title}}), do: [title]
  defp full_crumb(_browser), do: []

  # What is on the clipboard, top right, because a held file that is not
  # shown is a file someone pastes into the wrong place a minute later.
  defp held(graph, %{clipboard: nil}), do: graph

  defp held(graph, %{clipboard: %{mode: mode, name: name}}) do
    text(graph, "holding: #{truncate(name, 24)} (#{mode})",
      font_size: 14,
      fill: {:color, wait()},
      translate: {400, @title_y}
    )
  end

  # -- the column area ----------------------------------------------------------

  defp body(graph, %{overlay: {:confirm, pending}}, _system_panel),
    do: confirm_view(graph, pending)

  defp body(graph, %{overlay: {:rename, rename}}, _system_panel), do: rename_view(graph, rename)

  defp body(graph, %{full: full}, _system_panel) when full != nil, do: full_view(graph, full)

  # The actions sheet rides in the preview's slot, titled by the entry it is
  # about, so opening it reads as descending into the question.
  defp body(graph, %{overlay: {:actions, actions, cursor}} = browser, _system_panel) do
    sheet = %{
      title: truncate(selected_name(browser), 18),
      entries: Enum.map(actions, &%{kind: :action, name: &1.label}),
      cursor: cursor,
      note: nil
    }

    panes = Browser.panes(browser)

    graph
    |> separators()
    |> slot(panes.left, 0, false)
    |> slot(panes.center, 1, false)
    |> slot(sheet, 2, true)
  end

  # The main shape: parent, focus, preview. At the root there is no parent,
  # and the left slot carries the system panel instead of sitting empty.
  defp body(graph, browser, system_panel) do
    panes = Browser.panes(browser)

    graph
    |> separators()
    |> left_slot(panes.left, system_panel)
    |> slot(panes.center, 1, true)
    |> preview_pane(Browser.preview(browser))
  end

  # The system panel is the same `%{kind: :info, ...}` shape the preview's
  # info panes carry, so the one line renderer draws both.
  defp left_slot(graph, nil, system_panel), do: info_pane(graph, system_panel, slot_x(0))
  defp left_slot(graph, level, _system_panel), do: slot(graph, level, 0, false)

  defp slot(graph, nil, _index, _focused?), do: graph
  defp slot(graph, level, index, focused?), do: column(graph, level, slot_x(index), focused?)

  defp slot_x(index), do: @left + index * (@slot + @gutter)

  # The grid is fixed at three slots, so the hairlines are too: they say the
  # empty slots are empty, not absent.
  defp separators(graph) do
    Enum.reduce(1..(@slots - 1), graph, fn slot, acc ->
      x = @left + slot * (@slot + @gutter) - div(@gutter, 2) - 1

      rect(acc, {1, @rows_top + @visible * @pitch - @top},
        fill: {:color, row_bg()},
        translate: {x, @top}
      )
    end)
  end

  defp column(graph, level, x, focused?) do
    graph
    |> caption(level, x, focused?)
    |> rows(level, x, focused?)
  end

  # The column's name, and -- for the focused column when the listing is
  # windowed -- where the cursor is in it, as a count rather than a scrollbar.
  defp caption(graph, level, x, focused?) do
    count = length(level.entries)

    position =
      if focused? and count > @visible, do: "  #{level.cursor + 1} of #{count}", else: ""

    text(graph, truncate(level.title, name_chars()) <> position,
      font_size: 14,
      fill: {:color, dim()},
      translate: {x, @caption_y}
    )
  end

  # An empty column says why it is empty -- "Empty.", "No pickles installed.",
  # or what went wrong reading it -- where its rows would have been.
  defp rows(graph, %{entries: [], note: note}, x, _focused?) do
    text(graph, truncate(note || "Empty.", name_chars() + 6),
      font_size: 15,
      fill: {:color, dim()},
      translate: {x, @rows_top + 16}
    )
  end

  defp rows(graph, %{entries: entries, cursor: cursor}, x, focused?) do
    window = window(entries, cursor, @visible)

    {graph, _y} =
      Enum.reduce(window.rows, {graph, @rows_top}, fn {node, index}, {acc, y} ->
        {row(acc, node, x, y, index == window.cursor, focused?), y + @pitch}
      end)

    graph
  end

  defp row(graph, node, x, y, selected?, focused?) do
    graph
    |> highlight(x, y, selected?, focused?)
    |> text(truncate(node.name, name_chars()),
      font_size: 18,
      fill: {:color, name_colour(node, selected? and focused?)},
      translate: {x + 12, y + 17}
    )
    |> chevron(node, x, y)
  end

  # One filled rect for the open row in any column; the accent bar only in
  # the focused one, so a glance says which column the D-pad is moving.
  defp highlight(graph, _x, _y, false, _focused?), do: graph

  defp highlight(graph, x, y, true, focused?) do
    graph = rect(graph, {@slot, @pitch - 4}, fill: {:color, row_bg()}, translate: {x, y})

    if focused? do
      rect(graph, {4, @pitch - 4}, fill: {:color, head()}, translate: {x, y})
    else
      graph
    end
  end

  # A chevron on anything that opens as another column. What a leaf *is* --
  # its size, its link, a binary the image does not have -- goes on the
  # status line below: at this column width the names need the room.
  defp chevron(graph, node, x, y) do
    if Browser.expandable?(node) do
      text(graph, ">", font_size: 16, fill: {:color, dim()}, translate: {x + @slot - 12, y + 17})
    else
      graph
    end
  end

  defp name_colour(%{kind: :file, entry: %{broken?: true}}, _selected?), do: wait()
  defp name_colour(_node, true), do: title()
  defp name_colour(%{kind: :program, program: %{installed?: false}}, _selected?), do: dim()
  defp name_colour(%{kind: kind}, false) when kind in [:category, :place, :dir], do: head()
  defp name_colour(_node, false), do: label()

  # How many characters fit a slot with the highlight inset on the left and
  # the chevron on the right. The larger Pixel Operator HB face needs a little
  # more room for wide capitals than the regular face.
  defp name_chars, do: 15

  # Window the rows when a listing outgrows its column, keeping the cursor on
  # screen. Without this the hundredth ROM in a directory would be selected
  # somewhere nobody can see, and nothing would look wrong.
  defp window(items, cursor, visible) do
    count = length(items)
    cursor = if count == 0, do: 0, else: min(max(cursor, 0), count - 1)
    start = min(max(0, cursor - visible + 1), max(0, count - visible))

    %{rows: items |> Enum.slice(start, visible) |> Enum.with_index(start), cursor: cursor}
  end

  # -- the preview pane -------------------------------------------------------------

  # The third slot: not a column with a cursor but a statement about the
  # selected entry -- what it contains, what it is, what the buttons do to
  # it. `nil` -- an empty column -- draws nothing, which is the honest pane
  # for no selection.
  defp preview_pane(graph, nil), do: graph

  # An expandable entry previews as the column it would open: same rows,
  # no cursor, because the cursor is still one A press away.
  defp preview_pane(graph, %{kind: :level, level: level}) do
    x = slot_x(2)

    graph
    |> preview_caption(level.title, x)
    |> preview_listing(level, x)
  end

  defp preview_pane(graph, %{kind: :file, title: title, info: info, body: body}) do
    x = slot_x(2)

    graph
    |> preview_caption(title, x)
    |> preview_lines(info, x, @rows_top, label())
    |> preview_body(body, x, @rows_top + length(info) * 18 + 8)
  end

  defp preview_pane(graph, %{kind: :info} = pane), do: info_pane(graph, pane, slot_x(2))

  defp preview_pane(graph, %{kind: :top, title: title, lines: lines}) do
    x = slot_x(2)

    graph
    |> preview_caption(title, x)
    |> mono_lines(lines, x, @rows_top, 12)
  end

  # A generic line panel in any slot: a caption, then dim-labelled lines.
  # The preview's info panes and the root's system panel are both this.
  defp info_pane(graph, %{title: title, lines: lines}, x) do
    graph
    |> preview_caption(title, x)
    |> preview_lines(lines, x, @rows_top, label())
  end

  defp preview_caption(graph, words, x) do
    text(graph, truncate(words, name_chars()),
      font_size: 14,
      fill: {:color, dim()},
      translate: {x, @caption_y}
    )
  end

  defp preview_listing(graph, %{entries: [], note: note}, x) do
    text(graph, truncate(note || "Empty.", name_chars() + 6),
      font_size: 15,
      fill: {:color, dim()},
      translate: {x, @rows_top + 16}
    )
  end

  defp preview_listing(graph, %{entries: entries}, x) do
    shown = Enum.take(entries, @visible - 1)

    {graph, y} =
      Enum.reduce(shown, {graph, @rows_top}, fn node, {acc, y} ->
        acc =
          text(acc, truncate(node.name, name_chars()),
            font_size: 16,
            fill: {:color, name_colour(node, false)},
            translate: {x + 4, y + 16}
          )

        {acc, y + 22}
      end)

    case length(entries) - length(shown) do
      0 ->
        graph

      more ->
        text(graph, "… and #{more} more",
          font_size: 14,
          fill: {:color, dim()},
          translate: {x + 4, y + 14}
        )
    end
  end

  defp preview_lines(graph, lines, x, top, colour) do
    {graph, _y} =
      Enum.reduce(lines, {graph, top}, fn line, {acc, y} ->
        acc =
          text(acc, truncate(line, 26),
            font_size: 15,
            fill: {:color, colour},
            translate: {x, y + 14}
          )

        {acc, y + 18}
      end)

    graph
  end

  defp mono_lines(graph, lines, x, top, size) do
    {graph, _y} =
      Enum.reduce(lines, {graph, top}, fn line, {acc, y} ->
        acc =
          text(acc, line,
            font: @mono,
            font_size: size,
            fill: {:color, title()},
            translate: {x, y + 14}
          )

        {acc, y + size + 4}
      end)

    graph
  end

  defp preview_body(graph, nil, _x, _y), do: graph

  defp preview_body(graph, {:note, words}, x, y) do
    text(graph, truncate(words, 26), font_size: 15, fill: {:color, dim()}, translate: {x, y + 14})
  end

  defp preview_body(graph, {:text, lines}, x, y) do
    mono_lines(graph, Enum.map(lines, &truncate(&1, 27)), x, y, 12)
  end

  defp preview_body(graph, {:hex, lines}, x, y) do
    mono_lines(graph, lines, x, y, 12)
  end

  defp preview_body(graph, {:image, image}, x, y) do
    bottom = @rows_top + @visible * @pitch
    image_box(graph, @preview_stream, image, {x, y + 6, @slot - 8, bottom - y - 12})
  end

  # -- the full view ------------------------------------------------------------------

  # One wide column: what X opened. The heading carries the name and, on the
  # right, where the window sits in the whole -- the two facts the lines
  # themselves cannot show.
  defp full_view(graph, %{kind: :image, title: title, image: image} = full) do
    facts =
      Enum.join(
        ["#{image.width} x #{image.height}", image.format] ++ List.wrap(full.note),
        "  "
      )

    graph
    |> full_heading(title, facts)
    |> image_box(@full_stream, image, {@left, @rows_top, @span, @message_y - @rows_top - 10})
  end

  defp full_view(graph, %{kind: :info, title: title, lines: lines}) do
    graph = full_heading(graph, title, "")

    {graph, _y} =
      Enum.reduce(lines, {graph, @rows_top}, fn line, {acc, y} ->
        acc =
          text(acc, truncate(line, @info_chars),
            font_size: 17,
            fill: {:color, label()},
            translate: {@left, y + 14}
          )

        {acc, y + 22}
      end)

    graph
  end

  defp full_view(graph, %{kind: kind, lines: lines} = full)
       when kind in [:listing, :text, :hex] do
    window = Enum.slice(lines, full.offset, Browser.full_rows())

    {graph, _y} =
      Enum.reduce(window, {graph, @rows_top}, fn line, {acc, y} ->
        acc =
          text(acc, truncate(line, @full_chars),
            font: @mono,
            font_size: 13,
            fill: {:color, title()},
            translate: {@left, y + 14}
          )

        {acc, y + @full_pitch}
      end)

    full_heading(graph, full.title, range_words(full))
  end

  defp full_heading(graph, title, words) do
    graph
    |> text(truncate(title, 42),
      font_size: 18,
      fill: {:color, title()},
      translate: {@left, @caption_y + 2}
    )
    |> text(truncate(words, 34),
      font_size: 14,
      fill: {:color, dim()},
      translate: {@left + 372, @caption_y + 2}
    )
  end

  # Where the window sits, what the cap kept out, and -- for an empty
  # listing -- why there are no lines at all.
  defp range_words(%{lines: [], note: note}), do: note || "Empty."

  defp range_words(%{kind: kind, lines: lines, offset: offset} = full) do
    total = length(lines)
    window = Browser.full_rows()

    range =
      if total > window do
        "#{offset + 1}–#{min(offset + window, total)} of #{total} #{unit(kind)}"
      else
        "#{total} #{unit(kind)}"
      end

    case full.note do
      nil -> range
      note -> "#{note}  --  #{range}"
    end
  end

  defp unit(:listing), do: "entries"
  defp unit(_kind), do: "lines"

  # -- streamed images ------------------------------------------------------------

  # The picture, scaled to fit its box and centered in it. The texture is
  # staged first, because a rect filled from a stream nobody fed is a blank
  # hole shaped like a bug; when staging fails, the box says so.
  defp image_box(graph, id, %{bytes: bytes, width: w, height: h}, {x, y, box_w, box_h}) do
    case stage_image(id, bytes) do
      :ok ->
        scale = min(box_w / w, box_h / h)

        rect(graph, {w, h},
          fill: {:stream, id},
          scale: scale,
          pin: {0, 0},
          translate: {x + (box_w - w * scale) / 2, y + (box_h - h * scale) / 2}
        )

      :error ->
        text(graph, "cannot be shown here",
          font_size: 15,
          fill: {:color, dim()},
          translate: {x, y + 16}
        )
    end
  end

  defp stage_image(_id, nil), do: :error

  defp stage_image(id, bytes) do
    case Scenic.Assets.Stream.Image.from_binary(bytes) do
      {:ok, image} -> put_stream(id, image)
      {:error, _reason} -> :error
    end
  end

  # Stream.put talks to Scenic's asset table, which is only there while
  # Scenic runs -- and these graphs are also built by host tests with no
  # viewport at all. :error then, and the box explains itself.
  defp put_stream(id, image) do
    case Scenic.Assets.Stream.put(id, image) do
      :ok -> :ok
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  # -- the delete confirmation ----------------------------------------------------

  defp confirm_view(graph, %{location: location, entry: entry, name: name}) do
    graph
    |> text("Delete this?",
      font: title_font(),
      font_size: 26,
      fill: {:color, fail()},
      translate: {@left, @top + 24}
    )
    # The tail of the path, not the head: which directory and which file is
    # about to go is the part being confirmed, and "/root/mnt/games/ROMS/…"
    # would be the half that is the same for everything.
    |> text(truncate_left(path_of(location, name), 60),
      font_size: 18,
      fill: {:color, title()},
      translate: {@left, @top + 58}
    )
    |> text(what(entry), font_size: 16, fill: {:color, label()}, translate: {@left, @top + 82})
    |> text("There is no undo, and no trash to fish it out of.",
      font_size: 16,
      fill: {:color, wait()},
      translate: {@left, @top + 126}
    )
    |> text("This device is switched off by pulling its power.",
      font_size: 16,
      fill: {:color, dim()},
      translate: {@left, @top + 148}
    )
    |> text("Y deletes it.",
      font: title_font(),
      font_size: 20,
      fill: {:color, fail()},
      translate: {@left, @top + 196}
    )
    |> text("A, B or any direction cancels -- on purpose: the button that",
      font_size: 16,
      fill: {:color, label()},
      translate: {@left, @top + 224}
    )
    |> text("got you here is not the button that does it.",
      font_size: 16,
      fill: {:color, label()},
      translate: {@left, @top + 244}
    )
  end

  defp what(%{type: :directory}), do: "A directory. Only an empty one can go."

  defp what(%{link: link}) when is_binary(link),
    do: "A link. Deleting it leaves #{truncate_left(link, 40)} alone."

  defp what(%{type: :regular, size: size}), do: "A file of #{size(size)}."
  defp what(%{type: type}), do: "A #{type}."

  defp path_of(location, name) do
    case Files.resolve(location) do
      {:ok, path} -> path
      {:error, _reason} -> name
    end
  end

  # -- the rename editor -----------------------------------------------------------

  defp rename_view(graph, %{name: name, chars: chars, caret: caret}) do
    graph
    |> text(truncate(name, 60),
      font_size: 16,
      fill: {:color, dim()},
      translate: {@left, @top + 16}
    )
    |> cells(chars, caret)
    |> text("Left and right move. Up and down change the character.",
      font_size: 16,
      fill: {:color, label()},
      translate: {@left, @top + 136}
    )
    |> text("Y removes it. A saves the name. B cancels.",
      font_size: 16,
      fill: {:color, label()},
      translate: {@left, @top + 158}
    )
  end

  # One character per cell, and the caret is a box under a cell rather than a
  # bar between two: with a proportional font there is no honest way to draw a
  # bar in the right place, and a caret in the wrong place is worse than none.
  defp cells(graph, chars, caret) do
    count = length(chars)
    # The append slot is a cell too, so a name can be grown at the end.
    start = min(max(0, caret - @cells + 1), max(0, count + 1 - @cells))
    y = @top + 46

    Enum.reduce(0..(@cells - 1), graph, fn column, acc ->
      index = start + column
      x = @left + 4 + column * @cell

      cond do
        index > count ->
          acc

        index == count ->
          acc
          |> caret_box(x, y, index == caret)
          |> text("+", font_size: 20, fill: {:color, dim()}, translate: {x + 3, y + 20})

        true ->
          acc
          |> caret_box(x, y, index == caret)
          |> text(Enum.at(chars, index),
            font_size: 20,
            fill: {:color, title()},
            translate: {x + 3, y + 20}
          )
      end
    end)
  end

  defp caret_box(graph, _x, _y, false), do: graph

  defp caret_box(graph, x, y, true) do
    rect(graph, {@cell, 28}, fill: {:color, row_bg()}, stroke: {1, head()}, translate: {x, y})
  end

  # -- the status line -------------------------------------------------------------

  # An operation's message when there is one -- green for done, red for why
  # not -- otherwise what the selected entry is and how much room the column's
  # filesystem has left, which is the number someone about to paste needs.
  defp status_line(graph, %{message: {level, words}}) do
    colour = if level == :error, do: fail(), else: pass()

    text(graph, truncate(words, 78),
      font_size: 16,
      fill: {:color, colour},
      translate: {@left, @message_y}
    )
  end

  defp status_line(graph, browser) do
    words =
      [selection_words(Browser.selected(browser)), space_words(Browser.focused(browser))]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("  --  ")

    text(graph, truncate(words, 78),
      font_size: 15,
      fill: {:color, dim()},
      translate: {@left, @message_y}
    )
  end

  defp selection_words(nil), do: ""
  defp selection_words(%{kind: :place, note: note}), do: note

  defp selection_words(%{kind: :program, program: %{installed?: false}}), do: "not installed"

  defp selection_words(%{kind: :file, entry: %{broken?: true, link: link}}),
    do: "broken link to #{truncate_left(link || "?", 40)}"

  defp selection_words(%{kind: :file, entry: %{link: link}}) when is_binary(link),
    do: "link to #{truncate_left(link, 44)}"

  defp selection_words(%{kind: :file, entry: %{type: :regular, size: bytes}}), do: size(bytes)
  defp selection_words(%{kind: :file, entry: %{type: type}}), do: to_string(type)
  defp selection_words(_node), do: ""

  # Free space for the filesystem this column is on, not for the device: the
  # roots span more than one, and `/` is a full read-only squashfs that is
  # not reachable from here at all.
  defp space_words(%{space: %{device: device, free: free, total: total}}) do
    "#{device}: #{size(free)} free of #{size(total)}"
  end

  defp space_words(_level), do: ""

  defp selected_name(browser) do
    case Browser.selected(browser) do
      nil -> "Actions"
      node -> node.name
    end
  end

  # -- the bottom line -------------------------------------------------------------

  # One notice at a time, on the footer line. The power-off question wins
  # over an obituary: it is the panel asking for a decision, and the obituary
  # keeps -- it is still in the Launcher's state, and comes back the moment
  # the question is answered. With nothing to ask or report, the line labels
  # the buttons for the state on screen.
  defp notice(graph, _browser, true, _obituary) do
    graph
    |> footer_rule()
    |> text("Power off? Y switches off. Any other button keeps it on.",
      font_size: 18,
      fill: {:color, wait()},
      translate: {@left, @footer_y}
    )
  end

  defp notice(graph, browser, false, nil) do
    graph
    |> footer_rule()
    |> text(hint(browser), font_size: 15, fill: {:color, dim()}, translate: {@left, @footer_y})
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
        font_size: 15,
        fill: {:color, dim()},
        translate: {@left, @footer_rule - 8 - up * 18}
      )
    end)
    |> text(headline, font_size: 18, fill: {:color, wait()}, translate: {@left, @footer_y})
  end

  defp hint(%{full: full}) when full != nil,
    do: "B goes back. Up/Down scroll, L1/R1 page. X also closes."

  defp hint(%{overlay: {:actions, _actions, _cursor}}), do: "A does it. B goes back."
  defp hint(%{overlay: {:confirm, _pending}}), do: "Y deletes. Anything else cancels."
  defp hint(%{overlay: {:rename, _rename}}), do: "A saves. B cancels. Y removes a character."

  defp hint(browser) do
    if Browser.focused(browser).location == nil do
      "A opens. B closes a column. X inspects. L1/R1 page. Menu goes to the top."
    else
      "A opens. B closes. X inspects. Y for file actions. Menu goes to the top."
    end
  end

  defp footer_rule(graph) do
    rect(graph, {@span, 1}, fill: {:color, dim()}, translate: {@left, @footer_rule})
  end

  # -- words -----------------------------------------------------------------------

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

  # For paths and the breadcrumb, keep the end: where you are matters more
  # than where you began.
  defp truncate_left(text, limit) do
    if String.length(text) > limit do
      "…" <> String.slice(text, String.length(text) - limit + 1, limit)
    else
      text
    end
  end
end
