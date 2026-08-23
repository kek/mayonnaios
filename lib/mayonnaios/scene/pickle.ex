defmodule MayonnaiOS.Scene.Pickle do
  @moduledoc """
  The panel, worn by whichever pickle `MayonnaiOS.Pickles.App` says is
  current.

  One scene serves every graphical pickle, because the scene holds no
  opinion about content: it attaches to the pickle's runner, and from then
  on renders the frames the runner pushes -- validated draw ops from the
  script's `on_draw()`, see `MayonnaiOS.Pickles.Frame`. Input goes the other
  way around this scene entirely: launcher -> App -> runner, so a script
  chewing on a button can never wedge the process that owns the graph.

  Unlike the other scenes there is no status bar: like an external program,
  a pickle gets the whole panel. What it does not get is the framebuffer --
  everything passes through Frame's validation and Scenic's renderer, so the
  worst a script can draw is something ugly.

  A pickle that cannot draw stays diagnosable on the panel: the runner sends
  the reason (`no on_draw()`, a Lua error, not running) and it is rendered
  where the frame would have been, with the pickle's name and the way out.
  Same rule as everywhere else on this device: a failure someone can read
  beats a blank screen.
  """

  use Scenic.Scene

  alias MayonnaiOS.Pickles.{App, Runner}
  alias Scenic.Graph

  import Scenic.Primitives

  @width 640
  @height 480

  # The device palette, for the frames this scene draws itself (waiting,
  # errors). The pickle's own frames choose from Frame's named colors.
  @bg {12, 14, 22}
  @title {235, 238, 245}
  @label {150, 165, 195}
  @fail {245, 110, 120}
  @dim {110, 125, 155}

  @impl Scenic.Scene
  def init(scene, param, _opts) do
    error = if is_map(param), do: Map.get(param, :error), else: nil
    name = App.current()

    scene = assign(scene, name: name)

    case {name, error} do
      {nil, _} ->
        {:ok, notice(scene, "no pickle selected", nil)}

      {_name, error} when error != nil ->
        {:ok, notice(scene, "would not start", inspect(error))}

      {name, nil} ->
        attach(name)
        {:ok, notice(scene, "waiting for #{name}...", nil)}
    end
  end

  @impl GenServer
  def handle_info({:pickle_frame, frame}, scene) do
    {:noreply, push_graph(scene, graph(frame))}
  end

  def handle_info({:pickle_frame_error, message}, scene) do
    {:noreply, notice(scene, "cannot draw", message)}
  end

  def handle_info(_message, scene), do: {:noreply, scene}

  # The attach is a message so the scene never waits on a runner mid-exec;
  # the runner answers with the first frame. A pickle that is not running is
  # a notice, not a crash -- the launcher shows this scene either way.
  defp attach(name) do
    case Runner.whereis(name) do
      nil -> send(self(), {:pickle_frame_error, "not running"})
      pid -> send(pid, {:ui_attach, self()})
    end
  end

  # -- drawing -------------------------------------------------------------

  defp graph(%{ops: ops, invalid: invalid}) do
    graph =
      Graph.build(font: :roboto, font_size: 16)
      |> rect({@width, @height}, fill: @bg)

    graph = Enum.reduce(ops, graph, &draw/2)

    if invalid > 0 do
      text(graph, "#{invalid} invalid draw ops",
        translate: {8, @height - 10},
        fill: @fail,
        font_size: 14
      )
    else
      graph
    end
  end

  defp draw({:text, op}, graph) do
    text(graph, op.text, translate: {op.x, op.y}, fill: op.color, font_size: op.size)
  end

  defp draw({:rect, %{fill: true} = op}, graph) do
    rect(graph, {op.w, op.h}, translate: {op.x, op.y}, fill: op.color)
  end

  defp draw({:rect, op}, graph) do
    rect(graph, {op.w, op.h}, translate: {op.x, op.y}, stroke: {1, op.color})
  end

  defp draw({:line, op}, graph) do
    line(graph, {{op.x1, op.y1}, {op.x2, op.y2}}, stroke: {op.width, op.color})
  end

  defp draw({:circle, %{fill: true} = op}, graph) do
    circle(graph, op.r, translate: {op.x, op.y}, fill: op.color)
  end

  defp draw({:circle, op}, graph) do
    circle(graph, op.r, translate: {op.x, op.y}, stroke: {1, op.color})
  end

  defp notice(scene, headline, detail) do
    name = scene.assigns[:name]

    graph =
      Graph.build(font: :roboto, font_size: 16)
      |> rect({@width, @height}, fill: @bg)
      |> text(name || "pickle", translate: {40, 60}, fill: @title, font_size: 24)
      |> text(headline, translate: {40, 100}, fill: @label)
      |> text(detail || "", translate: {40, 128}, fill: @fail)
      |> text("Menu goes back", translate: {40, @height - 28}, fill: @dim)

    push_graph(scene, graph)
  end
end
