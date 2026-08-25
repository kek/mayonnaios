defmodule MayonnaiOS.Bluetooth.Serdev do
  @moduledoc """
  Bringing hci0 back when the Realtek part did not appear at boot.

  The Bluetooth half of the RTL8821CS is a UART part rather than a USB one.
  The device tree hangs a `bluetooth` node off `serial@5000400`, so the kernel
  binds `hci_uart_h5` to a serdev child named `serial0-0` -- which is why this
  image has no `/dev/ttyS1` and needs no `btattach`. See
  `MayonnaiOS.Bluetooth.HCISocket` for what being serdev-bound buys.

  That bind is what produces hci0, and it ordinarily happens on its own about
  eleven seconds into the boot:

      Bluetooth: hci0: RTL: examining hci_ver=08 ... lmp_subver=8821
      Bluetooth: hci0: RTL: loading rtl_bt/rtl8821cs_fw.bin
      Bluetooth: hci0: RTL: fw version 0x75b8f098

  ## The failure this module exists for

  Sometimes it does not happen. Observed on this device on 2026-08-25: the
  driver was bound -- `/sys/bus/serial/drivers/hci_uart_h5/serial0-0` was
  there, and so was the serdev child -- and yet `/sys/class/bluetooth` was
  empty, hci0 had never been registered, and `dmesg` for the entire boot
  carried not one RTL line. No probe error, no command timeout, no H5 resync:
  nothing to read anywhere. Every Bluetooth app then fails to start with
  `:enodev`, which on the couch is a menu entry that does nothing at all.

  Writing the device name to the driver's `unbind` and then to its `bind` is
  what fixes it, and the firmware download that should have happened at boot
  happens then instead. Verified on the device in both directions: unbinding
  reproduces `:enodev` exactly, and rebinding brings hci0 back with a full
  `MayonnaiOS.Diagnostics.probe_bluetooth/0` -- Realtek, core spec 4.2 --
  answering behind it. A reboot fixes it too, and that is the part worth
  knowing: the fault is intermittent, so a boot that works proves nothing
  about the next one.

  Why the bring-up silently no-ops is still unexplained. This module is the
  recovery, not the diagnosis, and it says so rather than implying the bug is
  understood.

  ## Why this is not a retry loop

  `MayonnaiOS.Controller`'s moduledoc says that nothing retries, and that
  still holds. This runs once, when a person has pressed A on a Bluetooth app
  and the open came back `:enodev`. It is the way out of a state the device
  otherwise cannot leave without a reboot -- not a background poll of a radio,
  which is how a handheld ends up with a flat battery and no explanation.
  """

  require Logger

  @driver "/sys/bus/serial/drivers/hci_uart_h5"
  @device "serial0-0"
  @hci0 "/sys/class/bluetooth/hci0"

  # How long to wait for hci0 after the bind, and how often to look.
  # Registration is the first thing the probe does rather than the last, so
  # this is generous: on the device the first RTL line follows the write by
  # well under a tenth of a second.
  @appear_timeout 2_000
  @poll 50

  @doc "Whether hci0 exists right now."
  @spec present?() :: boolean()
  def present?, do: File.dir?(@hci0)

  @doc """
  Rebind the Bluetooth serdev, and wait for hci0 to appear.

  `:ok` when hci0 is there -- including when it was there all along and
  nothing had to be done.

  Present is not the same as ready. The firmware download runs *after*
  registration and holds `HCI_SETUP` while it does, so a user-channel bind
  answers `:ebusy` for about another second afterwards. A caller is expected
  to wait that out; `MayonnaiOS.Bluetooth.Host` is the one that does, and its
  `open_when_ready/2` is where the waiting lives.
  """
  @spec revive() :: :ok | {:error, term()}
  def revive do
    if present?(), do: :ok, else: rebind()
  end

  defp rebind do
    Logger.info("[serdev] no hci0; rebinding #{@device} on #{Path.basename(@driver)}")

    # A failed unbind is not a reason to stop. If the driver is already
    # detached there is nothing to release and the bind below is the whole
    # job. It is logged rather than dropped, because "was not bound" and the
    # observed failure -- bound, with no hci0 behind it -- are different
    # faults, and this log line is the only place that difference shows.
    case write("unbind") do
      :ok -> :ok
      {:error, reason} -> Logger.info("[serdev] nothing to unbind (#{inspect(reason)})")
    end

    case write("bind") do
      :ok ->
        await(@appear_timeout)

      {:error, reason} = error ->
        Logger.error("[serdev] bind #{@device}: #{inspect(reason)}")
        error
    end
  end

  # Deliberately quiet: the two call sites above disagree about what a failure
  # means -- one is routine and one is the end of the road -- so the level and
  # the wording belong to them rather than to here.
  defp write(action), do: File.write(Path.join(@driver, action), @device)

  # Polled rather than watched: sysfs offers nothing to select on, this
  # happens once per button press, and the whole wait is two seconds at the
  # outside.
  defp await(remaining) when remaining <= 0 do
    Logger.error("[serdev] hci0 did not appear within #{@appear_timeout} ms of the bind")
    {:error, :enodev}
  end

  defp await(remaining) do
    if present?() do
      Logger.info("[serdev] hci0 is back")
      :ok
    else
      Process.sleep(@poll)
      await(remaining - @poll)
    end
  end
end
