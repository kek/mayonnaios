defmodule MayonnaiOS.Scene.Backup do
  @moduledoc "The 640×480 snapshot-only backup screen."

  use Scenic.Scene
  import Scenic.Primitives
  alias MayonnaiOS.Backup.App
  alias MayonnaiOS.Scene.StatusBar
  alias Scenic.Graph

  @status StatusBar.height()
  @bg {12, 14, 22}
  @title {235, 238, 245}
  @label {150, 165, 195}
  @good {110, 220, 150}
  @fail {245, 110, 120}

  @impl Scenic.Scene
  def init(scene, _param, _opts), do: {:ok, push(scene, watch())}
  @impl GenServer
  def handle_info({:backup_app, snapshot}, scene), do: {:noreply, push(scene, snapshot)}
  def handle_info(_, scene), do: {:noreply, scene}

  def graph(:stopped),
    do: base() |> add_text("Backup stopped", 120, @fail) |> footer("Menu goes back.")

  def graph(%{status: :idle}) do
    base()
    |> add_text("Back up user data", 92, @title, 26)
    |> add_text("Includes settings, saves, Moonlight, and Pickles.", 145)
    |> add_text("Excludes games, installed software, WiFi, and Bluetooth.", 175)
    |> add_text("A writes a verified backup to the second card.", 220)
    |> footer("A starts. Menu goes back.")
  end

  def graph(%{status: status} = snapshot) when status in [:preflighting, :copying, :verifying] do
    base()
    |> add_text(phase(status), 110, @title, 24)
    |> add_text(progress(snapshot), 155)
    |> add_text(short(Map.get(snapshot, :path)), 185)
    |> progress_bar(Map.get(snapshot, :bytes, 0), Map.get(snapshot, :total_bytes, 0))
    |> footer("Menu cancels; do not remove the card or power off.")
  end

  def graph(%{status: :done, result: result}) do
    base()
    |> add_text("Backup verified", 110, @good, 26)
    |> add_text("#{result.files} files, #{result.bytes} bytes", 155)
    |> add_text(short(result.destination), 185)
    |> footer("Safe-unmount the second card before removing it.")
  end

  def graph(%{status: :cancelled}),
    do:
      base()
      |> add_text("Backup cancelled", 120, @label, 24)
      |> footer("A tries again. Menu goes back.")

  def graph(%{status: :error, error: reason}) do
    base()
    |> add_text("Backup failed", 110, @fail, 26)
    |> add_text(error(reason), 155)
    |> footer("A tries again. Menu goes back.")
  end

  def graph(_), do: graph(%{status: :idle})

  def status_bar, do: @status

  defp base do
    Graph.build(font: :roboto, font_size: 16)
    |> rect({640, 480}, fill: {:color, @bg})
    |> StatusBar.mount()
  end

  defp add_text(graph, words, y, colour \\ @label, size \\ 16),
    do: text(graph, words || "", font_size: size, fill: {:color, colour}, translate: {20, y})

  defp footer(graph, words),
    do:
      graph
      |> rect({640, 1}, fill: {:color, @label}, translate: {0, 446})
      |> add_text(words, 470, @label, 14)

  defp progress_bar(graph, done, total) do
    width = if is_integer(total) and total > 0, do: min(600, div(600 * done, total)), else: 0

    graph
    |> rect({600, 16}, fill: {:color, {35, 42, 58}}, translate: {20, 220})
    |> rect({width, 16}, fill: {:color, @good}, translate: {20, 220})
  end

  defp phase(:preflighting), do: "Scanning user data…"
  defp phase(:copying), do: "Copying user data…"
  defp phase(:verifying), do: "Verifying backup…"

  defp progress(s),
    do:
      "#{Map.get(s, :files, 0)}/#{Map.get(s, :total_files, 0)} files  #{Map.get(s, :bytes, 0)}/#{Map.get(s, :total_bytes, 0)} bytes"

  defp short(nil), do: ""

  defp short(path),
    do: if(String.length(path) > 68, do: "…" <> String.slice(path, -67, 67), else: path)

  defp error(:destination_absent), do: "Insert and mount the second card."
  defp error(:space_unknown), do: "Cannot measure free space on the second card."
  defp error(:insufficient_space), do: "The second card does not have enough free space."
  defp error(:cancelled), do: "The backup was cancelled."
  defp error(:source_changed), do: "User data changed while it was being copied. Try again."
  defp error({:destination_read_only, _}), do: "The second card is read-only."
  defp error(reason), do: "Unexpected error: #{inspect(reason)}"

  defp watch do
    App.watch(self())
  catch
    :exit, _ -> :stopped
  end

  defp push(scene, snapshot), do: Scenic.Scene.push_graph(scene, graph(snapshot))
end
