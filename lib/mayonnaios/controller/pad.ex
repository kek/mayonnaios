defmodule MayonnaiOS.Controller.Pad do
  @moduledoc """
  Holds what is currently pressed, and tells the host when that changes.

  The gamepad is read by `MayonnaiOS.Launcher`, which owns `gpio-keys-gamepad`
  and always has. This process does not open the device: the launcher forwards
  whole evdev reports here while controller mode is on. One reader, one owner,
  and the buttons keep working exactly as they did -- which also means the
  keyboard bridge in `MayonnaiOS.Keyboard` drives the controller too, so the
  whole path can be exercised from a laptop with no handheld attached.

  ## Only changes go out

  A report is sent when the encoded five bytes differ from the last five sent.
  Not on every evdev report, and not on a timer.

  HID input reports are edge-driven by design: the host holds the last state
  it was given until it is given another. So a repeat carries no information,
  and sending one costs a connection event that a button press might have
  used instead. Sending only on change also makes the auto-repeat the kernel
  generates for a held button free -- it folds into a state that is already
  what was last sent, and nothing goes out.

  ## Everything is released on the way out

  `terminate/2` sends one report with nothing pressed. Leaving controller mode
  with A held would otherwise leave the host holding A forever: there is no
  timeout on a HID report and no keepalive to notice its absence. The same
  applies to a disconnect, which the peripheral handles by dropping reports --
  a host that loses the link forgets the device's state anyway.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Bluetooth.Peripheral
  alias MayonnaiOS.Controller.Report

  # What the host already believes, before anything is pressed. Starting this
  # at nil rather than at the released report would make the first event of a
  # session send one whatever it was -- including an event this report does
  # not carry, like Menu -- and "pressing Menu sends a report" is exactly the
  # kind of thing that is invisible until a host does something odd with it.
  @released Report.encode(%Report{})

  defstruct report: %Report{}, last: @released, sink: &Peripheral.report/1, unknown: MapSet.new()

  @doc """
  Start folding reports.

  `:sink` is where encoded reports go, and defaults to the peripheral. The
  tests pass a function that sends to the test process, which is what lets the
  whole button-to-bytes path be checked without a radio.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Fold an evdev report in, and send one if anything changed."
  @spec input([tuple()]) :: :ok
  def input(events), do: GenServer.cast(__MODULE__, {:input, events})

  @doc "What is held right now, as the host would see it."
  @spec state() :: %{pressed: [atom()], directions: [atom()], bytes: binary()}
  def state, do: GenServer.call(__MODULE__, :state)

  @impl true
  def init(opts) do
    # Without this, terminate/2 does not run on an ordinary shutdown and the
    # release report below is never sent -- which is the whole reason this
    # process has a terminate/2 at all.
    Process.flag(:trap_exit, true)

    {:ok, %__MODULE__{sink: Keyword.get(opts, :sink, &Peripheral.report/1)}}
  end

  @impl true
  def handle_cast({:input, events}, state) do
    state = Enum.reduce(events, state, &note_unknown/2)
    report = Report.apply_events(state.report, events)
    bytes = Report.encode(report)

    if bytes == state.last do
      {:noreply, %{state | report: report}}
    else
      state.sink.(bytes)
      {:noreply, %{state | report: report, last: bytes}}
    end
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply,
     %{
       pressed: MapSet.to_list(state.report.buttons),
       directions: MapSet.to_list(state.report.directions),
       bytes: Report.encode(state.report)
     }, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Only if something is actually held. A release report into a host that is
    # already at rest is harmless but it is also a lie about an event that did
    # not happen, and this one is easy to get right.
    if state.last != @released, do: state.sink.(@released)

    :ok
  end

  # A button on this shell with no place in the report is worth exactly one
  # log line, not one per press. The mapping was read off the hardware for
  # some buttons and inferred for others (see `MayonnaiOS.Controller.Report`),
  # so this is how an inference that turned out wrong announces itself.
  defp note_unknown({:ev_key, key, 1}, state) do
    if Report.known?(key) or MapSet.member?(state.unknown, key) do
      state
    else
      Logger.info("[pad] #{inspect(key)} is not mapped to anything the host sees")
      %{state | unknown: MapSet.put(state.unknown, key)}
    end
  end

  defp note_unknown(_event, state), do: state
end
