defmodule MayonnaiOS.LowPower.Governor do
  @moduledoc """
  Puts every cpufreq policy on `powersave`, and back on what it was.

  This one does nothing on the firmware it was written against, and that is
  worth stating first: `/sys/devices/system/cpu/cpufreq` is **empty** on this
  board. Not a policy pinned to a single operating point -- no policy at all,
  and so also no cooling device, which is why `/sys/class/thermal` lists four
  zones with a `step_wise` governor and nothing to throttle with.

  The cause is one character in the system repo. The device tree is ready:
  `opp-table-cpu` is `allwinner,sun50i-h616-operating-points`, `cpu@0` carries
  both `operating-points-v2` and `cpu-supply`, and the speed-grade eFuse is
  present as `sunxi-sid0`. That Allwinner-specific compatible is the reason
  `CONFIG_CPUFREQ_DT=y` is not enough on its own: `cpufreq-dt-platdev.c` binds
  plain `operating-points-v2` tables, while `sun50i-cpufreq-nvmem.c` is what
  reads the grade, sets `opp-supported-hw` and only then registers the
  cpufreq-dt device. It is `=m`, and this system has no initramfs and
  modprobes nothing, so the module ships on the device and has never loaded.
  `kek/nerves_system_rg40xxv#6` makes it `=y`.

  So this module is written now and no-ops now. When that lands, twelve
  operating points from 480 MHz to 1.512 GHz appear with a voltage rail behind
  them, and a dark panel stops costing the top one.

  ## Why remember rather than assume

  `leave/1` writes back the string it read, not a hardcoded `ondemand`. The
  default governor is whatever Kconfig's choice lands on, a future config may
  move it, and a person may have set `userspace` from IEx to pin a frequency;
  restoring a guess would quietly undo any of those. Reading first costs one
  file read per policy.

  A write that fails is logged and contributes no undo entry, so `leave/1` is
  never asked to restore a policy that was never changed.
  """

  require Logger

  @default_dir "/sys/devices/system/cpu/cpufreq"

  @powersave "powersave"

  @doc """
  The cpufreq directory holding `policyN/scaling_governor`.

  From `config :mayonnaios, :cpufreq_dir`, defaulting to sysfs.
  """
  @spec dir() :: String.t()
  def dir, do: Application.get_env(:mayonnaios, :cpufreq_dir, @default_dir)

  @doc """
  Set `powersave` everywhere, remembering what each policy had.

  `:noop` when there are no policies, which is this board today and every
  development laptop.
  """
  @spec enter() :: [{String.t(), String.t()}] | :noop
  def enter do
    case governor_files() do
      [] ->
        :noop

      paths ->
        paths
        |> Enum.flat_map(fn path ->
          with {:ok, was} <- File.read(path),
               :ok <- File.write(path, @powersave) do
            [{path, String.trim(was)}]
          else
            {:error, reason} ->
              # EINVAL here means the governor is not registered -- it is
              # CONFIG_CPU_FREQ_GOV_POWERSAVE=m and unloaded -- which is a
              # different mistake in a different file from an absent policy,
              # and is why this says which path and what the kernel said.
              Logger.warning("[low_power] #{path} would not take powersave: #{inspect(reason)}")
              []
          end
        end)
        |> case do
          [] -> :noop
          changed -> changed
        end
    end
  end

  @doc """
  Put each policy back on the governor it named before.
  """
  @spec leave([{String.t(), String.t()}]) :: :ok
  def leave(previous) do
    Enum.each(previous, fn {path, was} ->
      case File.write(path, was) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[low_power] #{path} back to #{was}: #{inspect(reason)}")
      end
    end)
  end

  defp governor_files do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "policy"))
        |> Enum.sort()
        |> Enum.map(&Path.join([dir(), &1, "scaling_governor"]))
        |> Enum.filter(&File.regular?/1)

      {:error, _reason} ->
        []
    end
  end
end
