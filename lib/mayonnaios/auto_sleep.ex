defmodule MayonnaiOS.AutoSleep do
  @moduledoc """
  The persisted switch for automatic idle sleep.

  Manual sleep remains available through the power key and the System menu.
  This switch only decides whether an idle launcher arms its three-minute
  timer, so disabling it keeps a development device reachable over SSH.

  The choice lives on the writable application partition rather than in the
  firmware or VM state, and therefore survives both a reboot and a firmware
  update. Unknown or unreadable contents fall back to configuration; a torn
  setting must never silently change the device's policy.
  """

  @default_path "/root/.config/mayonnaios/auto_sleep"

  @doc "Where the persisted switch is stored. Injectable for host tests."
  @spec path() :: String.t()
  def path, do: Application.get_env(:mayonnaios, :auto_sleep_path, @default_path)

  @doc "Whether inactivity may put the launcher to sleep. Defaults to on."
  @spec enabled?() :: boolean()
  def enabled? do
    case File.read(path()) do
      {:ok, value} -> decode(value, configured_default())
      {:error, _reason} -> configured_default()
    end
  end

  @doc "Persist a new automatic-sleep policy."
  @spec set(boolean()) :: :ok | {:error, File.posix()}
  def set(enabled) when is_boolean(enabled) do
    path = path()
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, if(enabled, do: "enabled\n", else: "disabled\n")),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temporary)
        error
    end
  end

  @doc "Flip and persist the policy, returning its new value."
  @spec toggle() :: {:ok, boolean()} | {:error, File.posix()}
  def toggle do
    enabled = not enabled?()

    case set(enabled) do
      :ok -> {:ok, enabled}
      {:error, _reason} = error -> error
    end
  end

  defp configured_default, do: Application.get_env(:mayonnaios, :auto_sleep, true)

  defp decode(value, fallback) do
    case String.trim(value) do
      "enabled" -> true
      "disabled" -> false
      _other -> fallback
    end
  end
end
