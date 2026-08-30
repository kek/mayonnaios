defmodule MayonnaiOS.LowPower.Cpus do
  @moduledoc """
  Takes every core but the first offline, and puts it back.

  Four Cortex-A53s stay online while the panel is dark, and on this board they
  stay there at whatever frequency and voltage U-Boot left them at, because
  `/sys/devices/system/cpu/cpufreq` is empty and there is no cpuidle driver to
  put an unused one anywhere deeper than WFI. Offlining is the only lever that
  reaches them.

  `/sys/devices/system/cpu/cpuN/online` is the interface: `0` calls PSCI
  `CPU_OFF` through `psci_cpu_disable`, `1` brings it back with `CPU_ON`. Both
  are implemented by ATF's native ops for this platform -- unlike
  `SYSTEM_SUSPEND`, which is not, and which is why there is no suspend to use
  instead. `CPU_ON` is also how all four came up at boot, so the path is at
  least exercised in one direction on every boot of this device.

  `cpu0` is never touched. Some arm64 kernels omit its `online` file and this
  board's kernel exposes one, so absence is not the guard: the directory name
  is filtered explicitly. Writing `0` there can migrate the boot CPU and leave
  whichever core happens to be last online, which is not the stable baseline
  this module promises.

  ## The BEAM keeps all four schedulers

  Deliberately. `:erlang.system_flag(:schedulers_online, 1)` is the obvious
  companion to this and is not done, because the BEAM does not observe CPU
  hotplug: with three cores gone, Linux simply migrates all four schedulers
  onto `cpu0` and they timeshare there. That costs a little scheduling
  overhead and nothing in power, and it leaves one fewer piece of global VM
  state to put back wrongly on the way out.

  ## On a laptop

  `/sys/devices/system/cpu` on a development machine has no `cpuN/online`
  files that Erlang may write, so `enter/0` finds nothing and returns `:noop`.
  Tests point `:cpu_dir` at a temp tree and read back what landed, the same
  trick `MayonnaiOS.Led` and `MayonnaiOS.Sleep` use.
  """

  require Logger

  @default_dir "/sys/devices/system/cpu"

  @offline "0"

  @doc """
  The directory holding `cpuN/online`.

  From `config :mayonnaios, :cpu_dir`, defaulting to sysfs.
  """
  @spec dir() :: String.t()
  def dir, do: Application.get_env(:mayonnaios, :cpu_dir, @default_dir)

  @doc """
  Offline every core that has an `online` file, remembering what it read.

  Returns the values to put back, or `:noop` when there are none -- which is
  every machine that is not this handheld, and would also be a kernel built
  without `CONFIG_HOTPLUG_CPU`.
  """
  @spec enter() :: [{String.t(), String.t()}] | :noop
  def enter do
    case online_files() do
      [] ->
        :noop

      paths ->
        # Read before writing, so the restore is what was actually there
        # rather than an assumed "1". A core that was already offline for
        # some other reason stays offline on the way out.
        paths
        |> Enum.map(fn path -> {path, File.read(path)} end)
        |> Enum.flat_map(fn
          {path, {:ok, was}} ->
            case File.write(path, @offline) do
              :ok ->
                [{path, String.trim(was)}]

              {:error, reason} ->
                # Not fatal, and not silent: one core that refuses to go is a
                # smaller problem than the three that did, and the undo list
                # is what decides whether it is asked to come back.
                Logger.warning("[low_power] #{path} would not go offline: #{inspect(reason)}")
                []
            end

          {path, {:error, reason}} ->
            Logger.warning("[low_power] #{path} unreadable: #{inspect(reason)}")
            []
        end)
    end
  end

  @doc """
  Put each core back to the value it had, one failure at a time.
  """
  @spec leave([{String.t(), String.t()}]) :: :ok
  def leave(previous) do
    Enum.each(previous, fn {path, was} ->
      case File.write(path, was) do
        :ok ->
          :ok

        {:error, reason} ->
          # The one failure in this module that really costs something: a core
          # that does not come back is gone until the next reboot.
          Logger.warning("[low_power] #{path} would not come back online: #{inspect(reason)}")
      end
    end)
  end

  # Sorted, so the order cores go down and come back is the order they are
  # numbered rather than whatever the directory listing happened to give.
  defp online_files do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(~r/^cpu[1-9]\d*$/, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join([dir(), &1, "online"]))
        |> Enum.filter(&File.regular?/1)

      {:error, _reason} ->
        []
    end
  end
end
