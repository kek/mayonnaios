defmodule MayonnaiOS.Backup.AppTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Backup.App
  alias MayonnaiOS.Scene.Backup

  setup do
    App.stop()
    on_exit(&App.stop/0)
    :ok
  end

  test "A starts exactly one responsive worker and reports progress and success" do
    run = fn opts ->
      opts[:progress].(%{phase: :copying, path: "retroarch/save.srm", bytes: 7})
      {:ok, %{destination: "/card/MayonnaiOS/backup-v1/current", files: 1, bytes: 7}}
    end

    assert {:ok, pid} = App.start(run: run)
    assert {:ok, ^pid} = App.start(run: run)
    assert %{status: :idle} = App.watch(self())
    App.input([{:ev_key, :btn_b, 1}])
    assert_receive {:backup_app, %{status: :preflighting}}
    assert_receive {:backup_app, %{status: :copying}}, 500
    assert_receive {:backup_app, %{status: :done, result: %{files: 1}}}, 500
    assert %{status: :done} = App.snapshot()
  end

  test "structured failures become retryable error snapshots" do
    assert {:ok, _} = App.start(run: fn _ -> {:error, :space_unknown} end)
    assert %{status: :idle} = App.watch(self())
    App.input([{:ev_key, :btn_b, 1}])
    assert_receive {:backup_app, %{status: :error, error: :space_unknown}}, 500
    assert %Scenic.Graph{} = Backup.graph(App.snapshot())
  end

  test "all scene states build without a viewport" do
    for snapshot <- [
          :stopped,
          %{status: :idle},
          %{status: :preflighting, files: 0, total_files: 0, bytes: 0, total_bytes: 0, path: nil},
          %{status: :copying, files: 1, total_files: 2, bytes: 3, total_bytes: 10, path: "save"},
          %{status: :verifying, files: 2, total_files: 2, bytes: 10, total_bytes: 10, path: nil},
          %{status: :done, result: %{files: 2, bytes: 10, destination: "/card/current"}},
          %{status: :cancelled},
          %{status: :error, error: :insufficient_space},
          %{status: :error, error: {:unknown, :reason}}
        ] do
      assert %Scenic.Graph{} = Backup.graph(snapshot)
    end
  end
end
