defmodule MayonnaiOS.Status do
  @moduledoc """
  One process that reads the battery and the network, and pushes what it got.

  `MayonnaiOS.Scene.StatusBar` draws this. Every scene mounts that component,
  so whatever is on screen, the same readings are behind it and there is one
  place that does the reading.

  ## Why the scenes do not read sysfs themselves

  Because a file read on this device has been observed to block forever. A
  `:prim_file.read_file_nif/1` stuck in the kernel filled the dirty-IO
  schedulers one at a time while pure Elixir kept evaluating over SSH, and
  every filesystem operation after that hung. A status bar that read
  `/sys/class/power_supply` from the scene process would, in that state, take
  the whole panel down with it: no menu, no file columns, no diagnostics, and
  no clue why.

  So the read happens here, and the readings arrive at the scenes as
  messages. A poll that never returns costs the bar its battery reading and
  costs the rest of the screen nothing -- and because every reading carries
  the time it was taken, the bar can say that it has stopped hearing from
  this process instead of drawing the last number as though it were current.

  ## Why not ask Diagnostics

  `MayonnaiOS.Diagnostics` already reads the same four files once a second,
  and the parsing *is* shared -- both go through `MayonnaiOS.Power`, so there
  is one place that knows what `current_now` means. What is not shared is the
  process, and that is deliberate. `Diagnostics.snapshot/0` is a
  `GenServer.call`, and that collector has a handler which holds it for
  seconds by design: the Bluetooth probe owns hci0 for as long as it runs. The
  diagnostics screen already carries a rescue and a catch for exactly that. A
  bar on every screen, calling into that process once a second, would make the
  most-glanced-at thing on the panel depend on the least available process on
  the device.

  So: one parser, two callers, and this caller cannot be blocked by anything
  but its own read.

  ## What is pushed

  Subscribers receive `{:mayonnaios_status, reading}` where a reading is

      %{
        battery: %{value: MayonnaiOS.Power.values() | nil, error: term | nil, at: integer | nil},
        wifi:    %{value: atom, error: term | nil, at: integer | nil},
        at: integer
      }

  `at` is `System.monotonic_time(:millisecond)`, which is only comparable
  within one VM -- which is all it has to be, since the process that draws it
  is a scene in this VM. Wall-clock time would be the wrong choice here: the
  RTC is set at boot and NTP may step it afterwards, and an age computed
  across a step is exactly the kind of number that looks fine and is wrong.

  ## WiFi is both subscribed and polled, on purpose

  `VintageNet.subscribe/1` delivers property changes as they happen, which is
  how a disconnection reaches the panel within a frame instead of within a
  poll. But a subscription that has stopped arriving is indistinguishable
  from a network that has stopped changing, and "the WiFi state has not
  changed for an hour" is the normal case. So each poll also re-reads the
  property with `VintageNet.get/1`. That is an ETS read of a table this VM
  owns, not an I/O call -- it cannot block on hardware -- and it means the
  freshness of the WiFi reading is a statement about this process still
  running rather than about the radio still changing its mind.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Power

  # Two seconds. The battery moves in percent over minutes, and the point of
  # polling faster than that is not the battery: it is that a subscriber can
  # only notice this process has gone quiet against some expected rhythm, and
  # a slow rhythm means a long wait before the panel admits it.
  @poll_ms 2_000

  # The interface the bar reports on. The device-wide ["connection"] property
  # would also count usb0, which is up whenever the cable is in and would
  # make a dead radio look like a working network.
  @interface "wlan0"

  defstruct [:battery_opts, :poll_ms, :timer, battery: nil, wifi: nil, subscribers: %{}]

  @typedoc "A single reading, with the time it was taken."
  @type source :: %{value: term() | nil, error: term() | nil, at: integer() | nil}

  @type reading :: %{battery: source(), wifi: source(), at: integer()}

  @doc """
  Start the reader.

  Options: `:name`, `:poll_ms`, and `:battery`/`:usb` paths passed through to
  `MayonnaiOS.Power`. The tests use all of them; the application uses none.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ask to be sent every reading, starting with the one it has now.

  A cast rather than a call, and that is the whole design of this function. It
  is invoked from `MayonnaiOS.Scene.StatusBar.init/3`, which runs while the
  ViewPort is starting the root scene at boot: a call there would block the
  panel behind this process, and a call to a name nobody has registered would
  raise and take the root scene -- and therefore the whole screen -- with it.
  A cast to a dead name is a no-op, and a bar that never hears anything says
  so, which is the correct thing for it to say.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.cast(server, {:subscribe, self()})
  end

  @doc """
  The current reading, for a person at an IEx prompt.

  Deliberately not what the status bar uses: this is a call, and a call is
  the thing the bar must not do. The default timeout is short so that a
  wedged reader answers a human with an exit rather than a hang.
  """
  @spec reading(GenServer.server(), timeout()) :: reading()
  def reading(server \\ __MODULE__, timeout \\ 1_000) do
    GenServer.call(server, :reading, timeout)
  end

  @impl GenServer
  def init(opts) do
    poll_ms = Keyword.get(opts, :poll_ms, @poll_ms)
    battery_opts = Keyword.take(opts, [:battery, :usb])

    subscribe_to_vintage_net()

    state =
      %__MODULE__{battery_opts: battery_opts, poll_ms: poll_ms}
      |> poll()

    {:ok, %{state | timer: schedule(poll_ms)}}
  end

  @impl GenServer
  def handle_call(:reading, _from, state), do: {:reply, snapshot(state), state}

  @impl GenServer
  def handle_cast({:subscribe, pid}, state) do
    # Monitored rather than linked: a scene that dies while a program is
    # launched must not take the reader with it, and the reader must not
    # accumulate the ghosts of every scene the launcher has ever mounted.
    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
      end

    send(pid, {:mayonnaios_status, snapshot(state)})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = poll(state)
    publish(state)
    {:noreply, %{state | timer: schedule(state.poll_ms)}}
  end

  # A property changed. Taken as a fresh WiFi reading -- it is one -- and
  # published immediately, so a disconnection does not wait for the next poll.
  def handle_info({VintageNet, [_, @interface, "connection"], _old, new, _meta}, state) do
    state = %{state | wifi: source(new)}
    publish(state)
    {:noreply, state}
  end

  def handle_info({VintageNet, _property, _old, _new, _meta}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- reading ---------------------------------------------------------------

  defp poll(state) do
    %{state | battery: read_battery(state.battery_opts), wifi: read_wifi()}
  end

  defp read_battery(opts) do
    case Power.read(opts) do
      {:ok, values} -> source(values)
      {:error, reason} -> error(reason)
    end
  end

  # VintageNet is a target-only dependency, so on a development laptop there
  # is nothing to ask. That is reported as an error rather than as
  # "disconnected": a laptop running this UI has a network, and a bar claiming
  # otherwise would be a bar nobody believes when it matters.
  defp read_wifi do
    if Code.ensure_loaded?(VintageNet) do
      case apply(VintageNet, :get, [["interface", @interface, "connection"]]) do
        nil -> error(:no_interface)
        value -> source(value)
      end
    else
      error(:not_managed)
    end
  rescue
    # get/1 reads a property table owned by the vintage_net application. If
    # that application is not running the table is not there, and this is a
    # bar, not a supervisor -- it says it does not know.
    error -> error(error)
  end

  defp subscribe_to_vintage_net do
    if Code.ensure_loaded?(VintageNet) do
      apply(VintageNet, :subscribe, [["interface", @interface, "connection"]])
    end
  rescue
    error ->
      Logger.warning("[status] VintageNet.subscribe failed: #{inspect(error)}")
      :error
  end

  # -- plumbing --------------------------------------------------------------

  defp source(value), do: %{value: value, error: nil, at: now()}
  defp error(reason), do: %{value: nil, error: reason, at: now()}

  defp snapshot(state) do
    %{battery: state.battery, wifi: state.wifi, at: now()}
  end

  defp publish(state) do
    reading = snapshot(state)
    for {pid, _ref} <- state.subscribers, do: send(pid, {:mayonnaios_status, reading})
    :ok
  end

  # send_after rather than send_interval: if a poll ever does block forever,
  # an interval timer would queue a message every two seconds behind it, and
  # the mailbox would grow for as long as the device stayed up.
  defp schedule(poll_ms), do: Process.send_after(self(), :poll, poll_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
