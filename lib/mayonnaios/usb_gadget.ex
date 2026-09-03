defmodule MayonnaiOS.USBGadget do
  @moduledoc """
  Implements CDC-ECM USB gadget setup on the type-C port, intended to create
  the device interface `usb0`.

  This is **Untested** as a cable-access path on the RG40XXV: configfs setup and
  VintageNetDirect configuration are implemented, but the type-C connection
  has not been observed enumerating on a host. Do not rely on it for SSH or
  recovery. WiFi is currently the only verified remote access; because UART0
  is on internal test pads, firmware without working initial WiFi credentials
  may need its card reflashed.

  The inherited device tree sets the type-C port to `dr_mode = "peripheral"`,
  and the kernel includes CONFIG_USB_CONFIGFS, ECM, and the musb sunxi UDC.
  This module populates configfs and binds the available UDC. If enumeration
  is later verified and `usb0` appears, VintageNetDirect (see
  `config/target.exs`) assigns the direct-link network and serves DHCP to the
  host.

  CDC-ECM is selected rather than RNDIS because macOS and Linux support ECM
  natively. That host support does not establish that this handheld's port
  enumerates.
  """

  require Logger

  @configfs "/sys/kernel/config"
  @gadget "/sys/kernel/config/usb_gadget/nerves"
  @udc_class "/sys/class/udc"

  # Linux Foundation's vendor ID with the multifunction composite gadget
  # product ID. These are the conventional IDs for a gadget that is not
  # claiming a real vendor's identity.
  @vendor_id "0x1d6b"
  @product_id "0x0104"

  @doc false
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&__MODULE__.setup/0]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Create and bind the gadget. Safe to call more than once.
  """
  @spec setup() :: :ok
  def setup() do
    case configure() do
      :ok ->
        Logger.info("[usb_gadget] bound, usb0 should now exist")

      {:already_bound, udc} ->
        Logger.info("[usb_gadget] already bound to #{udc}")

      {:error, reason} ->
        # Never take the supervision tree down over this. A device that cannot
        # bring up the cable interface should still boot and try WiFi.
        Logger.warning("[usb_gadget] not configured: #{inspect(reason)}")
    end

    :ok
  end

  defp configure() do
    with :ok <- mount_configfs(),
         {:ok, udc} <- find_udc(),
         :unbound <- binding_state(),
         :ok <- build_gadget(),
         :ok <- write("UDC", udc) do
      :ok
    else
      {:bound, udc} -> {:already_bound, udc}
      {:error, reason} -> {:error, reason}
    end
  end

  # configfs is not in the Nerves skeleton's fstab, so it is normally unmounted.
  defp mount_configfs() do
    if File.dir?(Path.join(@configfs, "usb_gadget")) do
      :ok
    else
      _ = File.mkdir_p(@configfs)

      case System.cmd("mount", ["-t", "configfs", "none", @configfs], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {output, code} ->
          # A concurrent mount is fine; anything else is not.
          if File.dir?(Path.join(@configfs, "usb_gadget")),
            do: :ok,
            else: {:error, {:configfs_mount_failed, code, String.trim(output)}}
      end
    end
  end

  defp find_udc() do
    case File.ls(@udc_class) do
      {:ok, [udc | _]} -> {:ok, udc}
      {:ok, []} -> {:error, :no_udc_available}
      {:error, reason} -> {:error, {:udc_list_failed, reason}}
    end
  end

  defp binding_state() do
    case File.read(Path.join(@gadget, "UDC")) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> :unbound
          udc -> {:bound, udc}
        end

      {:error, _} ->
        :unbound
    end
  end

  defp build_gadget() do
    {dev_addr, host_addr} = mac_addresses()

    steps = [
      {:mkdir, ""},
      {:write, "idVendor", @vendor_id},
      {:write, "idProduct", @product_id},
      {:write, "bcdDevice", "0x0100"},
      {:write, "bcdUSB", "0x0200"},
      {:mkdir, "strings/0x409"},
      {:write, "strings/0x409/manufacturer", "Nerves"},
      {:write, "strings/0x409/product", "mayonnaios"},
      {:write, "strings/0x409/serialnumber", serial_number()},
      {:mkdir, "functions/ecm.usb0"},
      {:write, "functions/ecm.usb0/dev_addr", dev_addr},
      {:write, "functions/ecm.usb0/host_addr", host_addr},
      {:mkdir, "configs/c.1/strings/0x409"},
      {:write, "configs/c.1/strings/0x409/configuration", "CDC ECM"},
      {:write, "configs/c.1/MaxPower", "250"},
      {:link, "functions/ecm.usb0", "configs/c.1/ecm.usb0"}
    ]

    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case run_step(step) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp run_step({:mkdir, rel}) do
    case File.mkdir_p(Path.join(@gadget, rel)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, rel, reason}}
    end
  end

  defp run_step({:write, rel, value}), do: write(rel, value)

  defp run_step({:link, target, rel}) do
    case File.ln_s(Path.join(@gadget, target), Path.join(@gadget, rel)) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:symlink, rel, reason}}
    end
  end

  defp write(rel, value) do
    case File.write(Path.join(@gadget, rel), value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write, rel, reason}}
    end
  end

  # Derive stable MAC addresses from the serial number so the host sees the same
  # interface across reboots instead of a new one each time. 0x02 and 0x06 are
  # unicast, locally administered.
  defp mac_addresses() do
    <<a, b, c, d, e, _rest::binary>> = :crypto.hash(:sha256, serial_number())
    {format_mac(0x02, [a, b, c, d, e]), format_mac(0x06, [a, b, c, d, e])}
  end

  defp format_mac(first, rest) do
    [first | rest]
    |> Enum.map_join(":", &Base.encode16(<<&1>>, case: :lower))
  end

  defp serial_number() do
    Nerves.Runtime.serial_number()
  rescue
    _ -> "unknown"
  end
end
