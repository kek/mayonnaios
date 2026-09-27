defmodule MayonnaiOS.Files.Worker do
  @moduledoc """

  Temporary supervised executor for recursive Files jobs. Messages sent to the
  owner are tagged `{worker_pid, job_ref}` and ordinary progress is coalesced.
  """

  use GenServer
  alias MayonnaiOS.Files

  @sessions MayonnaiOS.Files.Worker.Sessions
  @throttle 250

  def sessions do
    %{
      id: @sessions,
      start: {DynamicSupervisor, :start_link, [[name: @sessions, strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  def start(job, owner \\ self(), opts \\ []) when is_pid(owner) do
    ref = make_ref()

    case DynamicSupervisor.start_child(@sessions, {__MODULE__, {job, owner, ref, opts}}) do
      {:ok, pid} -> {:ok, pid, ref}
      error -> error
    end
  end

  def cancel(pid, ref), do: send(pid, {:cancel, ref})

  def child_spec(arg),
    do: %{id: make_ref(), start: {__MODULE__, :start_link, [arg]}, restart: :temporary}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl GenServer
  def init({job, owner, ref, opts}) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)
    send(self(), :run)

    {:ok,
     %{
       job: job,
       owner: owner,
       ref: ref,
       opts: opts,
       monitor: monitor,
       cancelled: false,
       last_progress: nil,
       last_at: nil
     }}
  end

  @impl GenServer
  def handle_info(:run, state) do
    send(state.owner, {:files_job, self(), state.ref, %{phase: :scanning}})
    result = run_job(state)
    send(state.owner, {:files_job, self(), state.ref, {:result, result}})
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp run_job(state) do
    pid = self()
    clock = Keyword.get(state.opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    progress = fn update -> maybe_progress(state.owner, state.ref, update, clock) end
    cancelled? = fn -> cancelled?(state.ref, state.monitor, state.owner) end
    opts = state.opts |> Keyword.put(:progress, progress) |> Keyword.put(:cancelled?, cancelled?)

    case state.job do
      {:copy, source, destination} -> Files.copy_tree(source, destination, opts)
      {:move, source, destination} -> Files.move_tree(source, destination, opts)
      {:discard, location} -> Files.discard_incomplete(location, opts)
      other -> {:error, {:unknown_job, other, pid}}
    end
  catch
    kind, reason -> {:error, {:worker_failure, kind, reason}}
  end

  defp cancelled?(ref, monitor, owner) do
    receive do
      {:cancel, ^ref} -> true
      {:DOWN, ^monitor, :process, ^owner, _reason} -> true
    after
      0 -> false
    end
  end

  defp maybe_progress(owner, ref, %{phase: phase} = update, _clock)
       when phase in [:scanning, :cleanup, :cancelling, :verifying] do
    send(owner, {:files_job, self(), ref, update})
  end

  defp maybe_progress(owner, ref, update, clock) do
    key = {__MODULE__, ref, :last_progress}
    now = clock.()
    last = Process.get(key)

    if last == nil or now - last >= @throttle do
      Process.put(key, now)
      send(owner, {:files_job, self(), ref, update})
    end

    :ok
  end
end
