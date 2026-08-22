defmodule MayonnaiOS.LauncherTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Launcher, Programs}
  alias MayonnaiOS.Scene.Home

  # No viewport, no driver, no framebuffer. Everything here runs on the host,
  # because everything here is arithmetic and graph building -- the parts of
  # the launcher that can be wrong without the device saying so.

  describe "Programs.list/1" do
    test "fills in the name from the path and defaults the arguments" do
      assert [program] = Programs.list([%{path: "/usr/bin/kmscube"}])
      assert program.name == "kmscube"
      assert program.args == []
    end

    test "keeps an explicit name and arguments" do
      assert [program] =
               Programs.list([
                 %{name: "Cube", path: "/usr/bin/kmscube", args: ["-M", "smooth"]}
               ])

      assert program.name == "Cube"
      assert program.args == ["-M", "smooth"]
    end

    test "reports a path that is not in the image rather than dropping it" do
      # The whole point of the installed? flag: a missing binary must reach
      # the panel as a visible entry, not vanish from a menu that then looks
      # correct.
      assert [program] = Programs.list([%{path: "/usr/bin/definitely-not-here"}])
      refute program.installed?
      assert length(Programs.list([%{path: "/usr/bin/definitely-not-here"}])) == 1
    end

    test "an existing path is reported as installed" do
      # Stat'd for real, so this asserts against a file the host does have.
      assert [program] = Programs.list([%{path: System.find_executable("sh")}])
      assert program.installed?
    end
  end

  describe "Programs.step/3" do
    setup do
      %{programs: Programs.list([%{path: "/a"}, %{path: "/b"}, %{path: "/c"}])}
    end

    test "moves down and wraps past the end", %{programs: programs} do
      assert Programs.step(programs, 0, 1) == 1
      assert Programs.step(programs, 2, 1) == 0
    end

    test "moves up and wraps past the start", %{programs: programs} do
      assert Programs.step(programs, 1, -1) == 0
      assert Programs.step(programs, 0, -1) == 2
    end

    test "is 0 for an empty list" do
      # An empty menu must not divide by zero on a D-pad press.
      assert Programs.step([], 0, 1) == 0
      assert Programs.step([], 3, -1) == 0
    end
  end

  describe "Programs.at/2" do
    test "tolerates an index past the end of a shrunken list" do
      programs = Programs.list([%{path: "/a"}, %{path: "/b"}])
      assert Programs.at(programs, 5).path == "/b"
      assert Programs.at(programs, -1).path == "/b"
    end

    test "is nil when nothing is configured" do
      assert Programs.at([], 0) == nil
    end
  end

  describe "Scene.Home.graph/2" do
    test "builds for an empty list" do
      assert %Scenic.Graph{} = Home.graph([], 0)
    end

    test "builds for a single entry" do
      assert %Scenic.Graph{} = Home.graph(Programs.list([%{path: "/usr/bin/kmscube"}]), 0)
    end

    test "builds with the selection on the last row" do
      programs = Programs.list([%{path: "/a"}, %{path: "/b"}, %{path: "/c"}])
      assert %Scenic.Graph{} = Home.graph(programs, 2)
    end

    test "windows the rows so the selection is always drawn" do
      # "It built without raising" is not enough here: Enum.slice returns []
      # for an out-of-range start, so a broken window would still produce a
      # graph -- an empty menu that looks like a rendering bug on the device.
      programs = Programs.list(for i <- 1..20, do: %{path: "/bin/prog#{i}"})

      last = texts(Home.graph(programs, 19))
      assert "prog20" in last
      refute "prog1" in last

      first = texts(Home.graph(programs, 0))
      assert "prog1" in first
      refute "prog20" in first
    end

    test "says so on the row when a configured path is not in the image" do
      graph = Home.graph(Programs.list([%{path: "/usr/bin/definitely-not-here"}]), 0)
      assert "not installed" in texts(graph)
    end

    # Every text primitive's string, so a test can assert what the panel says
    # rather than only that a graph exists.
    defp texts(graph) do
      Scenic.Graph.reduce(graph, [], fn
        %Scenic.Primitive{module: Scenic.Primitive.Text, data: data}, acc -> [data | acc]
        _primitive, acc -> acc
      end)
    end
  end

  describe "the D-pad binding" do
    setup do
      # The Launcher is not in the host supervision tree, and there is no
      # /dev/input here, so it starts with no device and the synthetic events
      # below stand in for the pad.
      programs = [%{path: "/a"}, %{path: "/b"}, %{path: "/c"}]
      Application.put_env(:mayonnaios, :programs, programs)
      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)

      start_supervised!({Launcher, device: "/nonexistent/event0"})
      :ok
    end

    test "down moves the cursor and up moves it back" do
      # This is the check that the atoms are right, rather than that the
      # arithmetic is: it drives the same clause a real press drives.
      press(:btn_dpad_down)
      assert Launcher.selected() == 1

      press(:btn_dpad_down)
      assert Launcher.selected() == 2

      press(:btn_dpad_up)
      assert Launcher.selected() == 1
    end

    test "up from the top wraps to the bottom" do
      press(:btn_dpad_up)
      assert Launcher.selected() == 2
    end

    test "autorepeat does not move the cursor" do
      # value 2 is autorepeat, which the event reduce drops: holding the
      # D-pad must not scroll, because every move re-roots the viewport.
      send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, :btn_dpad_down, 2}]})
      assert Launcher.selected() == 0
    end

    defp press(key) do
      send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, key, 1}]})
      # selected/0 is a call, so it is ordered behind the cast above.
      Launcher.selected()
    end
  end

  # RetroArch hands its SRAM to the kernel and never fsyncs it, and this device
  # is switched off by pulling the power. So the launcher fsyncs the saves at
  # the moments it knows nothing is writing to them -- and, just as important,
  # at no other moment. See MayonnaiOS.Saves.
  describe "flushing the saves" do
    setup do
      test = self()
      Application.put_env(:mayonnaios, :programs, [%{path: "/a"}])
      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)

      start_supervised!(
        {Launcher,
         device: "/nonexistent/event0",
         flush_delay: 5,
         flush_saves: fn -> send(test, :flushed) end}
      )

      :ok
    end

    test "when the program exits on its own" do
      # state.port is nil here and the message names nil, so this drives the
      # same clause a real exit drives: it is the reap that triggers the flush.
      send(Launcher, {nil, {:exit_status, 0}})
      assert Launcher.running?() == false
      assert_receive :flushed
    end

    test "shortly after a deliberate stop, because closing the port loses the exit" do
      # Pressing Menu closes the port, which throws away the exit message the
      # clause above waits for. Without the timer, the most ordinary way to
      # leave a game would be the one that never flushes.
      port = spawn_sleeper()
      :sys.replace_state(Launcher, &%{&1 | port: port})

      Launcher.stop_program()
      assert_receive :flushed, 500
    end

    test "not while something is running" do
      # A flush underneath a running program could fsync a save mid-write,
      # which would make a truncation durable -- the one way this mechanism
      # could destroy the thing it exists to protect.
      send(Launcher, :flush_saves)
      Launcher.selected()
      assert_receive :flushed

      # The guard is on the port, so with one open there must be no flush.
      port = spawn_sleeper()
      :sys.replace_state(Launcher, &%{&1 | port: port})

      send(Launcher, :flush_saves)
      Launcher.selected()
      refute_received :flushed

      Launcher.stop_program()
    end

    # A real OS process for the launcher to hold, so the stop path signals
    # something that exists rather than a port with no process behind it.
    defp spawn_sleeper do
      Port.open({:spawn_executable, System.find_executable("sleep")}, [
        :exit_status,
        args: ["30"]
      ])
    end
  end
end
