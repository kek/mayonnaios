defmodule MayonnaiOS.PairingTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Bluetooth.{Advertising, Bonds, FakeController, HCI, Scanner}
  alias MayonnaiOS.Pairing
  alias MayonnaiOS.Pairing.Cursor
  alias MayonnaiOS.Scene.Pairing, as: Scene

  @laptop {0x00, <<0xA6, 0xA5, 0xA4, 0xA3, 0xA2, 0xA1>>}
  @windows {0x01, <<0xB6, 0xB5, 0xB4, 0xB3, 0xB2, 0xB1>>}

  # The buttons, as the launcher forwards them. :btn_b is physical A; see
  # MayonnaiOS.Launcher for the device tree that lies about it.
  @a {:ev_key, :btn_b, 1}
  @up {:ev_key, :btn_dpad_up, 1}
  @down {:ev_key, :btn_dpad_down, 1}

  setup do
    path = Path.join(System.tmp_dir!(), "pairing-#{System.unique_integer([:positive])}/bonds.bin")
    Application.put_env(:mayonnaios, :bond_path, path)

    on_exit(fn ->
      Application.delete_env(:mayonnaios, :bond_path)
      File.rm_rf!(Path.dirname(path))
    end)

    :ok
  end

  defp bond(peer, ediv) do
    %{
      ltk: :crypto.strong_rand_bytes(16),
      ediv: ediv,
      rand: :crypto.strong_rand_bytes(8),
      peer: peer,
      key_size: 16
    }
  end

  # The app's own supervisor cannot start here: it wants the real Host, and
  # this machine has no AF_BLUETOOTH. So the pieces above the socket are
  # started against the shared fake, which is the same seam the peripheral
  # tests use, and `Pairing.status/0` is then exercised for real.
  defp start_session do
    start_supervised!({FakeController, self()})
    start_supervised!(Bonds)
    start_supervised!(Scanner)
    start_supervised!(Cursor)
    Scanner.status()
    :ok
  end

  defp advertise(name, flags) do
    types = Advertising.types()
    data = Advertising.encode([{types.flags, <<flags>>}, {types.complete_name, name}])

    params = <<0x01, 0x00, 0x00, 1, 2, 3, 4, 5, 6, byte_size(data), data::binary, -55::signed-8>>
    packet = <<0x04, 0x3E, byte_size(params) + 1, 0x02, params::binary>>
    FakeController.emit(HCI.decode(packet))
  end

  describe "the app that is not running" do
    test "status says so rather than raising" do
      assert Pairing.status() == :stopped
    end

    test "input goes nowhere rather than crashing the launcher" do
      assert Pairing.input([@a]) == :ok
    end

    test "the launcher can ask for the scene without the app being up" do
      assert Pairing.scene() == MayonnaiOS.Scene.Pairing
      refute Pairing.active?()
    end

    test "it satisfies the whole contract the launcher calls on an app" do
      # `MayonnaiOS.Launcher.start_program/2` calls start/0, then stop/0 and
      # input/1 and scene/0. A menu entry missing one of these is a
      # FunctionClauseError inside the process that owns the buttons, which
      # takes the gamepad away from the whole device.
      for {function, arity} <- [start: 0, start: 1, stop: 0, input: 1, scene: 0] do
        assert function_exported?(Pairing, function, arity),
               "MayonnaiOS.Pairing.#{function}/#{arity} is missing"
      end
    end

    test "it normalises as an app in the menu, not as a missing binary" do
      assert [program] =
               MayonnaiOS.Programs.list([%{name: "Bluetooth devices", app: Pairing}])

      assert program.installed?
      assert program.app == Pairing
      assert program.path == nil
    end
  end

  describe "what the screen is handed" do
    setup do
      start_session()
      :ok
    end

    test "bonds come out with a printable address rather than an EDIV" do
      Bonds.put(bond(@laptop, <<1, 0>>))

      assert [entry] = Pairing.list_bonds()
      assert entry.address == "A1:A2:A3:A4:A5:A6"
      assert entry.random? == false
      assert entry.key_size == 16
    end

    test "a random peer address is marked as one" do
      Bonds.put(bond(@windows, <<2, 0>>))
      assert [%{random?: true}] = Pairing.list_bonds()
    end
  end

  describe "the cursor" do
    setup do
      start_session()
      :ok
    end

    test "starts at the top and stays there with nothing paired" do
      assert %{selected: 0, armed: false} = Cursor.state()

      Cursor.input([@down])

      assert %{selected: 0, armed: false} = Cursor.state()
    end

    test "A cannot arm an empty list" do
      Cursor.input([@a])
      assert %{armed: false} = Cursor.state()
    end

    test "moves over the paired hosts and wraps" do
      Bonds.put(bond(@laptop, <<1, 0>>))
      Bonds.put(bond(@windows, <<2, 0>>))

      Cursor.input([@down])
      assert %{selected: 1} = Cursor.state()

      Cursor.input([@down])
      assert %{selected: 0} = Cursor.state()

      Cursor.input([@up])
      assert %{selected: 1} = Cursor.state()
    end

    test "the first A arms and the second one forgets" do
      Bonds.put(bond(@laptop, <<1, 0>>))
      Bonds.put(bond(@windows, <<2, 0>>))

      Cursor.input([@a])
      assert %{armed: true, selected: 0} = Cursor.state()
      assert length(Bonds.list()) == 2

      Cursor.input([@a])
      assert %{armed: false} = Cursor.state()

      # Newest first, so index 0 is the Windows bond that was put last.
      assert [%{peer: @laptop}] = Bonds.list()
    end

    test "moving cancels an armed row" do
      Bonds.put(bond(@laptop, <<1, 0>>))
      Bonds.put(bond(@windows, <<2, 0>>))

      Cursor.input([@a])
      Cursor.input([@down])

      assert %{armed: false, selected: 1} = Cursor.state()
      assert length(Bonds.list()) == 2
    end

    test "an unbound button leaves an armed row armed" do
      Bonds.put(bond(@laptop, <<1, 0>>))

      Cursor.input([@a])
      # Y, which is deliberately unbound everywhere on this device.
      Cursor.input([{:ev_key, :btn_x, 1}])

      assert %{armed: true} = Cursor.state()
    end

    test "autorepeat is ignored, so holding A does not forget a second bond" do
      Bonds.put(bond(@laptop, <<1, 0>>))
      Bonds.put(bond(@windows, <<2, 0>>))

      Cursor.input([@a])
      Cursor.input([{:ev_key, :btn_b, 2}])
      Cursor.input([{:ev_key, :btn_b, 2}])

      assert length(Bonds.list()) == 2
      assert %{armed: true} = Cursor.state()
    end

    test "forgetting the last row leaves the cursor inside the shorter list" do
      Bonds.put(bond(@laptop, <<1, 0>>))
      Bonds.put(bond(@windows, <<2, 0>>))

      Cursor.input([@down])
      Cursor.input([@a])
      Cursor.input([@a])

      assert length(Bonds.list()) == 1
      # The index is bounded where it is used rather than clamped here, so the
      # screen never asks for a row that is not in the list.
      assert %{selected: 1} = Cursor.state()
      assert %{selected: 0} = Pairing.status()
    end
  end

  describe "the screen" do
    test "renders the not-running page with the reason on it" do
      texts = texts(Scene.graph(:stopped, :eusers))

      assert "Not running" in texts
      assert ":eusers" in texts
      assert "Something else already has hci0." in texts
    end

    test "names the controller app when it already has the stack" do
      texts = texts(Scene.graph(:stopped, {:already_started, self()}))
      assert "The controller app is running." in texts
    end

    test "says headphones do not work before it says anything else" do
      start_session()

      texts = texts(Scene.graph(Pairing.status()))

      assert "Headphones cannot be connected from here." in texts

      assert "Audio is A2DP over BR/EDR, and this firmware has no BR/EDR host at all." in texts
    end

    test "offers no action at all when nothing is paired" do
      start_session()

      texts = texts(Scene.graph(Pairing.status()))

      assert "Nothing paired." in texts
      assert "B or Menu goes back." in texts
      refute Enum.any?(texts, &String.contains?(&1, "A forgets"))
    end

    test "a dual-mode device is tagged where a Connect button would be" do
      start_session()
      advertise("Headphones", 0x02)

      texts = texts(Scene.graph(Pairing.status()))

      assert "Headphones" in texts
      assert Enum.any?(texts, &String.contains?(&1, "needs BR/EDR"))
      refute Enum.any?(texts, &String.contains?(&1, "Connect"))
    end

    test "an LE-only device is not tagged as needing a transport we lack" do
      start_session()
      advertise("Beacon", 0x06)

      texts = texts(Scene.graph(Pairing.status()))

      assert Enum.any?(texts, &String.contains?(&1, "LE only"))
      refute Enum.any?(texts, &String.contains?(&1, "needs BR/EDR"))
    end

    test "an armed row says which press does it" do
      start_session()
      Bonds.put(bond(@laptop, <<1, 0>>))
      Cursor.input([{:ev_key, :btn_b, 1}])

      texts = texts(Scene.graph(Pairing.status()))

      assert "press A again to forget" in texts
      assert "A forgets this pairing. Any direction cancels. B or Menu leaves." in texts
    end

    test "an unarmed row says what the buttons do" do
      start_session()
      Bonds.put(bond(@laptop, <<1, 0>>))

      texts = texts(Scene.graph(Pairing.status()))

      assert "A1:A2:A3:A4:A5:A6" in texts
      assert "public address, 128-bit key" in texts
      assert "D-pad picks a pairing, A forgets it. B or Menu goes back." in texts
    end

    test "a scan that never started says so instead of showing an empty room" do
      status = %{
        scan: %{scanning: false, error: :eusers, devices: 0, undecodable: 0},
        devices: [],
        bonds: [],
        selected: 0,
        armed: false
      }

      texts = texts(Scene.graph(status))

      assert "Scan did not start." in texts
      refute "Scanning..." in texts
    end

    test "a scan with nothing in it yet is different from a scan that failed" do
      start_session()

      texts = texts(Scene.graph(Pairing.status()))

      assert "Scanning..." in texts
      assert "Nothing has advertised yet." in texts
    end

    test "windows the paired hosts so a selection past the last visible one is drawn" do
      bonds =
        for i <- 1..12 do
          %{
            peer: {0x00, <<i, i, i, i, i, i>>},
            address: "0#{i}:00:00:00:00:00",
            random?: false,
            key_size: 16
          }
        end

      status = %{
        scan: %{scanning: true, error: nil, devices: 0, undecodable: 0},
        devices: [],
        bonds: bonds,
        selected: 11,
        armed: false
      }

      texts = texts(Scene.graph(status))

      assert "012:00:00:00:00:00" in texts
      refute "01:00:00:00:00:00" in texts
      # Seven rows, not eight: the shared top bar took 22 px off the top of
      # this screen and the eighth row's counter would have landed on the
      # footer rule. The number is here rather than read from the scene on
      # purpose -- if the window shrinks again, this test is what should
      # notice.
      assert "6-12 of 12" in texts
    end

    test "a long name is clipped rather than drawn over the footer" do
      status = %{
        scan: %{scanning: true, error: nil, devices: 1, undecodable: 0},
        devices: [
          %{
            label: "A Very Long Bluetooth Device Name Indeed",
            name: "A Very Long Bluetooth Device Name Indeed",
            rssi: -40,
            age_ms: 0,
            dual_mode?: false
          }
        ],
        bonds: [],
        selected: 0,
        armed: false
      }

      texts = texts(Scene.graph(status))

      assert Enum.any?(texts, &String.starts_with?(&1, "A Very Long Bluetooth"))
      refute "A Very Long Bluetooth Device Name Indeed" in texts
    end
  end

  # Every text primitive's string, the same helper the launcher tests use, so
  # a test can assert what the panel says rather than only that it built.
  defp texts(graph) do
    Scenic.Graph.reduce(graph, [], fn
      %Scenic.Primitive{module: Scenic.Primitive.Text, data: data}, acc -> [data | acc]
      _primitive, acc -> acc
    end)
  end
end
