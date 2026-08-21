defmodule MayonnaiOS.Controller.Battery do
  @moduledoc """
  Tells the host how much charge the handheld has left.

  The Battery Service in `MayonnaiOS.Bluetooth.HOGP` is one byte, and without
  something to keep it up to date that byte is a fixed 100 -- which is worse
  than not having the service at all. A host shows it next to the device name,
  and a controller that reports full charge forever is a controller that dies
  without warning while it says 100%.

  So this reads what `MayonnaiOS.Diagnostics` already collects from
  `/sys/class/power_supply` and hands the percentage to the peripheral. It
  does not read sysfs itself: the collector is already polling those files and
  a second reader would be two answers to one question.

  ## Once a minute, and only on a change

  A battery percentage moves a few times an hour. Polling faster would cost a
  connection event for nothing, and every connection event spent on the
  battery is one not spent on a button press. `Peripheral.battery/1` is called
  only when the number differs from the last one sent, so a host with a
  subscription gets a notification when there is news and silence otherwise.

  ## Nothing here fails loudly

  On a laptop there is no collector and no battery, and the answer is `nil`
  every time. That is not worth a log line a minute, so it is simply skipped.
  The consequence is that the battery reads 100 during host development, which
  is visible in `MayonnaiOS.Controller.status/0` and is the honest state of a
  machine that has no `axp20x-battery`.
  """

  use GenServer

  alias MayonnaiOS.Bluetooth.Peripheral
  alias MayonnaiOS.Diagnostics

  @interval_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    :timer.send_interval(interval, :poll)

    # Once at startup as well as on the interval, so a host that connects in
    # the first minute is told the truth rather than the seeded 100.
    {:ok, poll(%{last: nil})}
  end

  @impl true
  def handle_info(:poll, state), do: {:noreply, poll(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp poll(state) do
    case capacity() do
      nil -> state
      percent when percent == state.last -> state
      percent -> report(state, percent)
    end
  end

  defp report(state, percent) do
    Peripheral.battery(percent)
    %{state | last: percent}
  end

  # The collector holds the last reading it took; `capacity` is a percentage
  # or nil when the file was not there. A call into a process that may not be
  # running, or may be busy in a Bluetooth probe, must not take this one down
  # -- hence the same guarding the diagnostics scene uses.
  defp capacity do
    if Process.whereis(Diagnostics) do
      Diagnostics.snapshot() |> get_in([Access.key(:battery, %{}), :capacity]) |> clamp()
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp clamp(percent) when is_integer(percent), do: min(max(percent, 0), 100)
  defp clamp(_other), do: nil
end
