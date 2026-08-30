defmodule MayonnaiOS.Update.App do
  @moduledoc """
  The System menu's "Software update" row: checks GitHub for a newer
  release the moment it is opened, and drives `MayonnaiOS.Update` through
  download, apply and reboot on the confirm button.

  An app rather than a program, on the same terms as `MayonnaiOS.Top`: a
  module in this firmware, started in this VM, with a scene of its own and
  no external process handed the screen. Unlike Top it needs no hardware at
  all, so nothing stops two changes at once the way the Bluetooth apps stop
  each other -- there is simply one process, because there is one screen.

  ## The state machine

      :idle        not checked yet, or the user asked to check again
      :checking    the GitHub request is in flight
      :up_to_date  checked; nothing newer
      :available   checked; a newer release exists, with a firmware asset
      :downloading fetching the asset to a tmpfs path, `:downloaded`/`:total`
                   updated a couple of times a second by polling the file's
                   size -- no callback from `:httpc`'s streamed download, but
                   a stat cheap enough to run twice a second
      :done        `fwup` accepted it; a reboot is what makes it count
      :error       whatever went wrong, at whichever step

  A on `:idle`/`:up_to_date`/`:error` (re)checks. A on `:available` starts
  the download-and-apply. A on `:done` reboots. Every other state ignores A,
  and Menu is the launcher's own -- neither this module nor its scene has to
  do anything with it beyond dropping it, matching `MayonnaiOS.Top`.

  ## Download and apply run off this process, deliberately

  Both are seconds-long I/O and neither belongs on a GenServer that also has
  to answer `snapshot/0` for a redrawing scene. `spawn_monitor/1` rather than
  `Task.async/1`: a `Task` links the caller, and a transfer that raised would
  take this process down mid-update with nothing on the panel to say why.
  The worker function catches everything of its own and always sends a
  result; the monitor is a backstop for what should therefore never happen.

  ## Leaving mid-update

  Pressing Menu stops this app like any other, which kills this process and
  the download-or-apply worker with it. That is safe for the reason
  `MayonnaiOS.Update`'s moduledoc gives: `fwup upgrade` only ever writes the
  slot that is not running, so an interrupted apply leaves a half-written
  inactive partition and nothing else -- reopening this screen and trying
  again overwrites it. Nothing is lost but the time spent.
  """

  use GenServer

  alias MayonnaiOS.{Clock, Update}

  @sessions MayonnaiOS.Update.App.Sessions

  # Physical A and Menu, in the launcher's own vocabulary -- see
  # MayonnaiOS.Launcher's moduledoc for why the atom named "b" is the button
  # printed "A" on this board's shell.
  @advance :btn_b
  @menu :btn_mode

  @default_tmp_path "/tmp/mayonnaios_update.fw"
  @poll_ms 500

  # -- the app protocol the Launcher uses --------------------------------------

  @doc """
  Start the app. Idempotent: pressing the menu row again while it is already
  running shows the same process rather than starting a second one.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    case DynamicSupervisor.start_child(@sessions, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop the app."
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@sessions, pid)
    end
  end

  @doc """
  Forward an evdev report from the Launcher.

  A cast, for the same reason `MayonnaiOS.Top.input/1` is: nothing here may
  make a button press wait on this process.
  """
  @spec input([tuple()]) :: :ok
  def input(events) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:input, events}), else: :ok
  end

  @doc "The scene the launcher shows while this app has the buttons."
  @spec scene() :: module()
  def scene, do: MayonnaiOS.Scene.Update

  @doc """
  Be told when the state changes, as `{:update_app, snapshot}`.

  Same arrangement as `MayonnaiOS.Top.watch/1`: the scene calls this instead
  of polling, and the watcher is monitored so a scene torn down by
  `set_root/3` drops itself.
  """
  @spec watch(pid()) :: map() | :stopped
  def watch(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:watch, pid}), else: :stopped
  end

  @doc "Everything the panel needs, as one map. `:stopped` if the app is not running."
  @spec snapshot() :: map() | :stopped
  def snapshot do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :snapshot), else: :stopped
  end

  @doc "The DynamicSupervisor the app runs under, for the application tree."
  @spec sessions() :: Supervisor.child_spec()
  def sessions do
    %{
      id: @sessions,
      start: {DynamicSupervisor, :start_link, [[name: @sessions, strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Temporary, like the other app sessions: whatever went wrong is in the
      # log, and a restart would land on a screen the user already left.
      restart: :temporary
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -- state --------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      status: :idle,
      result: nil,
      error: nil,
      downloaded: 0,
      total: nil,
      worker: nil,
      tmp_path: Keyword.get(opts, :tmp_path, @default_tmp_path),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      check_opts: Keyword.get(opts, :check_opts, []),
      download_opts: Keyword.get(opts, :download_opts, []),
      apply_opts: Keyword.get(opts, :apply_opts, []),
      time_synchronized?: Keyword.get(opts, :time_synchronized?, &Clock.synchronized?/0),
      # Injectable for the tests, the same way `MayonnaiOS.Launcher`'s
      # `:poweroff` is: the real thing is `no_return()` and cannot run on a
      # laptop, or in a test, without ending the process running it.
      reboot: Keyword.get(opts, :reboot, &Nerves.Runtime.reboot/0),
      watchers: []
    }

    {:ok, run_check(state)}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  def handle_call({:watch, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, snapshot_of(state), %{state | watchers: [pid | state.watchers]}}
  end

  @impl GenServer
  def handle_cast({:input, events}, state) do
    {:noreply, state |> apply_events(events) |> notify(state)}
  end

  @impl GenServer
  def handle_info({:update_check_done, result}, state) do
    state = apply_check_result(result, state)
    {:noreply, notify(state, nil)}
  end

  def handle_info({:update_transfer_done, result}, state) do
    state = apply_transfer_result(result, state)
    {:noreply, notify(state, nil)}
  end

  def handle_info(:poll_progress, %{status: :downloading} = state) do
    state = %{state | downloaded: file_size(state.tmp_path)}
    schedule_progress(state)
    {:noreply, notify(state, nil)}
  end

  # Arrives once more after the transfer has already finished; downloading
  # is over by then, and there is nothing left to poll for.
  def handle_info(:poll_progress, state), do: {:noreply, state}

  # The worker died without sending a result at all -- not the outcome its
  # own rescue clause is supposed to guarantee, so this is a bug rather than
  # a reported failure. Still becomes a visible error instead of a screen
  # that says "downloading..." forever.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker: {worker_pid, ref}} = state)
      when is_pid(worker_pid) do
    state = %{state | status: :error, error: {:worker_crashed, reason}, worker: nil}
    {:noreply, notify(state, nil)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | watchers: List.delete(state.watchers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- transitions ----------------------------------------------------------

  defp run_check(state) do
    parent = self()
    check_opts = state.check_opts

    {pid, ref} =
      spawn_monitor(fn -> send(parent, {:update_check_done, Update.check(check_opts)}) end)

    %{state | status: :checking, error: nil, worker: {pid, ref}}
  end

  defp apply_check_result({:ok, %{available?: true} = result}, state),
    do: %{state | status: :available, result: result, error: nil, worker: nil}

  defp apply_check_result({:ok, result}, state),
    do: %{state | status: :up_to_date, result: result, error: nil, worker: nil}

  defp apply_check_result({:error, reason}, state),
    do: %{state | status: :error, result: nil, error: diagnose(reason, state), worker: nil}

  defp start_transfer(%{result: %{asset: nil}} = state) do
    %{state | status: :error, error: :no_asset}
  end

  defp start_transfer(state) do
    parent = self()
    asset = state.result.asset
    tmp_path = state.tmp_path
    download_opts = state.download_opts
    apply_opts = state.apply_opts

    {pid, ref} =
      spawn_monitor(fn ->
        result = transfer(asset, tmp_path, download_opts, apply_opts)
        send(parent, {:update_transfer_done, result})
      end)

    schedule_progress(state)
    %{state | status: :downloading, downloaded: 0, total: asset.size, worker: {pid, ref}}
  end

  # Runs off the GenServer; see the moduledoc for why. Always returns rather
  # than raising, so the caller always gets a result to show.
  defp transfer(asset, tmp_path, download_opts, apply_opts) do
    with :ok <- Update.download(asset, tmp_path, download_opts),
         {:ok, _output} <- Update.apply(tmp_path, apply_opts) do
      :ok
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  after
    # Tmpfs is RAM on this device; the file has done its job whether fwup
    # accepted it or not, and there is no reason to hold onto ~1GB's worth
    # of it either way.
    File.rm(tmp_path)
  end

  defp apply_transfer_result(:ok, state),
    do: %{state | status: :done, error: nil, worker: nil}

  defp apply_transfer_result({:error, reason}, state),
    do: %{state | status: :error, error: diagnose(reason, state), worker: nil}

  defp diagnose({:http, _reason} = reason, state) do
    if state.time_synchronized?.(), do: reason, else: {:clock_unsynchronized, reason}
  end

  defp diagnose(reason, _state), do: reason

  defp schedule_progress(state), do: Process.send_after(self(), :poll_progress, state.poll_ms)

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _error -> 0
    end
  end

  # -- input ------------------------------------------------------------------

  defp apply_events(state, events) do
    Enum.reduce(events, state, fn
      {:ev_key, key, 1}, acc -> press(acc, key)
      _event, acc -> acc
    end)
  end

  defp press(state, @menu), do: state

  defp press(%{status: status} = state, @advance) when status in [:idle, :up_to_date, :error],
    do: run_check(state)

  defp press(%{status: :available} = state, @advance), do: start_transfer(state)
  defp press(%{status: :done} = state, @advance), do: reboot(state)
  defp press(state, _key), do: state

  defp reboot(state) do
    state.reboot.()
    state
  end

  # -- snapshot -----------------------------------------------------------------

  defp snapshot_of(state) do
    %{
      status: state.status,
      result: state.result,
      error: state.error,
      downloaded: state.downloaded,
      total: state.total
    }
  end

  defp notify(state, previous) do
    if previous != nil and snapshot_of(state) == snapshot_of(previous) do
      state
    else
      snapshot = snapshot_of(state)
      Enum.each(state.watchers, &send(&1, {:update_app, snapshot}))
      state
    end
  end
end
