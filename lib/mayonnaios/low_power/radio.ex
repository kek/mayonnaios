defmodule MayonnaiOS.LowPower.Radio do
  @moduledoc """
  Takes WiFi down while the panel is dark, and brings the same configuration
  back.

  `wlan0` stays associated through the current sleep: `rtw88_8821cs` is bound
  on mmc1 and the link is up with the backlight off, which means the radio is
  still doing beacons, DTIM wakeups and whatever the SDIO host costs to keep
  clocked. A handheld with a dark screen has nothing to say on the network.

  ## VintageNet rather than rfkill or `ip link`

  Three ways to do this, and only one of them is reversible from inside this
  VM without a shell.

  `ip link set wlan0 down` needs an executable and would fight VintageNet,
  which would notice the interface leaving and try to bring it back.

  rfkill is the one this would otherwise use -- `/sys/class/rfkill/rfkillN/soft`
  is a plain sysfs write and would fit the pattern of every other step here --
  but `CONFIG_RFKILL` is `=m` on this system for the reason
  `nerves.fragment` records (Bluetooth cannot be built in while RFKILL is a
  module), and `/proc/modules` on firmware `3cc86f59` does not list it. There
  is no `/sys/class/rfkill` to write to.

  So: `VintageNet.deconfigure/2`, which stops `wpa_supplicant` and takes the
  link down through the same machinery that brought it up, and
  `VintageNet.configure/3` on the way back with the map read before it went.

  ## `persist: false`, on both calls

  This is the important detail. Both directions pass `persist: false`, so the
  saved configuration on the writable partition is never rewritten -- sleeping
  does not touch the network settings, and a device that loses power while
  asleep comes back with its WiFi credentials and joins the network on boot as
  usual. Persisting a deconfigure would turn one press of the power button
  into "the handheld forgot my WiFi".

  Note that `VintageNet.reset_to_defaults/1` is a different thing and is not
  used: it clears the persistence file on purpose.

  ## The SSH consequence

  An SSH session that arrived over `wlan0` ends when the device sleeps. That
  is the intended behaviour and is also a nuisance while debugging sleep
  itself, which is what `config :mayonnaios, :low_power_sleep` is for -- see
  `MayonnaiOS.LowPower.enabled?/0`. The USB gadget's `usb0` is untouched and
  remains a way in either way.

  ## On a laptop

  VintageNet is a target-only dependency, so on a development machine the
  module is not loaded and this is a `:noop`. That is the same
  `Code.ensure_loaded?/1` guard `MayonnaiOS.Status` and
  `MayonnaiOS.BootDiagnostics` use, and it is why nothing here is exercised by
  the host test suite beyond the guard itself.
  """

  require Logger

  @default_interface "wlan0"

  @doc """
  The interface to take down.

  From `config :mayonnaios, :wifi_interface`, defaulting to `wlan0`.
  """
  @spec interface() :: String.t()
  def interface, do: Application.get_env(:mayonnaios, :wifi_interface, @default_interface)

  @doc """
  Deconfigure the interface, returning the configuration to put back.

  `:noop` when VintageNet is not running, or when it has no configuration for
  this interface to remember.
  """
  @spec enter() :: {String.t(), map()} | :noop
  def enter do
    ifname = interface()

    with true <- available?(),
         {:ok, config} <- configuration(ifname),
         :ok <- apply_vintage_net(:deconfigure, [ifname, [persist: false]]) do
      {ifname, config}
    else
      false ->
        :noop

      {:error, reason} ->
        Logger.warning("[low_power] #{ifname} would not go down: #{inspect(reason)}")
        :noop
    end
  end

  @doc """
  Reapply the configuration this interface had, without persisting it.
  """
  @spec leave({String.t(), map()}) :: :ok
  def leave({ifname, config}) do
    case apply_vintage_net(:configure, [ifname, config, [persist: false]]) do
      :ok ->
        :ok

      {:error, reason} ->
        # Worth a warning rather than a debug line: the device is awake with
        # no WiFi, and the fix is a reboot or a reconfigure from IEx. The
        # saved configuration is intact, so a reboot is enough.
        Logger.warning("[low_power] #{ifname} did not come back up: #{inspect(reason)}")
    end
  end

  # `get_configuration/1` raises rather than returning an error when the
  # interface is unknown to VintageNet, which is an ordinary state on a board
  # with no WiFi configured and not something to report as a failure.
  defp configuration(ifname) do
    {:ok, apply_vintage_net(:get_configuration, [ifname])}
  rescue
    _ -> {:error, :not_configured}
  end

  defp available?, do: Code.ensure_loaded?(VintageNet)

  # Through apply/3 so that a host build, where VintageNet does not exist at
  # all, compiles without an undefined-module warning.
  defp apply_vintage_net(fun, args), do: apply(VintageNet, fun, args)
end
