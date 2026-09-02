defmodule MayonnaiOS.LowPower do
  @moduledoc """
  Experimental low-power measures applied in addition to the backlight.

  `MayonnaiOS.Sleep` turns the backlight off, which is verified on RG40XXV
  hardware and is the only measure the user can see. This module coordinates
  everything else. The source has a measured awake baseline at rest, screen
  on, and discharging: **415 mA at 3.78 V (1.57 W)**, stable across ten samples
  two seconds apart. It does not have a corresponding asleep measurement, so
  neither this module's total saving nor the backlight's share is measured.

  The following components were observed still active with the panel dark on
  firmware `3cc86f59`; this identifies work to stop, not its current draw or
  the saving from stopping it:

    * `scenic_driver_l` burned **9.5% of one core** over a 30-second idle
      sample, redrawing a screen nobody was looking at.

    * `card0-DSI-1` read `dpms=On` and `enabled`, so the display engine, the
      TCON and the DSI link went on scanning the framebuffer out of DRAM at
      60 Hz behind the dark LED.

    * `wlan0` stayed associated, with `rtw88_8821cs` bound on mmc1.

    * All four cores stayed online, at whatever frequency and voltage U-Boot
      left them at, because `/sys/devices/system/cpu/cpufreq` is **empty** --
      no policy, not a policy with one operating point.

  ## Why this is not suspend

  Because there is no suspend to reach. `/sys/power/mem_sleep` offers only
  `[s2idle]`: ATF's `sun50i_h616` platform has no `pwr_domain_suspend`, because
  the H616 die dropped the AR100 coprocessor that A64 and H6 use for exactly
  that, so PSCI `SYSTEM_SUSPEND` is not implemented and `deep` is never
  registered. `s2idle` itself aborts today inside `rtw_sdio_suspend`, which
  returns the `-EINVAL` from `sdio_set_host_pm_flags(MMC_PM_KEEP_POWER)`
  because no device tree here carries `keep-power-in-suspend`; and even a
  successful one would save little, since
  `/sys/devices/system/cpu/cpuidle/current_driver` reads `none` and `cpu@0`
  has no `idle-states`, so these cores reach a bare WFI and no further whether
  "suspended" or not.

  So this is what every other OS on this SoC does under the name suspend.
  ROCKNIX calls its equivalent "fake suspend" in its own source.

  ## The undo list

  `enter/0` returns a list of `{step, restore}` tuples and `leave/1` replays it
  **in reverse**, which is the whole shape of this module. Nothing is
  remembered in a GenServer, because state that outlives a crash is state that
  can disagree with the hardware: if this process dies asleep, its supervisor
  restarts it knowing nothing, and knowing nothing is recoverable in a way that
  a stale "the governor was ondemand" is not.

  Reverse order matters at one end in particular. On the way down the renderer
  stops first and the cores go last; on the way up the cores come back first
  and the renderer last, so the frame is redrawn while the panel is still dark
  and `MayonnaiOS.Launcher` turns the backlight on over a finished picture
  rather than over whatever the framebuffer held.

  Every step is rescued on its own. A step that fails contributes nothing to
  the undo list and is logged, and the remaining steps still run -- because the
  failure being defended against is a device stuck half-asleep, with three
  cores offline and no way to get them back. `leave/1` likewise rescues each
  restore separately: one failure must not strand the rest.

  A step whose hardware is absent is a no-op and says so at debug level rather
  than warning. Two of the four are no-ops on this firmware today -- there are
  no cpufreq policies to set a governor on, and there is no `/sys/class/rfkill`
  -- and both become effective the moment the system image grows them. That is
  deliberate: see `kek/nerves_system_rg40xxv#6`, which builds
  `sun50i-cpufreq-nvmem` in so a policy exists at all.

  ## What this cannot promise

  The extra mode is **Experimental** and its saving is unmeasured. Everything
  above measures the awake baseline and identifies active components; it does
  not measure the result. Historical estimates are 255-315 mA with the
  backlight off and 150-250 mA with all extra measures, but they are estimates,
  not readings. The number that would settle it is one reading of
  `/sys/class/power_supply/axp20x-battery/current_now` taken with the panel
  dark, and it has not been taken.
  """

  require Logger

  alias MayonnaiOS.LowPower.{Cpus, Governor, Radio, Renderer}

  # In the order they are applied. `leave/1` reverses it; see the moduledoc for
  # why the renderer is the outer layer and the cores the inner one.
  @steps [Renderer, Radio, Governor, Cpus]

  @typedoc """
  What `leave/1` needs in order to put one step back, opaque to everyone else.
  """
  @type undo :: [{module(), term()}]

  @doc """
  Go low-power, returning the undo list `leave/1` wants.

  Never fails: a step that cannot run is logged and left out of the list, so
  the caller has nothing to decide. Whether the device is asleep is the
  backlight's answer and `MayonnaiOS.Sleep`'s to give.
  """
  @spec enter() :: undo()
  def enter do
    if enabled?() do
      Enum.flat_map(@steps, &apply_step/1)
    else
      Logger.debug("[low_power] disabled by configuration")
      []
    end
  end

  @doc """
  Undo `enter/0`, in reverse.

  Always `:ok`. Each restore is rescued on its own, because the alternative to
  a partial recovery here is no recovery at all.
  """
  @spec leave(undo()) :: :ok
  def leave(undo) when is_list(undo) do
    undo
    |> Enum.reverse()
    |> Enum.each(fn {step, restore} ->
      case run(fn -> step.leave(restore) end) do
        {:ok, _} -> Logger.debug("[low_power] restored #{name(step)}")
        {:error, reason} -> warn(step, "restore", reason)
      end
    end)
  end

  @doc """
  Whether the extra measures run at all.

  From `config :mayonnaios, :low_power_sleep`, defaulting to on. The switch is
  here because taking `wlan0` down ends any SSH session that arrives over it,
  and somebody debugging a sleep bug over WiFi wants a way to say no. USB
  gadget setup is unaffected, but cable enumeration is unverified and `usb0`
  must not be assumed to provide a recovery connection.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:mayonnaios, :low_power_sleep, true)

  defp apply_step(step) do
    case run(fn -> step.enter() end) do
      {:ok, :noop} ->
        Logger.debug("[low_power] #{name(step)}: nothing to do here")
        []

      {:ok, restore} ->
        Logger.info("[low_power] #{name(step)}")
        [{step, restore}]

      {:error, reason} ->
        warn(step, "enter", reason)
        []
    end
  end

  # A step is arbitrary code against sysfs, a port and a network stack, so it
  # is allowed to raise, throw and exit, and none of the three may take the
  # caller down: this runs while the user is holding the power button and
  # expecting a dark screen.
  defp run(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    thrown -> {:error, {:throw, thrown}}
  end

  defp warn(step, verb, reason),
    do: Logger.warning("[low_power] #{name(step)} could not #{verb}: #{inspect(reason)}")

  defp name(step), do: step |> Module.split() |> List.last() |> String.downcase()
end
