defmodule MayonnaiOS.Top do
  @moduledoc """
  The process readout app: `top`, for whichever of this device's two worlds
  the menu row named.

  One module, two menu entries -- `{MayonnaiOS.Top, :beam}` and
  `{MayonnaiOS.Top, :os}`, the same `{module, arg}` shape graphical pickles
  use -- because the two screens differ only in where the rows come from.
  `MayonnaiOS.Top.Beam` reads the VM, `MayonnaiOS.Top.Os` reads `/proc`, and
  everything else here -- the refresh clock, the scrolling, the sort, the
  scene -- is shared.

      iex> MayonnaiOS.Top.start(:beam)
      iex> MayonnaiOS.Top.snapshot().rows |> hd()
      iex> MayonnaiOS.Top.stop()

  An app rather than a program: a module in this firmware, started in this
  VM, with no external process and no screen handed over. See
  `MayonnaiOS.Programs` for what that costs and buys. It needs only the buttons and the panel, so two of these could run without
  harm -- there is still one, because it is one named process and one row of
  state.

  ## The buttons

      D-pad up/down    scroll one row
      D-pad left/right scroll one screen
      Y                flip the sort: activity or memory
      Menu             leave, handled by the Launcher

  A and B do nothing: the rows are readings, not things to open. Autorepeat
  scrolls, so holding a direction walks a long list.

  ## Both columns need a previous sample

  Neither world accounts "busy right now" in a single reading -- the OS gives
  cumulative jiffies and the VM gives cumulative reductions -- so the
  activity column on both screens is a delta between refreshes. The first
  frame shows `--` there and sorts those rows last; two seconds later the
  numbers are real. The samplers own that arithmetic; this process only keeps
  the previous sample's reference and hands it back.
  """

  use GenServer

  alias MayonnaiOS.Top.{Beam, Os}

  # The buttons as InputEvent names them, which is not what the shell prints;
  # `MayonnaiOS.Launcher` has the account of the device tree lying about X/Y.
  # Shell Y is 307, which InputEvent calls :btn_x.
  @y_button :btn_x

  @up :btn_dpad_up
  @down :btn_dpad_down
  @left :btn_dpad_left
  @right :btn_dpad_right

  @dpad [@up, @down, @left, @right]

  # Menu belongs to the Launcher: it is the way out of any app, and this one
  # drops it on the floor exactly as `MayonnaiOS.Controller.Report` does.
  @menu :btn_mode

  # One screen of rows. The scene draws exactly this many, and the snapshot
  # carries the window rather than the whole list so the two cannot disagree
  # about what a page is.
  @visible 16

  # top's own cadence. Once a second would double the sampling for a reading
  # nobody can act on faster, and the deltas get less noisy with the longer
  # baseline.
  @refresh_ms 2_000

  # -- the app protocol the Launcher uses -------------------------------------

  @sessions MayonnaiOS.Top.Sessions

  @doc """
  Start the app on one of its two screens.

  Under a DynamicSupervisor rather than linked to the caller, for the reason
  the controller is: the Launcher calls this from the process that owns the
  gamepad, and a bug here must not take the buttons down with it.

  Idempotent about the process and explicit about the screen: starting `:os`
  while `:beam` is up switches the running one over rather than failing, so
  the menu row pressed is the screen shown whatever a console did earlier.
  """
  @spec start(:beam | :os) :: {:ok, pid()} | {:error, term()}
  def start(kind) when kind in [:beam, :os] do
    case DynamicSupervisor.start_child(@sessions, {__MODULE__, []}) do
      {:ok, pid} -> show(pid, kind)
      {:error, {:already_started, pid}} -> show(pid, kind)
      {:error, reason} -> {:error, reason}
    end
  end

  defp show(pid, kind) do
    GenServer.call(__MODULE__, {:show, kind})
    {:ok, pid}
  end

  @doc "Stop the app."
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@sessions, pid)
    end
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
      # Temporary for the reason the other app sessions are: whatever went
      # wrong is in the log, and a readout that restarts itself back onto the
      # screen someone just left is not help.
      restart: :temporary
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Forward an evdev report from the Launcher.

  A cast, so a slow sample can never make the buttons late, and safe when the
  app is not running.
  """
  @spec input([tuple()]) :: :ok
  def input(events) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:input, events}), else: :ok
  end

  @doc "The scene the launcher shows while this app has the buttons."
  @spec scene() :: module()
  def scene, do: MayonnaiOS.Scene.Top

  @doc """
  Everything the panel needs, as one map: the visible window of rows, how
  many there are in all, the header stats, and which sort is on.

  A call, so a test that has just cast a synthetic button press is ordered
  behind it and does not have to sleep.
  """
  @spec snapshot() :: map() | :stopped
  def snapshot do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :snapshot), else: :stopped
  end

  @doc """
  Be told when the snapshot changes, as `{:top, snapshot}`.

  The scene does this instead of polling; a refresh arrives every couple of
  seconds and a scroll arrives when a button moved it. The watcher is
  monitored, so a scene torn down by `set_root/3` drops itself.
  """
  @spec watch(pid()) :: map() | :stopped
  def watch(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:watch, pid}), else: :stopped
  end

  # -- state -------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      kind: Keyword.get(opts, :kind, :beam),
      # The proc directory, a parameter so the tests can run the :os screen
      # against a fixture on a host that has no /proc.
      proc: Keyword.get(opts, :proc, "/proc"),
      refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms),
      rows: [],
      header: nil,
      error: nil,
      prev: nil,
      offset: 0,
      sort: :cpu,
      watchers: []
    }

    state = refresh(state)
    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  def handle_call({:watch, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, snapshot_of(state), %{state | watchers: [pid | state.watchers]}}
  end

  # Switching screens resets the scroll and the sort -- the new list has no
  # relation to the old position -- and keeps the previous sample only when it
  # is a sample of the same world, so a :beam delta is never computed against
  # an :os reading.
  def handle_call({:show, kind}, _from, state) do
    prev = if kind == state.kind, do: state.prev, else: nil

    state = refresh(%{state | kind: kind, prev: prev, offset: 0, sort: :cpu})
    {:reply, :ok, notify(state, nil)}
  end

  @impl GenServer
  def handle_cast({:input, events}, state) do
    {:noreply, state |> apply_events(events) |> notify(state)}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    state = refresh(state)
    schedule(state)
    {:noreply, notify(state, nil)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | watchers: List.delete(state.watchers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Rescheduled by hand rather than :timer.send_interval, so the timer dies
  # with the process and a sample that ran long delays the next tick instead
  # of stacking a second one behind it.
  defp schedule(state), do: Process.send_after(self(), :refresh, state.refresh_ms)

  defp snapshot_of(state) do
    %{
      kind: state.kind,
      header: state.header,
      rows: Enum.slice(state.rows, state.offset, @visible),
      total: length(state.rows),
      offset: state.offset,
      sort: state.sort,
      error: state.error
    }
  end

  # `previous` is the state to diff against, or nil for "always send" -- a
  # refresh is always news, a button press only when it changed something.
  defp notify(state, previous) do
    if previous != nil and snapshot_of(state) == snapshot_of(previous) do
      state
    else
      snapshot = snapshot_of(state)
      Enum.each(state.watchers, &send(&1, {:top, snapshot}))
      state
    end
  end

  # -- sampling ----------------------------------------------------------------

  defp refresh(state) do
    case take_sample(state) do
      {:ok, sample} ->
        rows = state.kind |> rows(sample, state.prev) |> sort(state.sort)

        clamp(%{
          state
          | rows: rows,
            header: header(state.kind, sample),
            prev: ref(state.kind, sample),
            error: nil
        })

      {:error, reason} ->
        %{state | rows: [], header: nil, prev: nil, error: reason, offset: 0}
    end
  end

  defp take_sample(%{kind: :beam}), do: {:ok, Beam.sample()}
  defp take_sample(%{kind: :os, proc: proc}), do: Os.sample(proc)

  defp rows(:beam, sample, prev), do: Beam.rows(sample, prev)
  defp rows(:os, sample, prev), do: Os.rows(sample, prev)

  defp ref(:beam, sample), do: Beam.ref(sample)
  defp ref(:os, sample), do: Os.ref(sample)

  defp header(:beam, sample), do: Beam.header(sample)
  defp header(:os, sample), do: Os.header(sample)

  # Rows with no delta yet sort below any row with one: a `--` that opened
  # the screen at the top would put the stalest information first.
  defp sort(rows, :cpu), do: Enum.sort_by(rows, &{&1.cpu || -1, &1.mem}, :desc)
  defp sort(rows, :mem), do: Enum.sort_by(rows, &{&1.mem, &1.cpu || -1}, :desc)

  # -- input -------------------------------------------------------------------

  defp apply_events(state, events) do
    Enum.reduce(events, state, fn
      {:ev_key, key, 1}, acc -> press(acc, key)
      # Autorepeat, for the D-pad only: a held direction scrolls, a held Y
      # does not flip the sort back and forth.
      {:ev_key, key, 2}, acc when key in @dpad -> press(acc, key)
      _event, acc -> acc
    end)
  end

  defp press(state, @menu), do: state
  defp press(state, @up), do: scroll(state, -1)
  defp press(state, @down), do: scroll(state, +1)
  defp press(state, @left), do: scroll(state, -@visible)
  defp press(state, @right), do: scroll(state, +@visible)

  # Flipping the sort re-sorts what is already on hand rather than waiting for
  # the next tick, and goes back to the top: the point of a sort is its head.
  defp press(state, @y_button) do
    sort = if state.sort == :cpu, do: :mem, else: :cpu
    %{state | sort: sort, rows: sort(state.rows, sort), offset: 0}
  end

  defp press(state, _key), do: state

  # Clamped rather than wrapped: a list of readings has a top and a bottom,
  # and scrolling off the end of one hundred processes back to the first reads
  # as the screen having lost its place.
  defp scroll(state, delta), do: clamp(%{state | offset: state.offset + delta})

  defp clamp(state) do
    %{state | offset: state.offset |> min(length(state.rows) - @visible) |> max(0)}
  end
end
