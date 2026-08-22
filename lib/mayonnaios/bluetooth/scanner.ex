defmodule MayonnaiOS.Bluetooth.Scanner do
  @moduledoc """
  The handheld as a scanner: what is advertising, and how strongly.

  The other direction from `MayonnaiOS.Bluetooth.Peripheral`. That process
  puts this device on the air and waits to be found; this one listens and
  builds a list. Both need `MayonnaiOS.Bluetooth.Host` and therefore hci0, so
  both cannot run at once -- which is why each belongs to an app the launcher
  starts one at a time rather than to the boot supervision tree.

  ## Setup is the same four commands, and then two more

  Reset, the event mask, the LE event mask, LE host support: identical to the
  peripheral's, and for the same reasons. The LE event mask default of `0x1F`
  already has bit 1 set, which is the Advertising Report event, so nothing
  extra is needed there -- worth saying because a scanner that sets scan
  parameters and enable and then hears nothing is exactly what a missing mask
  bit looks like.

  What is added is scan parameters and scan enable. Buffer sizes are not read:
  a scan never sends an ACL packet, so there is no credit accounting to do.

  ## Failing to start is reported, not retried

  A setup that fails leaves this process alive with `started?: false` and the
  reason in `status/0`, exactly as the peripheral does. The panel is the only
  place anyone can read this on a handheld, and a supervisor restarting the
  process every second would keep the radio busy and the reason off the
  screen.

  ## What this is not

  It is not a client. There is no `connect/1` here, and the omission is the
  point rather than an unfinished edge: this stack has no GATT client, no
  BR/EDR at all, and no A2DP, so a connection made from here would be an
  encrypted link with nothing to say over it. `MayonnaiOS.Bluetooth.Scan`
  carries the flags that let the screen say which devices would need the
  transport this firmware does not have.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Bluetooth.{HCI, Host, Scan}

  # Twice a second is enough for a screen that refreshes twice a second, and
  # it keeps the sweep off the path of the reports themselves.
  @sweep_ms 1_000

  # A device that has not advertised for this long is dropped. Long enough to
  # ride out a slow advertiser (the 10.24 s worst case in the specification is
  # for a directed advertiser; connectable devices sit far below it) and short
  # enough that switching headphones off is visible while still holding them.
  @stale_ms 30_000

  defstruct scan: nil, started?: false, error: nil, dropped: 0

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every device seen, first seen first, with an age against the clock now."
  @spec devices() :: [map()]
  def devices, do: GenServer.call(__MODULE__, :devices)

  @doc """
  Whether the scan is on the air, and the reason if it is not.
  """
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    # Trapping exits is what makes `terminate/2` run at all: a GenServer taken
    # down by its supervisor's shutdown signal skips terminate unless it traps,
    # and terminate is where the scan is switched off. Without this the radio
    # keeps scanning between two runs of the app, which costs battery and is
    # invisible.
    Process.flag(:trap_exit, true)

    {:ok, %__MODULE__{scan: Scan.new()}, {:continue, {:setup, opts}}}
  end

  @impl true
  def handle_continue({:setup, opts}, state) do
    :ok = Host.attach(self())

    with {:ok, _} <- Host.command(HCI.reset()),
         {:ok, _} <- Host.command(HCI.set_event_mask()),
         {:ok, _} <- Host.command(HCI.le_set_event_mask()),
         {:ok, _} <- Host.command(HCI.write_le_host_support()),
         {:ok, _} <- Host.command(HCI.le_set_scan_parameters(Keyword.take(opts, [:type]))),
         {:ok, _} <- Host.command(HCI.le_set_scan_enable(true)) do
      Logger.info("[scanner] scanning")
      :timer.send_interval(@sweep_ms, :sweep)
      {:noreply, %{state | started?: true}}
    else
      {:error, reason} ->
        Logger.error("[scanner] setup failed: #{inspect(reason)}")
        {:noreply, %{state | started?: false, error: reason}}
    end
  end

  @impl true
  def handle_call(:devices, _from, state) do
    now = now()

    devices =
      state.scan
      |> Scan.list()
      |> Enum.map(fn device ->
        device
        |> Map.put(:age_ms, Scan.age(device, now))
        |> Map.put(:dual_mode?, Scan.dual_mode?(device))
        |> Map.put(:label, Scan.label(device))
      end)

    {:reply, devices, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       scanning: state.started?,
       error: state.error,
       devices: Scan.count(state.scan),
       # Reports that decoded to nothing. Zero is the expected value; anything
       # else means the report walk above disagrees with what this controller
       # sends, which is the one part of this that has never met the hardware.
       undecodable: state.dropped
     }, state}
  end

  @impl true
  def handle_info({:hci, {:event, :le_advertising_report, %{reports: []}}}, state) do
    {:noreply, %{state | dropped: state.dropped + 1}}
  end

  def handle_info({:hci, {:event, :le_advertising_report, %{reports: reports}}}, state) do
    now = now()
    scan = Enum.reduce(reports, state.scan, &Scan.observe(&2, &1, now))
    {:noreply, %{state | scan: scan}}
  end

  # Everything else off the controller. Logged at debug rather than dropped
  # silently: a scan that produces nothing while the controller is sending
  # events of some other shape is a different fault from a silent radio.
  def handle_info({:hci, packet}, state) do
    Logger.debug("[scanner] ignoring #{inspect(packet)}")
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    {:noreply, %{state | scan: Scan.forget_stale(state.scan, now(), @stale_ms)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{started?: true}) do
    # Stop the scan before the socket goes. Closing hci0 would stop it too --
    # the kernel closes the device with the user channel -- but this app can be
    # stopped and started repeatedly from the menu, and leaving the controller
    # scanning between runs would cost battery for nothing.
    Host.command(HCI.le_set_scan_enable(false))
    :ok
  rescue
    # Host may already be gone: this is a `:one_for_all` tree and the socket
    # dying is one of the ways this process is asked to stop.
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp now, do: System.monotonic_time(:millisecond)
end
