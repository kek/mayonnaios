defmodule MayonnaiOS.Led do
  @moduledoc """
  The indicator LED, driven as a five-state signal.

  The window nearest the HDMI port holds two emitters behind one hole, and
  sysfs names both after colors the device tree assigned, not the colors they
  shine. Verified by lighting each alone and looking at the device:

    * `green:power` shines **green**
    * `green:status` shines **red**, whatever its name says

  The other window is the AXP717's charge indicator -- solid yellow whenever
  the device has power on USB. It is wired to the PMIC, not to Linux, so
  charging and charged-full stay its job and this module never touches it.
  (`rgb:indicator` on PI7 and the rtw88 LED light nothing visible; they are
  left alone.)

  ## The signal

  | State       | LED                        | Meaning                          |
  |-------------|----------------------------|----------------------------------|
  | `:starting` | quick flashing green       | BEAM up, supervision tree rising |
  | `:running`  | solid green                | the whole tree came up           |
  | `:sleeping` | slow flashing green        | backlight off, still running     |
  | `:failure`  | blinking red               | the application failed to start  |
  | `:off`      | dark                       | (also what a powered-off board shows) |

  The LED is the earliest signal the board gives and the only one that
  survives a UI that fails to start. Solid green means something specific:
  the kernel is running, the BEAM started, and every child of the supervision
  tree came up -- `{__MODULE__, :running}` sits after the launcher, so it
  cannot run sooner. Between kernel and BEAM the LED is dark; only a device
  tree default could light it earlier, and that is a system-repo change.

  `CONFIG_LEDS_GPIO` and `CONFIG_LEDS_TRIGGER_TIMER` are built in, so all of
  this is sysfs writes: `timer` with `delay_on`/`delay_off` for the flashing
  states, `none` plus a brightness for solid and dark.

  ## On a laptop

  `/sys/class/leds` does not exist there, and that is ordinary rather than
  wrong, so an absent directory is a debug line and `:ok`. A directory that
  is present but refuses a write is a warning naming the file: that is a
  device with a real problem. Tests point `:leds_class` at a temp directory
  and read back what landed, the same trick `MayonnaiOS.Sleep` uses.
  """

  require Logger

  @default_dir "/sys/class/leds"

  # The emitters by sysfs name. See the moduledoc: the names describe the
  # device tree's opinion, the comments describe the light.
  @green "green:power"
  @red "green:status"

  # Flash cadences, in milliseconds on/off. Quick reads as activity, slow as
  # a device at rest, and the red blink sits between them -- fast enough to
  # look wrong, slow enough to count.
  @quick {100, 100}
  @slow {1000, 1000}
  @blink {250, 250}

  @type state :: :starting | :running | :sleeping | :failure | :off

  @doc false
  # Two entries in the supervision tree, one state each: `{MayonnaiOS.Led,
  # :starting}` first, `{MayonnaiOS.Led, :running}` after the launcher. The
  # id carries the state so both can be children of the same supervisor.
  def child_spec(state) when state in [:starting, :running] do
    %{
      id: {__MODULE__, state},
      start: {Task, :start_link, [__MODULE__, :set, [state]]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  The directory the LEDs live in.

  From `config :mayonnaios, :leds_class`, defaulting to the kernel's.
  """
  @spec dir() :: String.t()
  def dir, do: Application.get_env(:mayonnaios, :leds_class, @default_dir)

  @doc """
  Put the LED in `state`.

  Every state writes both emitters, so no state depends on what the previous
  one left behind and two calls in a row land in the same place. `:ok` even
  when there are no LEDs to set -- see the moduledoc -- and `{:error, reason}`
  from the first write a present directory refuses.
  """
  @spec set(state()) :: :ok | {:error, File.posix()}
  def set(state) do
    if File.dir?(dir()) do
      apply_state(state)
    else
      Logger.debug("[led] #{dir()} absent; nothing to set")
      :ok
    end
  end

  defp apply_state(:starting), do: combine(off(@red), flash(@green, @quick))
  defp apply_state(:running), do: combine(off(@red), solid(@green))
  defp apply_state(:sleeping), do: combine(off(@red), flash(@green, @slow))
  defp apply_state(:failure), do: combine(off(@green), flash(@red, @blink))
  defp apply_state(:off), do: combine(off(@red), off(@green))

  # Both emitters are always written; the first error is the one returned,
  # after every write has been attempted, so one refused file does not leave
  # the other emitter in the previous state.
  defp combine(:ok, second), do: second
  defp combine({:error, _} = first, _second), do: first

  defp solid(led) do
    combine(write(led, "trigger", "none"), write(led, "brightness", "1"))
  end

  defp off(led) do
    combine(write(led, "trigger", "none"), write(led, "brightness", "0"))
  end

  # The timer trigger's delay files appear when the trigger is set, so the
  # trigger write goes first.
  defp flash(led, {on_ms, off_ms}) do
    write(led, "trigger", "timer")
    |> combine(write(led, "delay_on", Integer.to_string(on_ms)))
    |> combine(write(led, "delay_off", Integer.to_string(off_ms)))
  end

  defp write(led, file, value) do
    path = Path.join([dir(), led, file])

    case File.write(path, value) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[led] cannot write #{value} to #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
