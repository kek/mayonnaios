defmodule ScenicRg40xxv.Diagnostics do
  @moduledoc """
  Live readings for the hardware that cannot be verified from a desk.

  Everything in the verification plan splits into two kinds. Some of it can be
  answered over SSH by reading sysfs, and has been: the battery reports a
  capacity that moves, all four thermal zones rise under load, the RTC holds a
  sane date. The rest needs a person holding the device -- someone has to pull
  the charger, press a volume button, plug in headphones.

  This process exists for the second kind. It keeps a current picture of the
  board so `ScenicRg40xxv.Scene.Diagnostics` can put it on the panel, and the
  check becomes "press the button and watch the number change" rather than a
  session over the network.

  ## Why it owns two input devices

  The gamepad is `event0` and `ScenicRg40xxv.Launcher` has it. `InputEvent`
  delivers to whichever process opened the device, so the two devices nobody
  else uses are opened here:

      event1  gpio-keys-volume            KEY_VOLUMEDOWN 114, KEY_VOLUMEUP 115
      event2  H616 Audio Codec Headphone  SW_HEADPHONE_INSERT

  Both codes were read from `/sys/firmware/devicetree/base/gpio-keys-volume/`
  on the device rather than assumed. They happen to be the obvious ones this
  time; the gamepad's were not, which is the reason for looking.

  ## Switch state at startup

  A switch only sends an event when it *changes*, so a jack already plugged in
  when this starts would read as absent until someone unplugged it. `evtest
  --query` reports the current level, and exits 10 when the switch is set.
  """

  use GenServer
  require Logger

  @battery "/sys/class/power_supply/axp20x-battery"
  @usb "/sys/class/power_supply/axp20x-usb"
  @volume_device "/dev/input/event1"
  @jack_device "/dev/input/event2"

  # The blob whose absence stops Bluetooth from initialising. See the long
  # comment against BR2_PACKAGE_LINUX_FIRMWARE_RTL_87XX_BT in nerves_defconfig.
  @bt_config "/lib/firmware/rtl_bt/rtl8821cs_config.bin"

  @poll_ms 1_000
  # amixer means spawning a process, so it runs on its own slower clock.
  @audio_every 5

  defstruct battery: %{},
            thermal: [],
            rtc: %{},
            bluetooth: %{},
            audio: %{},
            volume: %{last: nil, up: 0, down: 0},
            jack: %{inserted: nil, changes: 0},
            ticks: 0

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The most recent reading of everything, as a struct. Cheap: it is cached.
  """
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl GenServer
  def init(_opts) do
    open(@volume_device)
    open(@jack_device)

    state =
      %__MODULE__{}
      |> Map.put(:jack, %{inserted: query_jack(), changes: 0})
      |> poll()

    :timer.send_interval(@poll_ms, :poll)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_info(:poll, state), do: {:noreply, poll(%{state | ticks: state.ticks + 1})}

  def handle_info({:input_event, @volume_device, events}, state) do
    volume =
      Enum.reduce(events, state.volume, fn
        {:ev_key, :key_volumeup, 1}, v -> %{v | last: :up, up: v.up + 1}
        {:ev_key, :key_volumedown, 1}, v -> %{v | last: :down, down: v.down + 1}
        _, v -> v
      end)

    {:noreply, %{state | volume: volume}}
  end

  def handle_info({:input_event, @jack_device, events}, state) do
    jack =
      Enum.reduce(events, state.jack, fn
        {:ev_sw, :sw_headphone_insert, value}, j ->
          %{j | inserted: value == 1, changes: j.changes + 1}

        _, j ->
          j
      end)

    {:noreply, %{state | jack: jack}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- reading ---------------------------------------------------------------

  defp poll(state) do
    audio = if rem(state.ticks, @audio_every) == 0, do: read_audio(), else: state.audio

    %{
      state
      | battery: read_battery(),
        thermal: read_thermal(),
        rtc: read_rtc(),
        bluetooth: read_bluetooth(),
        audio: audio
    }
  end

  defp read_battery do
    %{
      capacity: read_int("#{@battery}/capacity"),
      status: read_str("#{@battery}/status"),
      # Microvolts and microamps; divided for display, not here.
      voltage_uv: read_int("#{@battery}/voltage_now"),
      current_ua: read_int("#{@battery}/current_now"),
      health: read_str("#{@battery}/health"),
      usb_online: read_int("#{@usb}/online") == 1
    }
  end

  defp read_thermal do
    "/sys/class/thermal/thermal_zone*"
    |> Path.wildcard()
    |> Enum.map(fn zone ->
      {read_str("#{zone}/type") || Path.basename(zone), read_int("#{zone}/temp")}
    end)
    |> Enum.sort()
  end

  defp read_rtc do
    %{
      name: read_str("/sys/class/rtc/rtc0/name"),
      date: read_str("/sys/class/rtc/rtc0/date"),
      time: read_str("/sys/class/rtc/rtc0/time"),
      # 1 means the kernel used this RTC to set the clock at boot, which is
      # the only part NTP cannot fake later.
      hctosys: read_int("/sys/class/rtc/rtc0/hctosys") == 1
    }
  end

  defp read_bluetooth do
    # An hci0 directory is not evidence of a working controller: it appears
    # before setup runs, and stays after setup fails. The address attribute is
    # what distinguishes the two, so both are reported.
    %{
      hci0: File.dir?("/sys/class/bluetooth/hci0"),
      address: read_str("/sys/class/bluetooth/hci0/address"),
      config_firmware: File.exists?(@bt_config)
    }
  end

  # Controls, and whether each is actually audible. Reported, never changed:
  # unmuting is a decision for whoever is holding the device.
  defp read_audio do
    case cmd("amixer", ["scontents"]) do
      {:ok, out} -> %{card: File.exists?("/dev/snd/pcmC0D0p"), controls: parse_amixer(out)}
      :error -> %{card: File.exists?("/dev/snd/pcmC0D0p"), controls: []}
    end
  end

  # amixer scontents is a flat block per control. Only the name, the first
  # percentage and the first [on]/[off] matter here.
  defp parse_amixer(out) do
    out
    |> String.split(~r/\nSimple mixer control /, trim: true)
    |> Enum.map(fn block ->
      name =
        case Regex.run(~r/'([^']+)',\d+/, block) do
          [_, n] -> n
          _ -> nil
        end

      on =
        case Regex.run(~r/\[(on|off)\]/, block) do
          [_, "on"] -> true
          [_, "off"] -> false
          _ -> nil
        end

      percent =
        case Regex.run(~r/\[(\d+)%\]/, block) do
          [_, p] -> String.to_integer(p)
          _ -> nil
        end

      %{name: name, on: on, percent: percent}
    end)
    |> Enum.filter(& &1.name)
  end

  # -- helpers ---------------------------------------------------------------

  defp open(device) do
    case InputEvent.start_link(device) do
      {:ok, _pid} ->
        :ok

      other ->
        # Losing one of these costs a diagnostic, not the boot.
        Logger.warning("[diagnostics] #{device} unavailable: #{inspect(other)}")
        :error
    end
  end

  # evtest exits 10 when the switch is set, 0 when it is not.
  defp query_jack do
    case cmd_status("evtest", ["--query", @jack_device, "EV_SW", "SW_HEADPHONE_INSERT"]) do
      {:ok, 10} -> true
      {:ok, 0} -> false
      _ -> nil
    end
  end

  defp read_str(path) do
    case File.read(path) do
      {:ok, v} -> String.trim(v)
      _ -> nil
    end
  end

  defp read_int(path) do
    with v when is_binary(v) <- read_str(path),
         {n, _} <- Integer.parse(v) do
      n
    else
      _ -> nil
    end
  end

  defp cmd(exe, args) do
    case cmd_out(exe, args) do
      {:ok, out, 0} -> {:ok, out}
      _ -> :error
    end
  end

  defp cmd_status(exe, args) do
    case cmd_out(exe, args) do
      {:ok, _out, status} -> {:ok, status}
      _ -> :error
    end
  end

  defp cmd_out(exe, args) do
    {out, status} = System.cmd(exe, args, stderr_to_stdout: true)
    {:ok, out, status}
  rescue
    # Not every tool is in the image -- hwclock and hciconfig are not.
    _ -> :error
  end
end
