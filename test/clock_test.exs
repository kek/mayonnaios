defmodule MayonnaiOS.ClockTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.{Clock, Diagnostics}
  alias MayonnaiOS.Scene.Diagnostics, as: DiagnosticsScene

  test "distinguishes synchronized, never synchronized, and unavailable" do
    assert Clock.status(fn -> true end) == :synchronized
    assert Clock.status(fn -> false end) == :never_synchronized
    assert Clock.status(fn -> :unavailable end) == :unavailable

    assert Clock.synchronized?(fn -> true end)
    refute Clock.synchronized?(fn -> false end)
    refute Clock.synchronized?(fn -> :unavailable end)
  end

  test "diagnostics says whether network time has ever synchronized" do
    synchronized = texts(DiagnosticsScene.graph(%Diagnostics{time_sync: :synchronized}))
    waiting = texts(DiagnosticsScene.graph(%Diagnostics{time_sync: :never_synchronized}))

    assert "synchronized" in synchronized
    assert "never synchronized" in waiting
  end

  defp texts(graph) do
    Scenic.Graph.reduce(graph, [], fn
      %Scenic.Primitive{module: Scenic.Primitive.Text, data: data}, acc -> [data | acc]
      _primitive, acc -> acc
    end)
  end
end
