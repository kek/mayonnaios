defmodule MayonnaiOS.StatusBarTest do
  # Not async: it starts named processes and reads the application
  # environment, both of which are one global.
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Power, Programs, Status}
  alias MayonnaiOS.Scene.StatusBar

  # A sysfs battery directory, with the values read off this device: 437000 µA
  # at 4175000 µV while idle. Written to a temp directory rather than mocked,
  # because the thing being tested is the parsing of files whose format is the
  # kernel's, and a mock would only assert that this test agrees with itself.
  setup do
    id = System.unique_integer([:positive])
    battery = Path.join(System.tmp_dir!(), "battery-#{id}")
    usb = Path.join(System.tmp_dir!(), "usb-#{id}")

    File.mkdir_p!(battery)
    File.mkdir_p!(usb)

    write = fn dir, name, value -> File.write!(Path.join(dir, name), "#{value}\n") end

    write.(battery, "capacity", 62)
    write.(battery, "status", "Discharging")
    write.(battery, "voltage_now", 4_175_000)
    write.(battery, "current_now", 437_000)
    write.(battery, "health", "Good")
    write.(usb, "online", 0)

    on_exit(fn ->
      File.rm_rf(battery)
      File.rm_rf(usb)
    end)

    %{battery: battery, usb: usb, write: write}
  end

  describe "Power" do
    test "reads what the supply says", %{battery: battery, usb: usb} do
      assert {:ok, values} = Power.read(battery: battery, usb: usb)

      assert values.capacity == 62
      assert values.status == "Discharging"
      # Microvolts and microamps, undivided: the display divides, the reader
      # does not, so nothing downstream has to guess which it was given.
      assert values.voltage_uv == 4_175_000
      assert values.current_ua == 437_000
      assert values.usb_online == false
      assert Power.state(values) == :discharging
    end

    test "a supply that is not there is unavailable, not empty" do
      # The distinction the whole status bar rests on. A laptop has no
      # /sys/class/power_supply, and "0%" there would be indistinguishable
      # from a flat battery on the device.
      assert Power.read(battery: "/nonexistent/battery", usb: "/nonexistent/usb") ==
               {:error, :unavailable}

      assert Power.values(battery: "/nonexistent/battery", usb: "/nonexistent/usb") == %{
               capacity: nil,
               status: nil,
               voltage_uv: nil,
               current_ua: nil,
               health: nil,
               usb_online: false
             }
    end

    test "half an answer is still an answer", %{battery: battery, usb: usb, write: write} do
      File.rm!(Path.join(battery, "capacity"))
      write.(battery, "status", "Charging")

      assert {:ok, values} = Power.read(battery: battery, usb: usb)
      assert values.capacity == nil
      assert Power.state(values) == :charging
    end

    test "a status this board has never produced is unknown, not guessed", %{
      battery: battery,
      write: write
    } do
      write.(battery, "status", "Quantum")
      assert Power.state(Power.values(battery: battery)) == :unknown

      # And the sign of current_now is not used to fill the gap: it reads
      # 437000 µA on an idle battery, which is neither charging nor
      # discharging in any sense a person would recognise.
      refute Power.state(Power.values(battery: battery)) == :discharging
    end
  end

  describe "Status" do
    test "pushes a reading to whoever subscribed", %{battery: battery, usb: usb} do
      server = start_reader(battery: battery, usb: usb)

      Status.subscribe(server)

      assert_receive {:mayonnaios_status, reading}
      assert reading.battery.value.capacity == 62
      assert reading.battery.error == nil
      # Stamped with the time it was taken. Without this the bar cannot tell a
      # reading from a memory of one.
      assert is_integer(reading.battery.at)
    end

    test "keeps pushing on its own clock", %{battery: battery, usb: usb} do
      server = start_reader(battery: battery, usb: usb, poll_ms: 20)

      Status.subscribe(server)
      assert_receive {:mayonnaios_status, first}
      assert_receive {:mayonnaios_status, second}

      assert second.battery.at >= first.battery.at
    end

    test "an absent supply is reported as absent" do
      server = start_reader(battery: "/nonexistent/battery", usb: "/nonexistent/usb")

      Status.subscribe(server)

      assert_receive {:mayonnaios_status, reading}
      assert reading.battery.value == nil
      assert reading.battery.error == :unavailable
    end

    test "WiFi says it is not managed rather than saying disconnected" do
      # VintageNet is a target-only dependency, so this is the host case: no
      # radio to ask. Reporting :disconnected here would be a bar that cries
      # wolf on every development machine.
      refute Code.ensure_loaded?(VintageNet)

      server = start_reader([])
      Status.subscribe(server)

      assert_receive {:mayonnaios_status, reading}
      assert reading.wifi.error == :not_managed
    end

    test "a subscriber that dies does not take the reader with it", %{
      battery: battery,
      usb: usb
    } do
      server = start_reader(battery: battery, usb: usb)

      subscriber = spawn(fn -> Status.subscribe(server) end)
      ref = Process.monitor(subscriber)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _reason}

      Status.subscribe(server)
      assert_receive {:mayonnaios_status, _reading}
      assert Process.alive?(Process.whereis(server))
    end
  end

  describe "what the bar says" do
    test "a fresh reading is drawn as a reading", %{battery: battery, usb: usb, write: write} do
      write.(battery, "status", "Charging")
      reading = one_reading(battery: battery, usb: usb)

      fields = StatusBar.fields(reading)

      assert fields.battery.percent == "62%"
      assert fields.battery.word == "charging"
      assert fields.battery.level == 62
    end

    test "a reading that has gone quiet is not drawn at all", %{battery: battery, usb: usb} do
      reading = one_reading(battery: battery, usb: usb)

      # Six seconds and one millisecond after the reading was taken: the
      # reader has missed three polls. This is the test the whole design is
      # for -- the failure this project keeps repeating is a plausible value
      # that never moves, and the bar is the most believed place on the panel
      # to repeat it.
      #
      # Measured from the *newest* of the two stamps. The battery and the WiFi
      # are stamped separately as the reader takes them, so on a loaded
      # machine the WiFi stamp can be a millisecond or two later than the
      # battery's -- and 6_001 past the battery's would then be inside the
      # window for the WiFi, which asserts below that it is not.
      taken = max(reading.battery.at, reading.wifi.at)
      stale = StatusBar.fields(reading, now: taken + 6_001)

      assert stale.battery.percent == "--"
      assert stale.battery.word == "no reading"
      assert stale.battery.level == nil
      assert stale.wifi.word == "no reading"

      # And a reading a millisecond inside the window is still drawn, so the
      # bar does not flicker into "no reading" on a busy device.
      fresh = StatusBar.fields(reading, now: reading.battery.at + 5_999)
      assert fresh.battery.percent == "62%"
    end

    test "a bar that has never heard anything says so" do
      fields = StatusBar.fields(nil)

      assert fields.battery.word == "no reading"
      assert fields.wifi.word == "no reading"
    end

    test "the state is shown even when it is the boring one" do
      # A bar that only marks charging leaves "the cable is in and nothing is
      # happening" looking exactly like a normal discharge.
      assert words(:discharging).battery.word == "on battery"
      assert words(:charging).battery.word == "charging"
      assert words(:full).battery.word == "full"
      assert words(:unknown).battery.word == "no state"
    end

    test "the clock says which clock it is" do
      {:ok, noon} = DateTime.new(~D[2026-08-22], ~T[14:32:07], "Etc/UTC")

      # There is no timezone database in this image, so UTC is the only honest
      # thing the panel can claim -- and it claims it in the text rather than
      # in a moduledoc nobody holding the device can read.
      assert StatusBar.fields(nil, utc: noon).clock.text == "14:32 UTC"
    end

    test "an RTC that was never set is not drawn as a time" do
      {:ok, epoch} = DateTime.new(~D[1970-01-01], ~T[01:34:00], "Etc/UTC")

      assert StatusBar.fields(nil, utc: epoch).clock.text == "clock unset"
    end

    test "a WiFi state is a word, and an unknown one is not invented" do
      assert wifi(%{value: :internet, error: nil}).word == "internet"
      assert wifi(%{value: :lan, error: nil}).word == "lan only"
      assert wifi(%{value: :disconnected, error: nil}).word == "no network"
      assert wifi(%{value: :configuring, error: nil}).word == "configuring"

      # Clipped rather than allowed to grow leftwards into the scene's title:
      # the fields are laid out from the right edge, so a long word pushes the
      # ones beside it rather than running off the panel.
      assert wifi(%{value: :some_state_nobody_has_seen, error: nil}).word == "some_state_…"
    end
  end

  describe "the strip" do
    test "the bar draws inside its own height and nowhere else" do
      for fields <- [StatusBar.fields(nil), StatusBar.fields(nil, utc: DateTime.utc_now())] do
        for {y, primitive} <- placements(StatusBar.graph(fields)) do
          assert y >= 0 and y < StatusBar.height(),
                 "#{inspect(primitive)} is at y=#{y}, outside the #{StatusBar.height()} px strip"
        end
      end
    end

    test "every scene mounts the bar" do
      for {name, graph} <- scenes() do
        assert Enum.any?(components(graph), &(&1 == StatusBar)),
               "#{name} does not mount the status bar"
      end
    end

    test "no scene draws in the strip the bar owns" do
      # The file manager reserved this strip before the bar existed and has
      # its own test for every one of its views; this is the same assertion
      # for the other four screens, so a new one cannot be added under the
      # bar without something noticing.
      for {name, graph} <- scenes(), {y, primitive} <- placements(graph) do
        assert y >= StatusBar.height(),
               "#{name} draws #{inspect(primitive)} at y=#{y}, inside the bar's strip"
      end
    end

    test "the reserved height is the bar's own, not a copy of it" do
      assert MayonnaiOS.Scene.Top.status_bar() == StatusBar.height()
    end
  end

  describe "under a real viewport" do
    test "every scene starts the bar, and the bar subscribes to the reader" do
      # A ViewPort with no drivers: no window, no framebuffer, and everything
      # else real -- the graphs are compiled, the component is started as a
      # child scene, and its init/3 runs. That is the half of this feature the
      # pure graph tests cannot reach, and on this project it is the half that
      # has historically been wrong: a scene that builds a graph in a test and
      # crashes on the device is exactly the shape of "CI green on a GPU-less
      # image".
      # Under the test supervisor, not linked to the test process: `test/
      # panel_test.exs` starts Scenic too, and a `:scenic` left to die on its
      # own outlives the test that started it -- and whichever of the two
      # runs second races a supervisor that is already shutting down.
      start_supervised!({Scenic, []})

      {:ok, viewport} =
        Scenic.ViewPort.start(%{
          name: :status_bar_test_viewport,
          size: {640, 480},
          default_scene: MayonnaiOS.Scene.Home,
          drivers: []
        })

      # The bar the boot scene mounted, started and asking the reader for
      # readings. Nothing in the graph tests proves this happens.
      assert wait_for_subscribers(1)

      for {module, param} <- [
            {MayonnaiOS.Scene.Diagnostics, nil},
            {MayonnaiOS.Scene.Top, %{error: nil}},
            {MayonnaiOS.Scene.Pairing, %{error: nil}},
            {MayonnaiOS.Scene.Controller, %{error: nil}},
            {MayonnaiOS.Scene.Home, %{selected: 0}}
          ] do
        :ok = Scenic.ViewPort.set_root(viewport, module, param)

        # Back to exactly one: the outgoing scene's bar is gone and the
        # incoming one's has subscribed. Two would mean the reader is
        # accumulating the ghosts of every screen ever opened.
        assert wait_for_subscribers(1), "#{inspect(module)} did not leave one bar subscribed"
      end

      Scenic.ViewPort.stop(viewport)

      # And the monitor is what cleans up, not a message from the scene: a
      # scene that is killed mid-repaint has no chance to say goodbye.
      assert wait_for_subscribers(0)
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp wait_for_subscribers(count, attempts \\ 50) do
    cond do
      subscribers() == count -> true
      attempts > 0 -> Process.sleep(20) && wait_for_subscribers(count, attempts - 1)
      true -> flunk("expected #{count} subscribers, found #{subscribers()}")
    end
  end

  defp subscribers do
    Status |> :sys.get_state() |> Map.fetch!(:subscribers) |> map_size()
  end

  defp start_reader(opts) do
    name = :"status-#{System.unique_integer([:positive])}"
    start_supervised!({Status, Keyword.put(opts, :name, name)})
    name
  end

  # One real reading, through the real reader, so that what the bar is asked
  # to draw is the shape the reader actually sends rather than a guess at it.
  defp one_reading(opts) do
    server = start_reader(opts)
    Status.subscribe(server)
    assert_receive {:mayonnaios_status, reading}
    reading
  end

  defp words(state) do
    status =
      case state do
        :charging -> "Charging"
        :discharging -> "Discharging"
        :full -> "Full"
        :unknown -> "Anything Else"
      end

    at = System.monotonic_time(:millisecond)

    StatusBar.fields(%{
      battery: %{value: %{capacity: 62, status: status}, error: nil, at: at},
      wifi: %{value: :internet, error: nil, at: at},
      at: at
    })
  end

  defp wifi(source) do
    at = System.monotonic_time(:millisecond)

    StatusBar.fields(%{
      battery: %{value: %{capacity: 62, status: "Discharging"}, error: nil, at: at},
      wifi: Map.put(source, :at, at),
      at: at
    }).wifi
  end

  # One graph from every scene in this firmware. Both the populated page and
  # the "not running" page where a scene has one, because they are built by
  # different clauses and only one of them would notice a title moved back up
  # into the strip.
  defp scenes do
    [
      {"Scene.Home", MayonnaiOS.Scene.Home.graph(MayonnaiOS.Browser.new())},
      {"Scene.Home (columns)",
       MayonnaiOS.Scene.Home.graph(MayonnaiOS.Browser.descend(MayonnaiOS.Browser.new()))},
      {"Scene.Diagnostics", MayonnaiOS.Scene.Diagnostics.graph(%MayonnaiOS.Diagnostics{})},
      {"Scene.Diagnostics (no collector)", MayonnaiOS.Scene.Diagnostics.graph(nil)},
      {"Scene.Top (stopped)", MayonnaiOS.Scene.Top.graph(:stopped)},
      {"Scene.Pairing", MayonnaiOS.Scene.Pairing.graph(pairing_status())},
      {"Scene.Pairing (stopped)", MayonnaiOS.Scene.Pairing.graph(:stopped, :enodev)},
      {"Scene.Controller", MayonnaiOS.Scene.Controller.graph(controller_status())},
      {"Scene.Controller (stopped)", MayonnaiOS.Scene.Controller.graph(:stopped, :eusers)}
    ]
  end

  defp pairing_status do
    %{
      scan: %{scanning: true, error: nil, devices: 1, undecodable: 0},
      devices: [%{label: "Speaker", name: "Speaker", rssi: -60, dual_mode?: true, age_ms: 500}],
      bonds: [%{address: "00:11:22:33:44:55", random?: false, key_size: 16}],
      selected: 0,
      armed: false
    }
  end

  defp controller_status do
    %{
      name: "Xbox Wireless Controller",
      address: "00:11:22:33:44:55",
      advertising: true,
      connected: true,
      encrypted: true,
      subscribed: true,
      report_map_read: true,
      interval_ms: 15.0,
      paired: true,
      mtu: 65,
      bonds: 1,
      sent: 12,
      dropped: %{}
    }
  end

  # Every primitive's y, except the full-screen background the bar paints over
  # and the bar itself, which is the one thing allowed up there.
  defp placements(graph) do
    Scenic.Graph.reduce(graph, [], fn
      %Scenic.Primitive{data: {640, 480}}, acc ->
        acc

      %Scenic.Primitive{module: Scenic.Primitive.Component}, acc ->
        acc

      %Scenic.Primitive{} = primitive, acc ->
        case get_in(primitive.transforms, [:translate]) do
          {_x, y} -> [{y, primitive.module} | acc]
          _none -> acc
        end
    end)
  end

  defp components(graph) do
    Scenic.Graph.reduce(graph, [], fn
      %Scenic.Primitive{module: Scenic.Primitive.Component, data: {module, _param, _name}}, acc ->
        [module | acc]

      _primitive, acc ->
        acc
    end)
  end
end
