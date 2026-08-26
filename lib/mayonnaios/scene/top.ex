defmodule MayonnaiOS.Scene.Top do
  @moduledoc """
  What the panel shows while the process readout has the buttons.

  It draws `MayonnaiOS.Top.snapshot/0` and nothing else, told when to redraw
  by `Top.watch/1` -- a refresh every couple of seconds, a scroll when a
  button moved one. The same arrangement as the file manager's scene, for the
  same reason: `set_root/3` terminates a scene on every repaint the launcher
  does, so nothing may be remembered here.

  The table is set in `:roboto_mono` and each row is one padded string.
  Columns of numbers only line up in a monospace face, and one text primitive
  per row is what keeps a screen that redraws every two seconds from being
  eighty primitives deep.
  """

  use Scenic.Scene

  alias MayonnaiOS.Top
  alias MayonnaiOS.Scene.StatusBar
  alias Scenic.Graph

  import Scenic.Primitives

  @width 640
  @height 480

  # Same palette as the other screens, so they read as one device.
  @bg {12, 14, 22}
  @title {235, 238, 245}
  @head {90, 170, 255}
  @label {150, 165, 195}
  @fail {245, 110, 120}
  @dim {110, 125, 155}

  # The strip the shared top bar draws in; nothing is drawn above it.
  @status_bar StatusBar.height()

  @title_y 50
  @stats_y 74
  @rule_y 84
  @columns_y 104
  @top 124
  @pitch 19

  @range_y 434
  @footer_rule 446
  @footer_y 466

  # The table's face and size. 13 px Roboto Mono runs about 7.8 px per glyph,
  # so the 70-character BEAM row ends near x=566 on a 640 px panel.
  @mono :roboto_mono
  @mono_size 13

  @impl Scenic.Scene
  def init(scene, param, _opts) do
    error = if is_map(param), do: Map.get(param, :error), else: nil

    {:ok, scene |> assign(error: error) |> show(watch())}
  end

  @impl GenServer
  def handle_info({:top, snapshot}, scene), do: {:noreply, show(scene, snapshot)}
  def handle_info(_message, scene), do: {:noreply, scene}

  # The app not running is a state to render rather than crash on: it is what
  # the launcher shows when starting failed, and the reason is then the only
  # useful thing on the panel.
  defp watch do
    Top.watch(self())
  rescue
    _error -> :stopped
  catch
    :exit, _reason -> :stopped
  end

  defp show(scene, snapshot), do: push_graph(scene, graph(snapshot, scene.assigns[:error]))

  @doc """
  The height of the strip this scene leaves for the shared top bar, public so
  a test can assert that nothing is drawn above it.
  """
  @spec status_bar() :: pos_integer()
  def status_bar, do: @status_bar

  @doc """
  Build the graph for a snapshot.

  Public because it is the tested surface: no viewport, no driver and no
  framebuffer, so a host test can assert what the panel says for both kinds
  of row, for a machine with no `/proc`, and for the app not running.
  """
  @spec graph(map() | :stopped, term()) :: Scenic.Graph.t()
  def graph(snapshot, error \\ nil)

  def graph(:stopped, error) do
    base("Processes")
    |> text("Not running", font_size: 26, fill: {:color, @fail}, translate: {20, 120})
    |> text(reason(error), font_size: 16, fill: {:color, @label}, translate: {20, 150})
    |> footer("Menu goes back.")
  end

  # A machine whose sample failed -- a host with no /proc is the ordinary way
  # here. The reason is the reading.
  def graph(%{error: reason} = snapshot, _error) when reason != nil do
    base(title(snapshot.kind))
    |> text("No reading", font_size: 26, fill: {:color, @fail}, translate: {20, 120})
    |> text("/proc: #{reason(reason)}",
      font_size: 16,
      fill: {:color, @label},
      translate: {20, 150}
    )
    |> footer("Menu goes back.")
  end

  def graph(snapshot, _error) do
    base(title(snapshot.kind))
    |> stats(snapshot)
    |> rect({@width - 40, 1}, fill: {:color, @head}, translate: {20, @rule_y})
    |> mono(columns(snapshot.kind), @columns_y, @head)
    |> table(snapshot)
    |> range(snapshot)
    |> footer(
      "Up/Down scroll, Left/Right page. Y sorts by #{other_sort(snapshot)}. Menu goes back."
    )
  end

  defp base(heading) do
    Graph.build(font: :roboto, font_size: 14)
    |> rect({@width, @height}, fill: {:color, @bg})
    |> StatusBar.mount()
    |> text(heading, font_size: 20, fill: {:color, @title}, translate: {20, @title_y})
  end

  defp title(:beam), do: "BEAM processes"
  defp title(:os), do: "OS processes"

  # -- the header line ---------------------------------------------------------

  defp stats(graph, %{header: nil}), do: graph

  defp stats(graph, %{kind: :beam, header: h}) do
    m = h.memory

    line =
      "#{h.count} processes   run queue #{h.run_queue}   " <>
        "memory #{bytes(m.total)} — processes #{bytes(m.processes)}, binary #{bytes(m.binary)}"

    text(graph, line, font_size: 13, fill: {:color, @label}, translate: {20, @stats_y})
  end

  defp stats(graph, %{kind: :os, header: h}) do
    m = h.memory

    line =
      "#{h.count} processes   #{h.cpus} cpus   load #{Enum.join(h.load, " ")}   " <>
        "memory #{bytes(m.available)} free of #{bytes(m.total)}"

    text(graph, line, font_size: 13, fill: {:color, @label}, translate: {20, @stats_y})
  end

  # -- the table ---------------------------------------------------------------

  # The activity column is a rate on both screens, and the heading says the
  # unit: reductions since the last refresh for the VM, percent of one core
  # for the OS.
  defp columns(:beam) do
    pad("PID", 12) <>
      pad("PROCESS", 33) <> lpad("MEMORY", 9) <> lpad("MSGQ", 6) <> lpad("REDS", 10)
  end

  defp columns(:os) do
    lpad("PID", 6) <>
      "  " <> pad("COMMAND", 28) <> pad("S", 4) <> lpad("%CPU", 7) <> lpad("RSS", 9)
  end

  defp table(graph, snapshot) do
    snapshot.rows
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {row, index}, g ->
      mono(g, row_line(snapshot.kind, row), @top + index * @pitch, @title)
    end)
  end

  defp row_line(:beam, row) do
    pad(pid_string(row.pid), 12) <>
      pad(shorten(row.name, 32), 33) <>
      lpad(bytes(row.mem), 9) <> lpad(to_string(row.mq), 6) <> lpad(count(row.cpu), 10)
  end

  defp row_line(:os, row) do
    lpad(to_string(row.pid), 6) <>
      "  " <>
      pad(shorten(row.name, 27), 28) <>
      pad(row.state, 4) <> lpad(percent(row.cpu), 7) <> lpad(bytes(row.mem), 9)
  end

  defp mono(graph, line, y, colour) do
    text(graph, line,
      font: @mono,
      font_size: @mono_size,
      fill: {:color, colour},
      translate: {20, y}
    )
  end

  # Where the window sits in the whole list, and which sort produced it --
  # the two facts the table itself cannot show.
  defp range(graph, %{total: 0}), do: graph

  defp range(graph, snapshot) do
    first = snapshot.offset + 1
    last = snapshot.offset + length(snapshot.rows)

    line = "#{first}–#{last} of #{snapshot.total}, by #{sort_name(snapshot)}"
    text(graph, line, font_size: 13, fill: {:color, @dim}, translate: {20, @range_y})
  end

  defp sort_name(%{sort: :mem}), do: "memory"
  defp sort_name(%{kind: :beam}), do: "reductions"
  defp sort_name(%{kind: :os}), do: "cpu"

  defp other_sort(%{sort: :mem} = snapshot), do: sort_name(%{snapshot | sort: :cpu})
  defp other_sort(_snapshot), do: "memory"

  defp footer(graph, words) do
    graph
    |> rect({@width - 40, 1}, fill: {:color, @dim}, translate: {20, @footer_rule})
    |> text(words, font_size: 14, fill: {:color, @label}, translate: {20, @footer_y})
  end

  # -- formatting ----------------------------------------------------------------

  defp pid_string(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()

  # Cut long names keeping the tail: module names differ at the end --
  # MayonnaiOS.Bluetooth.Scanner keeps Scanner, not the prefix every row shares.
  defp shorten(name, max) do
    if String.length(name) <= max do
      name
    else
      "…" <> String.slice(name, -(max - 1), max - 1)
    end
  end

  defp pad(string, width), do: String.pad_trailing(string, width)
  defp lpad(string, width), do: String.pad_leading(string, width) <> " "

  defp bytes(nil), do: "--"
  defp bytes(b) when b >= 10 * 1024 * 1024, do: "#{div(b, 1024 * 1024)}M"
  defp bytes(b) when b >= 1024 * 1024, do: "#{Float.round(b / (1024 * 1024), 1)}M"
  defp bytes(b) when b >= 1024, do: "#{div(b, 1024)}K"
  defp bytes(b), do: "#{b}"

  defp count(nil), do: "--"
  defp count(n) when n >= 10_000_000, do: "#{div(n, 1_000_000)}M"
  defp count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp count(n) when n >= 10_000, do: "#{div(n, 1000)}k"
  defp count(n), do: "#{n}"

  defp percent(nil), do: "--"
  defp percent(f), do: :erlang.float_to_binary(f, decimals: 1)

  defp reason(nil), do: "It was not started."
  defp reason(other), do: inspect(other)
end
