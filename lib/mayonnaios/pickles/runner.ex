defmodule MayonnaiOS.Pickles.Runner do
  @moduledoc """
  One running pickle: a GenServer holding its Lua state.

  The runner serializes everything -- action calls, timer ticks, `on_start` --
  because the Lua state is a value and there is exactly one current one.
  Every piece of Lua runs through `Sandbox.exec/2` in a throwaway process, so
  a script that loops forever or eats memory costs one killed process and a
  log line, never the runner and never its state.

  ## The script's contract

  The chunk runs once at start. If it defined `on_start()`, that is called
  next. After that the script is inert until something calls into it: a named
  action (any global function, invoked over the web API or from the console)
  or a timer callback it registered with `mayo.timer`.

  ## A script that fails to load stays visible

  A broken chunk does not kill the runner. It sits in status
  `{:error, reason}` with the reason in its log, because a pickle that
  vanishes on error tells its author nothing, and the author is holding a
  phone, not a stack trace. Same philosophy as `Programs` rendering missing
  binaries.

  ## Timers

  `mayo.timer.every/once` registrations arrive as messages (see the Sandbox
  moduledoc for why) and live here as `Process.send_after` loops. Intervals
  are clamped to at least 250 ms and at most 16 timers exist at once --
  clamped and logged rather than rejected, because by the time the message
  arrives the Lua call that made it has already returned `true`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias MayonnaiOS.Pickles.{Sandbox, Store}

  @min_interval 250
  @max_timers 16
  @max_log 200

  # -- client ------------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def via(name), do: {:via, Registry, {MayonnaiOS.Pickles.Registry, name}}

  @doc """
  Call the global Lua function `fname` with `args` (plain Elixir terms).
  """
  def call(name, fname, args) do
    GenServer.call(via(name), {:call, fname, args}, 40_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Status and recent log of a running pickle.
  """
  def info(name) do
    GenServer.call(via(name), :info)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  def stop(name) do
    GenServer.stop(via(name), :normal)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  def whereis(name) do
    case Registry.lookup(MayonnaiOS.Pickles.Registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # -- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    root = Keyword.fetch!(opts, :root)

    case Store.manifest(root, name) do
      {:ok, manifest} ->
        state = %{
          name: name,
          root: root,
          manifest: manifest,
          lua: nil,
          status: :starting,
          log: [],
          timers: %{},
          next_timer: 1
        }

        # The chunk and on_start run in handle_continue rather than here:
        # they have a 30-second budget each, and a supervisor waiting that
        # long on init would stall every sibling behind it.
        {:ok, state, {:continue, :boot}}

      {:error, reason} ->
        {:stop, {:bad_manifest, reason}}
    end
  end

  @impl true
  def handle_continue(:boot, state) do
    %{manifest: manifest, root: root, name: name} = state

    lua =
      Sandbox.new(manifest, self(), state_path: Store.state_path(root, name))

    script = Path.join([Store.dir(root, name), manifest.main])

    with {:ok, chunk} <- File.read(script),
         {:ok, lua} <- exec_load(lua, chunk),
         {:ok, lua} <- exec_on_start(lua) do
      {:noreply, %{state | lua: lua, status: :running} |> log("started")}
    else
      {:error, reason} ->
        Logger.warning("[pickle #{name}] failed to start: #{inspect(reason)}")

        {:noreply,
         %{state | status: {:error, reason}} |> log("failed to start: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_call({:call, fname, args}, _from, state) do
    case state do
      %{status: :running, lua: lua} ->
        if Sandbox.function?(lua, fname) do
          case Sandbox.exec(fn -> Sandbox.call(lua, fname, args) end) do
            {:ok, results, lua} ->
              {:reply, {:ok, results}, %{state | lua: lua}}

            {:error, reason} ->
              {:reply, {:error, reason}, log(state, "#{fname}: #{inspect(reason)}")}
          end
        else
          {:reply, {:error, :no_such_function}, state}
        end

      %{status: status} ->
        {:reply, {:error, {:not_running, status}}, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      name: state.name,
      status: state.status,
      log: Enum.reverse(state.log),
      timers: map_size(state.timers)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:pickle_log, msg}, state) do
    Logger.info("[pickle #{state.name}] #{msg}")
    {:noreply, log(state, msg)}
  end

  def handle_info({:pickle_timer_req, kind, ms, fname}, state) do
    cond do
      map_size(state.timers) >= @max_timers ->
        {:noreply, log(state, "timer for #{fname} dropped: already #{@max_timers} timers")}

      true ->
        ms = max(ms, @min_interval)
        id = state.next_timer
        Process.send_after(self(), {:pickle_tick, id}, ms)
        timers = Map.put(state.timers, id, %{kind: kind, ms: ms, fname: fname})
        {:noreply, %{state | timers: timers, next_timer: id + 1}}
    end
  end

  def handle_info({:pickle_tick, id}, state) do
    case {state.timers[id], state} do
      {nil, _} ->
        {:noreply, state}

      {timer, %{status: :running, lua: lua}} ->
        state =
          case Sandbox.exec(fn -> Sandbox.call(lua, timer.fname, []) end) do
            {:ok, _results, lua} ->
              %{state | lua: lua}

            {:error, reason} ->
              # The timer survives its callback failing: a lamp that was
              # unreachable once should be retried on the next tick, and a
              # script bug shows up as a repeating log line, which is louder
              # and more honest than a timer that silently stopped.
              log(state, "timer #{timer.fname}: #{inspect(reason)}")
          end

        case timer.kind do
          :every ->
            Process.send_after(self(), {:pickle_tick, id}, timer.ms)
            {:noreply, state}

          :once ->
            {:noreply, %{state | timers: Map.delete(state.timers, id)}}
        end

      {_timer, _} ->
        # Not running (failed load); drop the timer rather than tick a corpse.
        {:noreply, %{state | timers: Map.delete(state.timers, id)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- steps -------------------------------------------------------------------

  defp exec_load(lua, chunk) do
    case Sandbox.exec(fn -> Sandbox.load(lua, chunk) end) do
      {:ok, lua} -> {:ok, lua}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exec_on_start(lua) do
    if Sandbox.function?(lua, "on_start") do
      case Sandbox.exec(fn -> Sandbox.call(lua, "on_start", []) end) do
        {:ok, _results, lua} -> {:ok, lua}
        {:error, reason} -> {:error, {:on_start, reason}}
      end
    else
      {:ok, lua}
    end
  end

  defp log(state, msg) do
    entry = %{at: DateTime.utc_now(), msg: msg}
    %{state | log: Enum.take([entry | state.log], @max_log)}
  end
end
