defmodule MayonnaiOS.Heartbeat do
  @moduledoc """
  Sets every LED to the kernel's heartbeat trigger so the device visibly shows
  that it is alive.

  Originally this was the *only* feedback the board gave: the display did not
  work, and the LED that glows yellow is the AXP717 charge indicator, which
  looks identical whether the device booted or is wedged. The panel works now,
  so the LED is no longer the sole signal -- but it is still the earliest one,
  and the only one that survives a UI that fails to start.

  A blinking LED means something quite specific: the kernel is running, the
  BEAM started, and the supervision tree came up. Steady or dark means it did
  not get this far.

  `CONFIG_LEDS_GPIO` and `CONFIG_LEDS_TRIGGER_HEARTBEAT` are both built in, so
  this only needs to write to sysfs.
  """

  require Logger

  @leds_class "/sys/class/leds"
  @trigger "heartbeat"

  @doc false
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&__MODULE__.start_blinking/0]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Point every LED at the heartbeat trigger.
  """
  @spec start_blinking() :: :ok
  def start_blinking() do
    case File.ls(@leds_class) do
      {:ok, []} ->
        Logger.warning("[heartbeat] no LEDs in #{@leds_class}")

      {:ok, leds} ->
        set = Enum.filter(leds, &set_trigger/1)
        Logger.info("[heartbeat] blinking: #{Enum.join(set, ", ")} (of #{Enum.join(leds, ", ")})")

      {:error, reason} ->
        Logger.warning("[heartbeat] #{@leds_class} unreadable: #{inspect(reason)}")
    end

    :ok
  end

  defp set_trigger(led) do
    path = Path.join([@leds_class, led, "trigger"])

    case File.write(path, @trigger) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("[heartbeat] #{led}: #{inspect(reason)}")
        false
    end
  end
end
