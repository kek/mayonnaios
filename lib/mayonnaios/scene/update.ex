defmodule MayonnaiOS.Scene.Update do
  @moduledoc """
  What the panel shows while `MayonnaiOS.Update.App` has the buttons.

  Draws `MayonnaiOS.Update.App.snapshot/0` and nothing else, told when to
  redraw by `App.watch/1` -- the same arrangement as `MayonnaiOS.Scene.Top`,
  for the same reason: `set_root/3` terminates this scene on every repaint
  the launcher does, so nothing may be remembered here.
  """

  use Scenic.Scene

  alias MayonnaiOS.Scene.StatusBar
  alias MayonnaiOS.Update.App
  alias Scenic.Graph

  import Scenic.Primitives

  @width 640
  @height 480

  @bg {12, 14, 22}
  @title {235, 238, 245}
  @label {150, 165, 195}
  @good {110, 220, 150}
  @fail {245, 110, 120}
  @dim {110, 125, 155}

  @status_bar StatusBar.height()

  @title_y 50
  @body_y 130
  @detail_y 165
  @bar_y 200
  @bar_width @width - 40
  @bar_height 18

  @footer_rule 446
  @footer_y 466

  @impl Scenic.Scene
  def init(scene, _param, _opts) do
    {:ok, scene |> show(watch())}
  end

  @impl GenServer
  def handle_info({:update_app, snapshot}, scene), do: {:noreply, show(scene, snapshot)}
  def handle_info(_message, scene), do: {:noreply, scene}

  # The app not running is a state to render rather than crash on, matching
  # `MayonnaiOS.Scene.Top`.
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
  framebuffer, so a host test can assert what the panel says for every
  state without a running app.
  """
  @spec graph(map() | :stopped) :: Scenic.Graph.t()
  def graph(:stopped) do
    base()
    |> text("Not running", font_size: 26, fill: {:color, @fail}, translate: {20, @body_y})
    |> footer("Menu goes back.")
  end

  def graph(%{status: :checking}) do
    base()
    |> text("Checking for an update...",
      font_size: 22,
      fill: {:color, @label},
      translate: {20, @body_y}
    )
    |> footer("Menu goes back.")
  end

  def graph(%{status: :up_to_date, result: result}) do
    base()
    |> text("Up to date", font_size: 26, fill: {:color, @good}, translate: {20, @body_y})
    |> text(version_line(result),
      font_size: 16,
      fill: {:color, @label},
      translate: {20, @detail_y}
    )
    |> footer("A checks again. Menu goes back.")
  end

  def graph(%{status: :available, result: %{asset: nil} = result}) do
    base()
    |> text("Update available: #{result.latest}",
      font_size: 22,
      fill: {:color, @title},
      translate: {20, @body_y}
    )
    |> text("No firmware file has been published for this device yet.",
      font_size: 16,
      fill: {:color, @fail},
      translate: {20, @detail_y}
    )
    |> footer("Menu goes back.")
  end

  def graph(%{status: :available, result: result}) do
    base()
    |> text("Update available: #{result.latest}",
      font_size: 22,
      fill: {:color, @title},
      translate: {20, @body_y}
    )
    |> text(version_line(result),
      font_size: 16,
      fill: {:color, @label},
      translate: {20, @detail_y}
    )
    |> footer("A downloads and installs it. Menu goes back.")
  end

  def graph(%{status: :downloading, downloaded: downloaded, total: total}) do
    base()
    |> text("Downloading and installing...",
      font_size: 22,
      fill: {:color, @title},
      translate: {20, @body_y}
    )
    |> progress_bar(downloaded, total)
    |> footer("Menu cancels. The current firmware is untouched either way.")
  end

  def graph(%{status: :done}) do
    base()
    |> text("Installed", font_size: 26, fill: {:color, @good}, translate: {20, @body_y})
    |> text("A restarts into it now.",
      font_size: 16,
      fill: {:color, @label},
      translate: {20, @detail_y}
    )
    |> footer("A reboots. Menu goes back without rebooting.")
  end

  def graph(%{status: :error, error: reason}) do
    base()
    |> text("Update failed", font_size: 26, fill: {:color, @fail}, translate: {20, @body_y})
    |> text(reason(reason), font_size: 15, fill: {:color, @label}, translate: {20, @detail_y})
    |> footer("A tries again. Menu goes back.")
  end

  # :idle, or anything else not drawn above.
  def graph(_snapshot) do
    base()
    |> text("Press A to check for an update.",
      font_size: 20,
      fill: {:color, @label},
      translate: {20, @body_y}
    )
    |> footer("Menu goes back.")
  end

  defp base do
    Graph.build(font: :roboto, font_size: 14)
    |> rect({@width, @height}, fill: {:color, @bg})
    |> StatusBar.mount()
    |> text("Software update", font_size: 20, fill: {:color, @title}, translate: {20, @title_y})
  end

  defp version_line(%{current: current, latest: latest, comparable?: true}),
    do: "Running #{current}, latest is #{latest}."

  defp version_line(%{current: current, tag: tag}),
    do: "Running #{current}; latest release is tagged #{tag} (not a comparable version)."

  defp progress_bar(graph, _downloaded, nil) do
    text(graph, "Size unknown", font_size: 16, fill: {:color, @label}, translate: {20, @bar_y})
  end

  defp progress_bar(graph, downloaded, total) when total > 0 do
    fraction = downloaded |> min(total) |> Kernel./(total)
    fill_width = round(@bar_width * fraction)

    graph
    |> rect({@bar_width, @bar_height}, fill: {:color, @dim}, translate: {20, @bar_y})
    |> rect({max(fill_width, 1), @bar_height}, fill: {:color, @good}, translate: {20, @bar_y})
    |> text("#{bytes(downloaded)} / #{bytes(total)} (#{round(fraction * 100)}%)",
      font_size: 15,
      fill: {:color, @label},
      translate: {20, @bar_y + @bar_height + 20}
    )
  end

  defp progress_bar(graph, downloaded, _total) do
    text(graph, "#{bytes(downloaded)} downloaded",
      font_size: 16,
      fill: {:color, @label},
      translate: {20, @bar_y}
    )
  end

  defp footer(graph, words) do
    graph
    |> rect({@width - 40, 1}, fill: {:color, @dim}, translate: {20, @footer_rule})
    |> text(words, font_size: 14, fill: {:color, @label}, translate: {20, @footer_y})
  end

  defp bytes(nil), do: "--"
  defp bytes(b) when b >= 1024 * 1024, do: "#{Float.round(b / (1024 * 1024), 1)}M"
  defp bytes(b) when b >= 1024, do: "#{div(b, 1024)}K"
  defp bytes(b), do: "#{b}"

  defp reason(:no_releases), do: "This repository has no published releases yet."
  defp reason(:no_asset), do: "The release has no firmware file for this device."

  defp reason({:insufficient_space, needed, path}),
    do: "Not enough free space on #{path} (need #{bytes(needed)})."

  defp reason({:http, _}), do: "Could not reach GitHub. Check the network connection."
  defp reason({:http_status, status}), do: "GitHub returned an unexpected status (#{status})."
  defp reason({:fwup_failed, status, _output}), do: "fwup exited with status #{status}."
  defp reason(:fwup_not_found), do: "fwup is missing from this image."
  defp reason(:no_devpath), do: "The firmware device path is unknown."
  defp reason(other), do: inspect(other)
end
