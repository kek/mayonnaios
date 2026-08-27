defmodule MayonnaiOS.Diagnostics do
  @moduledoc """
  Live readings for the hardware that cannot be verified from a desk.

  Everything in the verification plan splits into two kinds. Some of it can be
  answered over SSH by reading sysfs, and has been: the battery reports a
  capacity that moves, all four thermal zones rise under load, the RTC holds a
  sane date. The rest needs a person holding the device -- someone has to pull
  the charger, press a volume button, plug in headphones.

  This process exists for the second kind. It keeps a current picture of the
  board so `MayonnaiOS.Scene.Diagnostics` can put it on the panel, and the
  check becomes "press the button and watch the number change" rather than a
  session over the network.

  ## Why it opens two input devices

  `MayonnaiOS.Launcher` has the gamepad and the power key. `InputEvent`
  delivers to whichever process opened the device, so the two devices the
  Launcher does not read are opened here, by name:

      gpio-keys-volume                 KEY_VOLUMEDOWN 114, KEY_VOLUMEUP 115
      H616 Audio Codec Headphone Jack  SW_HEADPHONE_INSERT

  Both codes were read from `/sys/firmware/devicetree/base/gpio-keys-volume/`
  on the device rather than assumed. They happen to be the obvious ones this
  time; the gamepad's were not, which is the reason for looking.

  No numbers in that table, because `/dev/input` numbering moves whenever a
  device is added to the board. `MayonnaiOS.Input` has the current numbering
  and the argument for not writing it down here.

  `MayonnaiOS.Volume` opens the rocker as well, and acts on it. Both readers
  get every event -- evdev is only exclusive to a reader that asks for
  `EVIOCGRAB`, and `InputEvent` does not unless told to -- so the press counts
  here stay a plain observation of the hardware while the mixer is somebody
  else's job. That split is deliberate; this process reports, it does not act.

  ## Switch state at startup

  A switch only sends an event when it *changes*, so a jack already plugged in
  when this starts would read as absent until someone unplugged it. `evtest
  --query` reports the current level, and exits 10 when the switch is set.

  ## The Bluetooth probe is manual, and stays manual for now

  `probe_bluetooth/0` talks to the controller over a raw HCI user channel; see
  `MayonnaiOS.Bluetooth.HCISocket`. It is not in `poll/1` and is not run at
  startup, for two reasons. The socket takes exclusive ownership of hci0 while
  it is open, so it is not something to do once a second in the background.
  And it has never been run on this device: the second `hci_dev_open` since
  boot is the one unverified step, so the first run should be a person over
  SSH watching what comes back, not a boot-time call whose failure looks like a
  broken boot.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Bluetooth.HCISocket

  # Looked up by name at startup, and by name only -- no numbered fallbacks.
  # A number reached when the name is missing is a different device: `event1`
  # is the analog stick and `event2` is the gamepad, so a fallback would count
  # volume presses on a device that has no keys and query a jack switch on one
  # that has no switch. See `MayonnaiOS.Input`.
  @volume_name "gpio-keys-volume"
  @jack_name "H616 Audio Codec Headphone Jack"

  # The blob whose absence stops Bluetooth from initialising. See the long
  # comment against BR2_PACKAGE_LINUX_FIRMWARE_RTL_87XX_BT in nerves_defconfig.
  @bt_config "/lib/firmware/rtl_bt/rtl8821cs_config.bin"

  # Panfrost publishes per-engine busy nanoseconds in fdinfo, but only once
  # profiling is switched on.
  @gpu "/sys/devices/platform/soc/1800000.gpu"

  @poll_ms 1_000
  # amixer means spawning a process, so it runs on its own slower clock.
  @audio_every 5

  defstruct battery: %{},
            thermal: [],
            rtc: %{},
            bluetooth: %{},
            audio: %{},
            gpu: %{client: nil, engines: %{}},
            volume: %{last: nil, up: 0, down: 0},
            jack: %{inserted: nil, changes: 0},
            gpu_prev: nil,
            rtl: {:error, "not read"},
            # Nothing has asked the controller anything yet, which is not the
            # same as having asked and got nothing. See probe_bluetooth/0.
            bt_probe: {:error, :not_run},
            ticks: 0

  @typedoc "One reading of everything this collector watches."
  @type t :: %__MODULE__{}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The most recent reading of everything, as a struct. Cheap: it is cached.
  """
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc """
  Ask the Bluetooth controller who it is, and remember the answer.

  Run this by hand, over SSH:

      iex> MayonnaiOS.Diagnostics.probe_bluetooth()
      {:ok, %{manufacturer: 93, manufacturer_name: "Realtek", ...}}

  Manufacturer 0x5D coming back is the first proof this project has that the
  controller answers, rather than that btrtl uploaded firmware to it once at
  boot -- which is all `rtl_status/0` can tell from the kernel log.

  The result is cached into the snapshot, so the diagnostics panel shows it
  afterwards. Running it again re-asks; hci0 is held only for the duration of
  the call, and it is released before this returns.

  It runs inside this GenServer on purpose. Whoever holds the socket owns
  hci0, so having one process that does it is the difference between "the
  probe is busy" and two IEx sessions racing for `:eusers`.
  """
  def probe_bluetooth(opts \\ []) do
    # Comfortably longer than the two 2 s HCI commands it may wait on, so a
    # controller that has stopped answering reports a timeout from the socket
    # rather than an exit from this call.
    GenServer.call(__MODULE__, {:probe_bluetooth, opts}, 30_000)
  end

  @impl GenServer
  def init(_opts) do
    open(@volume_name)
    open(@jack_name)

    # Without this the fdinfo engine counters stay at zero, which would look
    # exactly like a GPU doing nothing.
    File.write("#{@gpu}/profiling", "1")

    :timer.send_interval(@poll_ms, :poll)
    {:ok, %__MODULE__{}, {:continue, :first_reading}}
  end

  # The first reading is taken here rather than in `init/1` because of where
  # this process sits in the boot: the application supervisor starts its
  # children one at a time and waits for each `start_link` to return, so
  # anything done in `init/1` is time the games card, the cores, the web
  # server and the launcher spend not existing.
  #
  # And the first reading is the expensive one. It spawns four programs off a
  # read-only squashfs that has none of them in the page cache yet -- `evtest`
  # for the jack, `dmesg` for the Realtek firmware line (whose whole output is
  # then scanned), `amixer` for the mixer, `hwclock` where it exists -- which
  # is several hundred milliseconds of fork/exec in front of every child below
  # this one.
  #
  # `handle_continue` runs before this process handles any other message, so
  # `snapshot/0` still cannot observe the empty struct: a caller that asks
  # immediately waits for the reading rather than being told nothing. What
  # moves is only when the *rest of the supervision tree* is allowed to start.
  @impl GenServer
  def handle_continue(:first_reading, state) do
    state =
      state
      |> Map.put(:jack, %{inserted: query_jack(), changes: 0})
      |> Map.put(:rtl, rtl_status())
      |> poll()

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:probe_bluetooth, opts}, _from, state) do
    result = HCISocket.probe(opts)
    Logger.info("[diagnostics] bluetooth probe: #{inspect(result)}")

    # Reported through the snapshot as well as returned, so the panel stops
    # saying "not run" the moment somebody has run it.
    {:reply, result, %{state | bt_probe: result, bluetooth: read_bluetooth(state.rtl, result)}}
  end

  @impl GenServer
  def handle_info(:poll, state), do: {:noreply, poll(%{state | ticks: state.ticks + 1})}

  # One handler for both devices, matching on what the event *is* rather than
  # on which path it came from: the two kinds of event here are disjoint, a
  # volume key and a jack switch, so the path carries no information -- and
  # /dev/input numbering is probe order rather than a promise anyway.
  def handle_info({:input_event, _device, events}, state) do
    state =
      Enum.reduce(events, state, fn
        {:ev_key, :key_volumeup, 1}, acc ->
          %{acc | volume: %{acc.volume | last: :up, up: acc.volume.up + 1}}

        {:ev_key, :key_volumedown, 1}, acc ->
          %{acc | volume: %{acc.volume | last: :down, down: acc.volume.down + 1}}

        {:ev_sw, :sw_headphone_insert, value}, acc ->
          %{acc | jack: %{acc.jack | inserted: value == 1, changes: acc.jack.changes + 1}}

        _event, acc ->
          acc
      end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- reading ---------------------------------------------------------------

  defp poll(state) do
    audio = if rem(state.ticks, @audio_every) == 0, do: read_audio(), else: state.audio
    {gpu, gpu_prev} = read_gpu(state.gpu_prev)

    %{
      state
      | battery: read_battery(),
        thermal: read_thermal(),
        rtc: read_rtc(),
        bluetooth: read_bluetooth(state.rtl, state.bt_probe),
        audio: audio,
        gpu: gpu,
        gpu_prev: gpu_prev
    }
  end

  # Busy time is cumulative nanoseconds, so utilisation is a difference over
  # elapsed wall clock. Measuring this rather than watching the temperature
  # was the point: kmscube keeps this GPU about 5% busy, which is real work
  # and produces no heat worth reading. A thermal check would have called
  # that a dead GPU.
  defp read_gpu(prev) do
    now = System.monotonic_time(:nanosecond)

    case gpu_client() do
      nil ->
        {%{client: nil, engines: %{}}, nil}

      {pid, name} ->
        totals = engine_totals(pid)

        engines =
          case prev do
            {prev_at, prev_totals} when prev_at < now ->
              elapsed = now - prev_at

              Map.new(totals, fn {engine, busy} ->
                delta = busy - Map.get(prev_totals, engine, busy)
                {engine, Float.round(delta / elapsed * 100, 1)}
              end)

            _ ->
              # First sample after launch has nothing to subtract from.
              Map.new(totals, fn {engine, _} -> {engine, nil} end)
          end

        {%{client: name, engines: engines}, {now, totals}}
    end
  end

  defp gpu_client do
    with pid when is_integer(pid) <- launcher_pid(),
         {:ok, comm} <- File.read("/proc/#{pid}/comm") do
      {pid, String.trim(comm)}
    else
      _ -> nil
    end
  end

  defp launcher_pid do
    MayonnaiOS.Launcher.os_pid()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp engine_totals(pid) do
    "/proc/#{pid}/fdinfo/*"
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, acc ->
      case File.read(path) do
        {:ok, body} -> Map.merge(acc, parse_fdinfo(body), fn _k, a, b -> a + b end)
        _ -> acc
      end
    end)
  end

  defp parse_fdinfo(body) do
    if String.contains?(body, "drm-driver:\tpanfrost") do
      ~r/^(drm-engine-[a-z-]+):\s+(\d+) ns$/m
      |> Regex.scan(body)
      |> Map.new(fn [_, engine, ns] ->
        {String.replace_prefix(engine, "drm-engine-", ""), String.to_integer(ns)}
      end)
    else
      %{}
    end
  end

  # The parsing lives in `MayonnaiOS.Power` rather than here, because the
  # status bar reads the same four files and two parsers of one sysfs
  # directory is how two screens end up disagreeing about the battery with no
  # way to tell which is lying. This screen keeps the flat shape -- a map with
  # nils in it -- because it colours each row separately and a partial answer
  # is worth drawing as long as the missing half is drawn as missing.
  defp read_battery, do: MayonnaiOS.Power.values()

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

  defp read_bluetooth(rtl, probe) do
    # An hci0 directory is not evidence of a working controller: it appears
    # before setup runs, and stays after setup fails.
    #
    # It is tempting to reach for /sys/class/bluetooth/hci0/address as the
    # thing that tells those apart. This kernel does not have it -- hci0
    # exposes only uevent, power, device, subsystem and rfkill -- so a check
    # for it reports "no address" on a perfectly healthy controller. That
    # mistake was made here and cost an evening; the note is the fix.
    #
    # Of the three cheap readings, only :rtl says anything about setup, and
    # even that is btrtl's account of what happened once at boot -- a chip
    # that answered then and has been wedged ever since reads identically.
    # :probe is the one that cannot be faked by history, because it is a
    # round trip made now. It stays {:error, :not_run} until somebody calls
    # probe_bluetooth/0; "nobody asked" is deliberately not shown as a pass.
    %{
      hci0: File.dir?("/sys/class/bluetooth/hci0"),
      config_firmware: File.exists?(@bt_config),
      rtl: rtl,
      probe: probe
    }
  end

  # btrtl logs its result once, during boot, and never again -- so this is
  # read at startup and kept, rather than polled.
  #
  #   working: RTL: cfg_sz 25, total sz 36953
  #            RTL: fw version 0x75b8f098
  #   broken:  RTL: mandatory config file rtl_bt/rtl8821cs_config not found
  defp rtl_status do
    case cmd("dmesg", []) do
      {:ok, out} ->
        cond do
          match = Regex.run(~r/RTL: fw version (0x[0-9a-f]+)/, out) ->
            {:ok, Enum.at(match, 1)}

          Regex.match?(~r/RTL: mandatory config file .* not found/, out) ->
            {:error, "config missing"}

          match = Regex.run(~r/Direct firmware load for (\S+) failed/, out) ->
            {:error, "load failed: #{Path.basename(Enum.at(match, 1))}"}

          true ->
            {:error, "no RTL setup logged"}
        end

      :error ->
        {:error, "dmesg unavailable"}
    end
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

  # Takes the driver name rather than a path, so the "there is no such device"
  # case is a line naming the thing that is missing instead of a number that
  # would have been some other device's.
  defp open(name) do
    case MayonnaiOS.Input.find(name) do
      nil ->
        # Losing one of these costs a diagnostic, not the boot.
        Logger.warning("[diagnostics] no #{name} input device; its readings stay blank")
        :error

      device ->
        case InputEvent.start_link(device) do
          {:ok, _pid} ->
            :ok

          other ->
            Logger.warning("[diagnostics] #{device} unavailable: #{inspect(other)}")
            :error
        end
    end
  end

  # evtest exits 10 when the switch is set, 0 when it is not. No jack device
  # means nil -- "nobody could ask", which is what nil already means for this
  # field and is not the same as "nothing is plugged in".
  defp query_jack do
    case MayonnaiOS.Input.find(@jack_name) do
      nil ->
        nil

      jack ->
        case cmd_status("evtest", ["--query", jack, "EV_SW", "SW_HEADPHONE_INSERT"]) do
          {:ok, 10} -> true
          {:ok, 0} -> false
          _ -> nil
        end
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
