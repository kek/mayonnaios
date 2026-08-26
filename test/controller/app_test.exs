defmodule MayonnaiOS.Controller.AppTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Launcher, Programs}
  alias MayonnaiOS.Controller.{Pad, Report}

  # The app end of the controller: what the launcher does with a menu entry
  # that is a module rather than a binary, and what the pad does with the
  # events it is handed. No Bluetooth -- the pad's reports go to a function
  # that sends them here, which is the seam that lets the whole
  # button-to-bytes path be checked on a laptop.

  # A stand-in for MayonnaiOS.Controller, recording what the launcher asked of
  # it. Deliberately not the real one: starting that opens hci0, which does
  # not exist on this machine, and the thing under test is the launcher's side
  # of the conversation.
  defmodule FakeApp do
    def start(_opts \\ []) do
      Agent.update(__MODULE__, &%{&1 | started: &1.started + 1})
      if Agent.get(__MODULE__, & &1.fail), do: {:error, :eusers}, else: {:ok, self()}
    end

    def stop do
      Agent.update(__MODULE__, &%{&1 | stopped: &1.stopped + 1})
      :ok
    end

    def input(events) do
      Agent.update(__MODULE__, &%{&1 | events: &1.events ++ [events]})
      :ok
    end

    def scene, do: MayonnaiOS.Scene.Controller

    def log, do: Agent.get(__MODULE__, & &1)
  end

  describe "Programs.list/1 with an app" do
    test "an app is always installed, because it is in this firmware" do
      assert [program] = Programs.list([%{name: "Controller", app: MayonnaiOS.Controller}])
      assert program.installed?
      assert program.app == MayonnaiOS.Controller
      assert program.path == nil
    end

    test "an app with no name is named after its module" do
      assert [program] = Programs.list([%{app: MayonnaiOS.Controller}])
      assert program.name == "MayonnaiOS.Controller"
    end

    test "a program keeps working exactly as it did" do
      assert [program] = Programs.list([%{path: "/usr/bin/kmscube"}])
      assert program.app == nil
      assert program.name == "kmscube"
    end

    test "the two kinds sit in one menu" do
      programs =
        Programs.list([
          %{name: "RetroArch", path: "/usr/bin/retroarch"},
          %{name: "Controller", app: MayonnaiOS.Controller}
        ])

      assert Enum.map(programs, & &1.name) == ["RetroArch", "Controller"]
    end
  end

  describe "the launcher running an app" do
    setup do
      start_supervised!(%{
        id: FakeApp,
        start:
          {Agent, :start_link,
           [fn -> %{started: 0, stopped: 0, events: [], fail: false} end, [name: FakeApp]]}
      })

      Application.put_env(:mayonnaios, :programs, [%{name: "Controller", app: FakeApp}])
      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)

      start_supervised!({Launcher, device: "/nonexistent"})
      :ok
    end

    test "A starts it" do
      press(:btn_b)

      assert FakeApp.log().started == 1
    end

    test "the buttons then go to the app instead of the launcher" do
      press(:btn_b)

      # A again. Without app mode this would try to launch a second time; with
      # it, the press is forwarded and the launcher does nothing.
      press(:btn_b)

      assert FakeApp.log().started == 1
      assert FakeApp.log().events == [[{:ev_key, :btn_b, 1}]]
    end

    test "a whole evdev report is forwarded in one piece" do
      press(:btn_b)

      send_events([{:ev_key, :btn_dpad_down, 1}, {:ev_key, :btn_a, 1}])

      # One entry, not two: the A press that started the app belongs to the
      # launcher and is not forwarded. Only what happens after it is the
      # app's.
      assert [report] = FakeApp.log().events
      assert report == [{:ev_key, :btn_dpad_down, 1}, {:ev_key, :btn_a, 1}]
    end

    test "the D-pad does not move the menu cursor" do
      before = Launcher.selected()
      press(:btn_b)
      press(:btn_dpad_down)

      assert Launcher.selected() == before
    end

    test "Menu stops it" do
      press(:btn_b)
      press(:btn_mode)

      assert FakeApp.log().stopped == 1
    end

    test "and after Menu the launcher has its buttons back" do
      press(:btn_b)
      press(:btn_mode)

      # A launches again, which it could not do if the launcher still thought
      # an app was running.
      press(:btn_b)

      assert FakeApp.log().started == 2
    end

    # There is deliberately no test for Select+Menu here.
    #
    # `Nerves.Runtime.poweroff/0` is not a no-op on the host: it fails to find
    # the `poweroff` binary, but not before it has begun stopping the VM, and
    # a test that presses the chord takes the whole run down with it -- the
    # suite exits zero with no summary, which reads as a passing run that
    # printed nothing. The chord's ordering (checked before the plain Menu) is
    # one `if` in `leave_app/2` and is readable there; a test that ends the
    # test run is worse than no test.

    test "an app that will not start leaves the launcher usable" do
      Agent.update(FakeApp, &%{&1 | fail: true})

      press(:btn_b)

      assert FakeApp.log().started == 1
      # Not in app mode: the next press is the launcher's again.
      press(:btn_b)
      assert FakeApp.log().started == 2
      assert FakeApp.log().events == []
    end
  end

  describe "the pad" do
    setup do
      parent = self()
      start_supervised!({Pad, sink: fn bytes -> send(parent, {:report, bytes}) end})
      :ok
    end

    test "a press produces one report" do
      Pad.input([{:ev_key, :btn_b, 1}])

      assert_receive {:report, <<_::binary-size(13), 0x01, 0x00, 0x00>>}
    end

    test "and a release produces another" do
      Pad.input([{:ev_key, :btn_b, 1}])
      assert_receive {:report, _}

      Pad.input([{:ev_key, :btn_b, 0}])
      assert_receive {:report, <<_::binary-size(13), 0x00, 0x00, 0x00>>}
    end

    test "an event that changes nothing sends nothing" do
      Pad.input([{:ev_key, :btn_b, 1}])
      assert_receive {:report, _}

      # Auto-repeat of a button already held: the state is the same, so the
      # host has nothing to be told.
      Pad.input([{:ev_key, :btn_b, 2}])
      refute_receive {:report, _}, 50
    end

    test "a button the report does not carry sends nothing" do
      Pad.input([{:ev_key, :btn_mode, 1}])

      refute_receive {:report, _}, 50
    end

    test "a diagonal and a button in one report are one report out" do
      Pad.input([
        {:ev_key, :btn_dpad_down, 1},
        {:ev_key, :btn_dpad_right, 1},
        {:ev_key, :btn_b, 1}
      ])

      assert_receive {:report, <<_::binary-size(12), 4, 0x01, 0x00, 0x00>>}
      refute_receive {:report, _}, 50
    end

    test "the stick is a report too, and its noise is not" do
      Pad.input([{:ev_abs, :abs_x, 4096}])
      assert_receive {:report, <<0xFF, 0xFF, _::binary>>}

      # A wobble inside one quantisation step encodes to the same bytes, and
      # the same bytes are not sent twice.
      Pad.input([{:ev_abs, :abs_x, 4090}])
      refute_receive {:report, _}, 50
    end

    test "state/0 reports what is held" do
      Pad.input([{:ev_key, :btn_b, 1}, {:ev_key, :btn_dpad_up, 1}])
      assert_receive {:report, _}

      state = Pad.state()
      assert state.pressed == [:btn_b]
      assert state.directions == [:up]
    end

    test "leaving controller mode releases whatever was held" do
      Pad.input([{:ev_key, :btn_b, 1}])
      assert_receive {:report, _}

      stop_supervised!(Pad)

      assert_receive {:report, bytes}
      assert bytes == Report.encode(Report.released())
    end

    test "and sends nothing on the way out when nothing was held" do
      stop_supervised!(Pad)

      refute_receive {:report, _}, 50
    end
  end

  defp press(key), do: send_events([{:ev_key, key, 1}])

  # The shape input_event delivers, which is what the Launcher listens for.
  defp send_events(events) do
    send(Launcher, {:input_event, "(test)", events})
    # The Launcher is a GenServer and these are casts in disguise; a call
    # flushes the mailbox so the assertion sees the effect.
    Launcher.selected()
    :ok
  end
end
