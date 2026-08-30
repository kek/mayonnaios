defmodule MayonnaiOS.BootDiagnostics do
  @moduledoc """
  Writes a boot report into unallocated space on the MicroSD card so it can be
  read back from a host with `dd`.

  This is the one channel that works when the others do not, which is exactly
  when you need it. It has no dependency on the network coming up, on the
  panel, or on the UI starting, and a UI that takes the framebuffer and then
  fails leaves nothing on screen to read.

  It works because the boot chain demonstrably runs by this point: rootfs A
  mounts and the app data partition gets formatted, so the raw block device is
  writable.

  On by default. It writes to the card on every boot, so it is switchable
  without editing the supervision tree:

      config :mayonnaios, boot_diagnostics: false

  Card layout in 512-byte blocks (see `fwup_include/fwup-common.conf`):

      16     .. ~1421   SPL + BL31 + U-Boot
      8192   .. 8448    U-Boot environment
      8448   .. 43008   UNALLOCATED -- 17MB, we use a slice of this
      43008  ..         rootfs A

  Writing here is deliberately preferred over the U-Boot environment: a bad
  write to the environment block would stop the device booting at all, whereas
  this region is untouched by fwup except during a full re-flash.

  Two slots are written at different elapsed times so that an early report
  survives even if the device wedges before the later one.
  """

  require Logger

  @device "/dev/mmcblk0"
  @block_size 512

  @slot_blocks 256
  @slots [10_240, 10_496]
  @magic "NERVESDBG1"

  # Neighbours, for the bounds check below.
  @env_end_block 8_448
  @rootfs_a_block 43_008

  # The first checkpoint is early, to catch a boot that dies soon after
  # userland starts. The second allows time for WiFi association and DHCP.
  @checkpoints [15_000, 75_000]

  @doc false
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&__MODULE__.run/0]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Collect and write a report at each checkpoint.
  """
  @spec run() :: :ok
  def run() do
    @checkpoints
    |> Enum.zip(@slots)
    |> Enum.each(fn {delay, slot} ->
      Process.sleep(delay)

      case write_slot(slot, report(delay)) do
        :ok -> Logger.info("[boot_diag] wrote report to block #{slot}")
        {:error, reason} -> Logger.warning("[boot_diag] write failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc """
  The report text. Exposed so it can be read over IEx once there is a way in.
  """
  @spec report(non_neg_integer()) :: iodata()
  def report(elapsed_ms \\ 0) do
    [
      "=== boot diagnostics @ #{elapsed_ms}ms ===\n",
      section("uptime", fn -> read_file("/proc/uptime") end),
      section("network interfaces (/sys/class/net)", fn -> ls("/sys/class/net") end),
      section("loaded modules (/proc/modules)", &modules/0),
      section("USB device controllers (/sys/class/udc)", fn -> ls("/sys/class/udc") end),
      section("usb gadget bound to", fn ->
        read_file("/sys/kernel/config/usb_gadget/nerves/UDC")
      end),
      section("wpa_supplicant running", fn -> pgrep("wpa_supplicant") end),
      section("LEDs (/sys/class/leds)", fn -> ls("/sys/class/leds") end),
      section("LED triggers in effect", &led_triggers/0),
      section("sshd listening on 22", &ssh_listening/0),
      section("vintage_net interfaces", &vintage_net_interfaces/0),
      section("vintage_net properties", &vintage_net_properties/0),
      section("log", &log_dump/0)
    ]
  end

  # Each section is isolated so that one failing collector cannot lose the
  # whole report.
  defp section(title, fun) do
    body =
      try do
        fun.()
      rescue
        e -> "!! raised: #{inspect(e)}"
      catch
        kind, value -> "!! #{kind}: #{inspect(value)}"
      end

    ["\n--- ", title, " ---\n", body, "\n"]
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, reason} -> "(unreadable: #{inspect(reason)})"
    end
  end

  defp ls(path) do
    case File.ls(path) do
      {:ok, []} -> "(empty)"
      {:ok, entries} -> Enum.join(Enum.sort(entries), " ")
      {:error, reason} -> "(unreadable: #{inspect(reason)})"
    end
  end

  # Only the wireless and USB modules matter here, and the full list is long.
  defp modules() do
    case File.read("/proc/modules") do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.match?(&1, ~r/rtw|mac80211|cfg80211|usb|ecm|libcomposite/))
        |> case do
          [] -> "(no wireless or usb modules loaded -- this would explain no wlan0)"
          lines -> Enum.join(lines, "\n")
        end

      {:error, reason} ->
        "(unreadable: #{inspect(reason)})"
    end
  end

  defp pgrep(name) do
    case System.cmd(
           "sh",
           ["-c", "ps | grep -c '[#{String.first(name)}]#{String.slice(name, 1..-1//1)}'"],
           stderr_to_stdout: true
         ) do
      {out, _} -> String.trim(out) <> " matching process(es)"
    end
  end

  # Read /proc/net/tcp directly rather than shelling out: this image has no
  # netstat, and a missing binary silently looked like "not listening".
  # Fields are "sl local_address rem_address st ...", with the address as
  # hex ip:port and st == 0A meaning LISTEN. Port 22 is 0x0016.
  defp ssh_listening() do
    listening =
      ["/proc/net/tcp", "/proc/net/tcp6"]
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, contents} -> String.split(contents, "\n", trim: true)
          {:error, _} -> []
        end
      end)
      |> Enum.map(&String.split/1)
      |> Enum.filter(fn
        [_sl, local, _rem, "0A" | _] -> String.ends_with?(local, ":0016")
        _ -> false
      end)

    case listening do
      [] -> "NOT LISTENING (no socket in LISTEN state on port 22)"
      sockets -> "LISTENING (#{length(sockets)} socket(s))"
    end
  end

  # The active trigger is the one in brackets, e.g. "none [timer] heartbeat".
  # Confirms whether MayonnaiOS.Led actually took effect.
  defp led_triggers() do
    case File.ls("/sys/class/leds") do
      {:ok, []} ->
        "(no LEDs)"

      {:ok, leds} ->
        Enum.map_join(leds, "\n", fn led ->
          "#{led}: #{read_file(Path.join(["/sys/class/leds", led, "trigger"]))}"
        end)

      {:error, reason} ->
        "(unreadable: #{inspect(reason)})"
    end
  end

  # VintageNet is a target-only dependency, so it does not exist when this file
  # is compiled for :host. Calling through apply/3 keeps the host compile clean
  # instead of warning about an undefined module.
  defp vintage_net_interfaces() do
    if Code.ensure_loaded?(VintageNet) do
      inspect(apply(VintageNet, :all_interfaces, []))
    else
      "(VintageNet not loaded)"
    end
  end

  defp vintage_net_properties() do
    if Code.ensure_loaded?(VintageNet) do
      apply(VintageNet, :get_by_prefix, [["interface"]])
      |> Enum.map_join("\n", fn {path, value} ->
        "#{Enum.join(path, ".")} = #{inspect(value, limit: 12)}"
      end)
    else
      "(VintageNet not loaded)"
    end
  end

  defp log_dump() do
    RingLogger.get()
    |> Enum.map_join("\n", &format_log_entry/1)
  end

  defp format_log_entry(%{level: level, message: message, timestamp: timestamp}) do
    "#{format_timestamp(timestamp)} [#{level}] #{stringify(message)}"
  end

  defp format_log_entry(other), do: inspect(other)

  defp format_timestamp({{_y, _mo, _d}, {h, m, s, ms}}) do
    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [h, m, s, ms]) |> IO.iodata_to_binary()
  end

  defp format_timestamp(other), do: inspect(other)

  defp stringify(message) when is_binary(message), do: message

  defp stringify(message) do
    IO.iodata_to_binary(message)
  rescue
    _ -> inspect(message)
  end

  # --- writing -------------------------------------------------------------

  defp write_slot(slot, report) do
    with :ok <- check_bounds(slot) do
      payload = build_payload(report)

      case File.open(@device, [:write, :binary, :raw]) do
        {:ok, fd} ->
          result =
            with {:ok, _} <- :file.position(fd, slot * @block_size) do
              :file.write(fd, payload)
            end

          _ = :file.sync(fd)
          _ = File.close(fd)
          result

        {:error, reason} ->
          {:error, {:open_failed, reason}}
      end
    end
  end

  # Refuse to write anywhere that could damage the bootloader, the environment
  # or a rootfs, however this module is called.
  defp check_bounds(slot) do
    if slot >= @env_end_block and slot + @slot_blocks <= @rootfs_a_block do
      :ok
    else
      {:error, {:refusing_unsafe_offset, slot}}
    end
  end

  defp build_payload(report) do
    body = IO.iodata_to_binary(report)
    max_body = @slot_blocks * @block_size - 64

    body =
      if byte_size(body) > max_body do
        binary_part(body, 0, max_body - 24) <> "\n...[truncated]...\n"
      else
        body
      end

    header = "#{@magic} len=#{byte_size(body)}\n"
    blob = header <> body

    # Block devices want whole blocks.
    padding = @slot_blocks * @block_size - byte_size(blob)
    blob <> :binary.copy(<<0>>, padding)
  end
end
