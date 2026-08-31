defmodule MayonnaiOS.Backup.App do
  @moduledoc "Responsive app state machine for the System backup screen."

  use GenServer

  alias MayonnaiOS.Backup

  @sessions MayonnaiOS.Backup.App.Sessions
  @advance :btn_b

  def start(opts \\ []) do
    case DynamicSupervisor.start_child(@sessions, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@sessions, pid)
    end
  end

  def input(events) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:input, events}), else: :ok
  end

  def scene, do: MayonnaiOS.Scene.Backup

  def watch(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:watch, pid}), else: :stopped
  end

  def snapshot do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :snapshot), else: :stopped
  end

  def sessions do
    %{
      id: @sessions,
      start: {DynamicSupervisor, :start_link, [[name: @sessions, strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       status: :idle,
       files: 0,
       bytes: 0,
       total_files: 0,
       total_bytes: 0,
       path: nil,
       result: nil,
       error: nil,
       worker: nil,
       watchers: [],
       run: Keyword.get(opts, :run, &Backup.run/1),
       run_opts: Keyword.get(opts, :run_opts, [])
     }}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, present(state), state}

  def handle_call({:watch, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, present(state), %{state | watchers: Enum.uniq([pid | state.watchers])}}
  end

  @impl GenServer
  def handle_cast({:input, events}, %{status: status} = state)
      when status in [:idle, :done, :cancelled, :error] do
    if Enum.any?(events, &match?({:ev_key, @advance, 1}, &1)),
      do: {:noreply, start_run(state)},
      else: {:noreply, state}
  end

  def handle_cast({:input, _events}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:backup_progress, worker, progress}, %{worker: worker} = state) do
    phase = Map.get(progress, :phase, state.status)

    state = %{
      state
      | status: phase,
        path: Map.get(progress, :path, state.path),
        bytes: state.bytes + Map.get(progress, :bytes, 0)
    }

    {:noreply, notify(state)}
  end

  def handle_info({:backup_done, worker, {:ok, result}}, %{worker: worker} = state) do
    {:noreply,
     notify(%{
       state
       | status: :done,
         result: result,
         files: result.files,
         bytes: result.bytes,
         worker: nil
     })}
  end

  def handle_info({:backup_done, worker, {:error, :cancelled}}, %{worker: worker} = state),
    do: {:noreply, notify(%{state | status: :cancelled, worker: nil})}

  def handle_info({:backup_done, worker, {:error, reason}}, %{worker: worker} = state),
    do: {:noreply, notify(%{state | status: :error, error: reason, worker: nil})}

  def handle_info({:EXIT, worker, reason}, %{worker: worker} = state) when reason != :normal,
    do:
      {:noreply, notify(%{state | status: :error, error: {:worker_crashed, reason}, worker: nil})}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | watchers: List.delete(state.watchers, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{worker: worker}) when is_pid(worker) do
    Process.exit(worker, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_run(state) do
    owner = self()
    run = state.run
    base_opts = state.run_opts

    worker =
      spawn_link(fn ->
        opts =
          Keyword.put(base_opts, :progress, fn progress ->
            send(owner, {:backup_progress, self(), progress})
          end)

        send(owner, {:backup_done, self(), run.(opts)})
      end)

    notify(%{
      state
      | status: :preflighting,
        error: nil,
        result: nil,
        worker: worker,
        files: 0,
        bytes: 0
    })
  end

  defp notify(state) do
    snapshot = present(state)
    Enum.each(state.watchers, &send(&1, {:backup_app, snapshot}))
    state
  end

  defp present(state), do: Map.drop(state, [:watchers, :run, :run_opts])
end
