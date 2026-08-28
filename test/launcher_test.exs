defmodule MayonnaiOS.LauncherTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Browser, Launcher, Programs}
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

  describe "Scene.Home.graph/3" do
    setup do
      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)
      :ok
    end

    test "the root column names the categories" do
      says = texts(Home.graph(Browser.new()))

      for category <- ["Games", "Files", "Apps", "System"] do
        assert category in says
      end
    end

    test "builds the sheets: actions, the confirmation, the rename editor" do
      entry = %{type: :regular, size: 9, link: nil, broken?: false}

      confirm =
        put_in(
          Browser.new().overlay,
          {:confirm, %{location: %{root: "r", path: []}, entry: entry, name: "x"}}
        )

      assert Enum.any?(texts(Home.graph(confirm)), &(&1 =~ "Y deletes it."))

      rename =
        put_in(Browser.new().overlay, {:rename, %{name: "ab", chars: ["a", "b"], caret: 0}})

      assert Enum.any?(texts(Home.graph(rename)), &(&1 =~ "Y removes it."))

      sheet = put_in(Browser.new().overlay, {:actions, [%{id: :delete, label: "Delete x"}], 0})
      assert "Delete x" in texts(Home.graph(sheet))
    end

    test "the breadcrumb names every open level" do
      Application.put_env(:mayonnaios, :programs, [%{path: "/a"}])

      browser = Browser.new() |> Browser.descend()

      assert Enum.any?(texts(Home.graph(browser)), &(&1 =~ "RG40XXV > Games"))
    end

    test "windows the rows so the selection is always drawn" do
      # "It built without raising" is not enough here: Enum.slice returns []
      # for an out-of-range start, so a broken window would still produce a
      # graph -- an empty column that looks like a rendering bug on the device.
      Application.put_env(
        :mayonnaios,
        :programs,
        for(i <- 1..20, do: %{path: "/bin/prog#{i}"})
      )

      browser = Browser.new() |> Browser.descend()

      first = texts(Home.graph(browser))
      assert "prog1" in first
      refute "prog20" in first

      last = texts(Home.graph(Browser.move(browser, 19)))
      assert "prog20" in last
      refute "prog1" in last
    end

    test "says so on the row when a configured path is not in the image" do
      Application.put_env(:mayonnaios, :programs, [%{path: "/usr/bin/definitely-not-here"}])

      graph = Home.graph(Browser.new() |> Browser.descend())
      assert "not installed" in texts(graph)
    end

    test "an empty column says why instead of listing nothing" do
      Application.put_env(:mayonnaios, :programs, [])

      graph = Home.graph(Browser.new() |> Browser.descend())
      assert Enum.any?(texts(graph), &(&1 =~ "Nothing to run"))
    end

    test "the power-off question is on the panel only while it is being asked" do
      asked = texts(Home.graph(Browser.new(), true))
      assert Enum.any?(asked, &(&1 =~ "Power off? Y switches off"))

      idle = texts(Home.graph(Browser.new()))
      refute Enum.any?(idle, &(&1 =~ "Y switches off"))
    end

    test "an obituary quotes the program's dying words" do
      obituary = %{name: "Moonlight", status: 1, lines: ["Can't open configuration file"]}

      says = texts(Home.graph(Browser.new(), false, obituary))
      assert Enum.any?(says, &(&1 =~ "Moonlight exited (1)"))
      assert Enum.any?(says, &(&1 =~ "Can't open configuration file"))

      idle = texts(Home.graph(Browser.new()))
      refute Enum.any?(idle, &(&1 =~ "exited"))
    end

    test "a spawn that raised says would not start, not exited" do
      obituary = %{name: "Doom", status: nil, lines: ["enoent"]}
      says = texts(Home.graph(Browser.new(), false, obituary))

      assert Enum.any?(says, &(&1 =~ "Doom would not start"))
      refute Enum.any?(says, &(&1 =~ "exited"))
    end

    test "the power-off question outranks the obituary" do
      obituary = %{name: "Moonlight", status: 1, lines: ["nope"]}
      says = texts(Home.graph(Browser.new(), true, obituary))

      assert Enum.any?(says, &(&1 =~ "Power off?"))
      refute Enum.any?(says, &(&1 =~ "exited"))
    end

    test "the right pane previews the selection" do
      Application.put_env(:mayonnaios, :programs, [%{path: "/a"}])

      # The cursor is on Games, so the preview pane lists what Games holds.
      assert "a" in texts(Home.graph(Browser.new()))
    end

    test "the full view is one wide column about the selection" do
      Application.put_env(:mayonnaios, :programs, [%{path: "/a"}])

      browser = Browser.new() |> Browser.descend() |> Browser.open_full()
      says = texts(Home.graph(browser))

      assert Enum.any?(says, &(&1 =~ "/a"))
      assert Enum.any?(says, &(&1 =~ "B goes back"))
      # The columns give way to the one wide view.
      refute "Games" in says
    end

    test "the footer labels the buttons for the state on screen" do
      idle = texts(Home.graph(Browser.new()))
      assert Enum.any?(idle, &(&1 =~ "A opens."))

      sheet = put_in(Browser.new().overlay, {:actions, [%{id: :delete, label: "Delete x"}], 0})
      assert Enum.any?(texts(Home.graph(sheet)), &(&1 =~ "A does it."))
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

  describe "the devices it opens" do
    test "starts on a machine with none, and says so" do
      # The host path, and the one the `:device` option in every other test
      # here deliberately steps around. Two lookups happen at boot -- the pad
      # and whatever device the sleep key is on -- and on a laptop both answer
      # `nil`. Neither may be opened, and neither may take the boot down:
      # `File.exists?/1` on a nil raises, and a fallback would hide the nil
      # by handing over a path that merely does not exist.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!(Launcher)
          assert Launcher.selected() == 0
        end)

      assert log =~ "no input devices found"
    end
  end

  describe "the D-pad binding" do
    setup do
      # The Launcher is not in the host supervision tree, and there is no
      # /dev/input here, so it starts with no device and the synthetic events
      # below stand in for the pad. The root column is fixed -- four
      # categories -- so nothing on this host can change what these wrap over.
      programs = [%{path: "/a"}, %{path: "/b"}, %{path: "/c"}]
      Application.put_env(:mayonnaios, :programs, programs)

      # A real directory behind the Files category, for the sheet and paging
      # tests: one file would page nowhere and offer nothing.
      root = Path.join(System.tmp_dir!(), "launcher-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      for i <- 1..12,
          do: File.write!(Path.join(root, "file-#{String.pad_leading("#{i}", 2, "0")}"), "x")

      Application.put_env(:mayonnaios, :file_roots, [%{key: "r", path: root, note: ""}])

      on_exit(fn ->
        File.rm_rf(root)
        Application.delete_env(:mayonnaios, :programs)
        Application.delete_env(:mayonnaios, :file_roots)
      end)

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
      assert Launcher.selected() == 3
    end

    test "autorepeat does not move the cursor" do
      # value 2 is autorepeat, which the event reduce drops: holding the
      # D-pad must not scroll, because every move re-roots the viewport.
      send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, :btn_dpad_down, 2}]})
      assert Launcher.selected() == 0
    end

    test "A opens a category and B closes it" do
      # :btn_b is the button silkscreened A; see the Launcher moduledoc.
      press(:btn_b)

      browser = Launcher.browser()
      assert Browser.depth(browser) == 2
      assert Browser.trail(browser) == ["RG40XXV", "Games"]
      assert Enum.map(List.last(browser.levels).entries, & &1.name) == ["a", "b", "c"]

      press(:btn_a)
      assert Browser.depth(Launcher.browser()) == 1
    end

    test "right opens a column and left closes it, and neither launches" do
      press(:btn_dpad_right)
      assert Browser.depth(Launcher.browser()) == 2

      # Right on a leaf: /a is a program, not a column, and right must not
      # start it -- A is the button that commits.
      press(:btn_dpad_right)
      assert Browser.depth(Launcher.browser()) == 2
      refute Launcher.running?()

      press(:btn_dpad_left)
      assert Browser.depth(Launcher.browser()) == 1
    end

    test "Y opens the actions sheet in a directory, and the sheet has the buttons" do
      # Down onto Files, into the first root, onto its one file.
      press(:btn_dpad_down)
      press(:btn_b)
      press(:btn_b)
      refute Browser.busy?(Launcher.browser())

      press(:btn_x)
      assert Browser.busy?(Launcher.browser())

      # The D-pad now moves the sheet's cursor, not the column's.
      before = Launcher.selected()
      press(:btn_dpad_down)
      assert Launcher.selected() == before

      # Physical B closes the sheet.
      press(:btn_a)
      refute Browser.busy?(Launcher.browser())
    end

    test "Y outside a directory column does nothing" do
      before = Launcher.browser()
      press(:btn_x)

      assert Launcher.browser() == before
    end

    test "the shoulders page the focused column, clamped" do
      press(:btn_dpad_down)
      press(:btn_b)
      press(:btn_b)

      press(:btn_tr)
      assert Launcher.selected() == 10

      press(:btn_tr)
      assert Launcher.selected() == 11

      press(:btn_tl)
      assert Launcher.selected() == 1
    end

    test "A on a file opens the full view, never the actions sheet" do
      # Down onto Files, into the first root, cursor on its first file.
      press(:btn_dpad_down)
      press(:btn_b)
      press(:btn_b)

      press(:btn_b)
      browser = Launcher.browser()
      assert Browser.full?(browser)
      refute Browser.busy?(browser)

      # Physical B closes it, and the columns are back where they were.
      press(:btn_a)
      refute Browser.full?(Launcher.browser())
      assert Browser.depth(Launcher.browser()) == 3
    end

    test "X toggles the full view, and the view has the D-pad while it is up" do
      press(:btn_dpad_down)
      press(:btn_b)
      press(:btn_b)

      # :btn_y is the button silkscreened X; see the Launcher moduledoc.
      press(:btn_y)
      assert Browser.full?(Launcher.browser())

      before = Launcher.selected()
      press(:btn_dpad_down)
      assert Launcher.selected() == before

      press(:btn_y)
      refute Browser.full?(Launcher.browser())
    end

    test "Menu leaves the full view for the root column" do
      press(:btn_dpad_down)
      press(:btn_b)
      press(:btn_b)
      press(:btn_y)
      assert Browser.full?(Launcher.browser())

      press(:btn_mode)
      refute Browser.full?(Launcher.browser())
      assert Browser.depth(Launcher.browser()) == 1
    end

    test "Menu goes back to the root column from deep in the tree" do
      press(:btn_b)
      press(:btn_dpad_down)
      assert Browser.depth(Launcher.browser()) == 2

      press(:btn_mode)
      assert Browser.depth(Launcher.browser()) == 1
    end

    defp press(key) do
      send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, key, 1}]})
      send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, key, 0}]})
      # selected/0 is a call, so it is ordered behind the casts above.
      Launcher.selected()
    end
  end

  # B leaving the readout apps and diagnostics, and staying with the apps
  # that need it. The fake apps at the bottom of this file stand in for the
  # real ones because the real ones want hci0 or a viewport; the contract
  # exercised -- start, stop, input, claims_back? -- is the launcher's whole
  # view of an app either way.
  describe "B as the way back out" do
    setup do
      Process.register(self(), :launcher_test_sink)

      Application.put_env(:mayonnaios, :programs, [
        %{name: "Readout", app: FakeReadout, category: :apps},
        %{name: "Game", app: FakeGame, category: :apps},
        %{name: "BEAM processes", app: {MayonnaiOS.Top, :beam}, category: :apps}
      ])

      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)

      start_supervised!({Launcher, device: "/nonexistent/event0"})

      # Into the Apps column: third category from the top.
      tap(:btn_dpad_down)
      tap(:btn_dpad_down)
      tap(:btn_b)
      :ok
    end

    test "B leaves an app that does not claim it, and the press is swallowed" do
      tap(:btn_b)
      assert :sys.get_state(Launcher).app == FakeReadout

      tap(:btn_a)
      assert_receive {FakeReadout, :stopped}
      assert :sys.get_state(Launcher).app == nil
      assert :sys.get_state(Launcher).scene == :home

      # The press that left never reached the app as input.
      refute_received {FakeReadout, {:input, [{:ev_key, :btn_a, 1}]}}
    end

    test "B stays with an app that claims it" do
      tap(:btn_dpad_down)
      tap(:btn_b)
      assert :sys.get_state(Launcher).app == FakeGame

      tap(:btn_a)
      assert_receive {FakeGame, {:input, [{:ev_key, :btn_a, 1}]}}
      assert :sys.get_state(Launcher).app == FakeGame
      refute_received {FakeGame, :stopped}
    end

    test "X on a process monitor opens the readout itself, and B backs out" do
      tap(:btn_dpad_down)
      tap(:btn_dpad_down)

      tap(:btn_y)
      assert :sys.get_state(Launcher).app == {MayonnaiOS.Top, :beam}

      tap(:btn_a)
      assert :sys.get_state(Launcher).app == nil
    end

    test "B leaves diagnostics for the home screen" do
      # System is one wrap up from Apps' row; simplest is Menu home, then up.
      tap(:btn_mode)
      tap(:btn_dpad_up)
      tap(:btn_b)
      tap(:btn_b)
      assert :sys.get_state(Launcher).scene == :diagnostics

      tap(:btn_a)
      assert :sys.get_state(Launcher).scene == :home
    end
  end

  describe "the Power off row" do
    setup do
      programs = [%{path: "/a"}, %{name: "Power off", action: :poweroff}]
      Application.put_env(:mayonnaios, :programs, programs)
      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)

      test = self()

      start_supervised!(
        {Launcher, device: "/nonexistent/event0", poweroff: fn -> send(test, :powered_off) end}
      )

      # Into System -- the last category -- and down past Diagnostics and
      # Sleep onto the Power off row, which sits last on purpose.
      tap(:btn_dpad_up)
      tap(:btn_b)
      tap(:btn_dpad_down)
      tap(:btn_dpad_down)

      assert Browser.selected(Launcher.browser()).name == "Power off"
      :ok
    end

    test "A only asks; Y answers" do
      tap(:btn_b)
      refute_received :powered_off

      tap(:btn_x)
      assert_receive :powered_off
    end

    test "any other button keeps the device on, and Y afterwards does not switch off" do
      tap(:btn_b)
      tap(:btn_a)

      # The question is gone, so the button that would have answered it is
      # back to its day job of cycling columns.
      tap(:btn_x)
      refute_received :powered_off
    end

    test "the cancelling press is swallowed, not dispatched" do
      tap(:btn_b)
      # A again would re-open the question if it were dispatched -- the cursor
      # is still on the Power off row; here it may only cancel. Y proving no
      # question is up also proves no second question was opened.
      tap(:btn_b)
      tap(:btn_x)
      refute_received :powered_off
    end

    test "Y with no question pending does nothing here" do
      # Settings is not a directory column, so the second verb has nothing to
      # offer -- and it must not switch the device off.
      before = Launcher.browser()
      tap(:btn_x)

      assert Launcher.browser() == before
      refute_received :powered_off
    end

    defp tap(key) do
      send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, key, 1}]})
      send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, key, 0}]})
      # A call, so both casts above have been handled before the test asserts.
      Launcher.selected()
    end
  end

  # Stopping a program, which is the half of the handover that was taken on
  # trust. These tests run real OS processes -- `/bin/sh` blocking on a pipe
  # that nothing writes -- because the thing being asserted is that a *process*
  # is gone, and a fake cannot be gone. The only fake here is for the case no
  # host can produce: a process that survives SIGKILL.
  describe "stopping a program" do
    alias MayonnaiOS.Panel

    setup do
      Unkillable.reset()

      on_exit(fn ->
        Panel.release()
        Unkillable.reset()
      end)

      :ok
    end

    # A program that blocks for ever, and the shape of it matters.
    #
    # It deliberately does not read stdin. The obvious `sh -c` script that
    # waits on a `read` blocks just as well, and it also exits the moment
    # `Port.close/1` shuts the pipe -- so a stop path that only sent SIGTERM
    # and then closed the port would still leave no process behind, and every
    # test below would pass against the bug. RetroArch does not read stdin
    # either, which is the whole point.
    #
    # A short `sleep` in a loop instead. The shell is the port's process and
    # the one these tests signal; a loop iteration's `sleep` can outlive it by
    # up to a second, which is why the sleep is short.
    @blocks_for_ever "while :; do sleep 1; done"

    defp sh(script) do
      [%{name: "sh", path: "/bin/sh", args: ["-c", script]}]
    end

    defp start(script, opts) do
      Application.put_env(:mayonnaios, :programs, sh(script))
      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)

      start_supervised!({Launcher, [device: "/nonexistent/event0"] ++ opts})

      # Into the Games column, where the configured shell is the first row.
      # `launch/0` is A: the first press opens the category, the second runs.
      Launcher.launch()
      Launcher.launch()
      assert Launcher.running?()
      os_pid = Launcher.os_pid()
      assert is_integer(os_pid)

      # The pid has to outlive a test that fails, or a stray process sits on
      # the host holding a pipe for the rest of the run.
      on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)]) end)

      os_pid
    end

    defp drain_observations(acc) do
      receive do
        {:checked, alive, held} -> drain_observations([{alive, held} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp alive?(os_pid) do
      match?(
        {_, 0},
        System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
      )
    end

    defp gone?(os_pid, attempts \\ 100) do
      cond do
        not alive?(os_pid) -> true
        attempts == 0 -> false
        true -> Process.sleep(10) && gone?(os_pid, attempts - 1)
      end
    end

    test "a program that honours SIGTERM is stopped by it" do
      os_pid = start(@blocks_for_ever, term_timeout: 2_000, kill_timeout: 500, poll_ms: 10)

      assert Launcher.stop_program() == :ok
      refute Launcher.running?()
      assert gone?(os_pid)
    end

    test "a program that ignores SIGTERM is killed anyway" do
      # This is RetroArch. It catches SIGTERM -- `SigCgt` bit 15 set, `SigIgn`
      # clear, read off a running one -- and the handler only sets a quit flag
      # that a main loop stuck in poll() never notices. Verified on the device:
      # TERM delivered, four seconds later the process was still there.
      #
      # With a TERM-only stop this test is the whole bug in one line: the
      # launcher says :ok and the process is still alive, still holding the
      # display.
      os_pid =
        start(~s(trap "" TERM; #{@blocks_for_ever}),
          term_timeout: 200,
          kill_timeout: 1_000,
          poll_ms: 10
        )

      assert Launcher.stop_program() == :ok
      assert gone?(os_pid), "the program survived a stop that reported success"
      refute Launcher.running?()
    end

    test "the panel is handed back only after the process is gone" do
      # The repaint is a write to a framebuffer whose DRM master is the program
      # being stopped, so releasing the hold before it dies is the hang this
      # firmware already has a module to prevent. Raised as a follow-up on the
      # panel-ownership PR; asserted here.
      os_pid =
        start(~s(trap "" TERM; #{@blocks_for_ever}),
          term_timeout: 100,
          kill_timeout: 1_000,
          poll_ms: 10
        )

      assert Panel.held?()
      assert Launcher.stop_program() == :ok
      refute Panel.held?()
      assert gone?(os_pid)
    end

    test "the hold is still held every time the OS says the program is alive" do
      # The ordering, asserted from inside the wait rather than from after it.
      # Nothing outside this process can see the interleaving of "release the
      # panel" and "the program is still there", and that interleaving is the
      # bug: a repaint is a write to a framebuffer whose DRM master is the
      # program being stopped.
      Process.register(self(), PanelRecorder)

      os_pid =
        start(~s(trap "" TERM; #{@blocks_for_ever}),
          signals: Watching,
          term_timeout: 150,
          kill_timeout: 1_000,
          poll_ms: 10
        )

      assert Launcher.stop_program() == :ok
      assert gone?(os_pid)

      observations = drain_observations([])

      assert Enum.any?(observations, &match?({true, _held}, &1)),
             "the wait never observed the program alive, so this proves nothing"

      for {alive, held} <- observations, alive do
        assert held, "the panel was handed back while the program was still running"
      end
    end

    test "a program that survives SIGKILL is not reported as stopped" do
      # No host can produce one -- a process that ignores SIGKILL is wedged in
      # a driver -- so the signals seam stands in for the operating system and
      # simply never lets go.
      os_pid =
        start(@blocks_for_ever,
          signals: Unkillable,
          term_timeout: 60,
          kill_timeout: 60,
          poll_ms: 10
        )

      assert Launcher.stop_program() == {:error, {:still_running, os_pid}}

      # The program still has the display, so the launcher must not claim
      # otherwise and must not draw.
      assert Launcher.running?()
      assert Panel.held?()
      assert alive?(os_pid)
    end

    test "a stop that failed can be retried, and the retry works" do
      # Which is the reason nothing is torn down on the failure path: the port
      # is still open and the pid is still known, so Menu is still the way out.
      os_pid =
        start(@blocks_for_ever,
          signals: Unkillable,
          term_timeout: 60,
          kill_timeout: 60,
          poll_ms: 10
        )

      assert Launcher.stop_program() == {:error, {:still_running, os_pid}}

      # The seam now behaves like an operating system again.
      Unkillable.relent()

      assert Launcher.stop_program() == :ok
      refute Launcher.running?()
      assert gone?(os_pid)
    end
  end

  # A program that exits in its first hundred milliseconds is invisible from
  # the couch -- the panel flashes and the menu is back, with the reason only
  # in the ring logger. These run real processes for the same reason the stop
  # tests do: the thing asserted is what an exit status and a pipe actually
  # deliver, and a fake delivers whatever the test wants to hear.
  describe "why a program died" do
    alias MayonnaiOS.Panel

    setup do
      on_exit(fn ->
        Panel.release()
        Application.delete_env(:mayonnaios, :programs)
      end)

      :ok
    end

    defp run(script) do
      Application.put_env(:mayonnaios, :programs, [
        %{name: "sh", path: "/bin/sh", args: ["-c", script]}
      ])

      start_supervised!({Launcher, device: "/nonexistent/event0"})

      # A twice: into the Games column, then the shell on its first row.
      Launcher.launch()
      Launcher.launch()
    end

    defp reaped?(attempts \\ 500) do
      cond do
        not Launcher.running?() -> true
        attempts == 0 -> false
        true -> Process.sleep(10) && reaped?(attempts - 1)
      end
    end

    test "a nonzero exit leaves an obituary quoting the last lines" do
      run("echo one; echo nope; exit 3")
      assert reaped?()

      assert %{name: "sh", status: 3, lines: lines} = Launcher.obituary()
      assert "nope" in lines
    end

    test "a clean exit leaves nothing" do
      run("echo fine; exit 0")
      assert reaped?()
      assert Launcher.obituary() == nil
    end

    test "a deliberate stop leaves nothing, whatever the exit status" do
      # SIGTERM ends this shell with a nonzero status; the point is that a
      # stop the user asked for is not a death worth reporting.
      run("while :; do sleep 1; done")
      assert Launcher.stop_program() == :ok
      assert Launcher.obituary() == nil
    end

    test "B takes it off, the D-pad leaves it alone" do
      run("exit 5")
      assert reaped?()
      assert %{status: 5} = Launcher.obituary()

      tap_key(:btn_dpad_down)
      assert %{status: 5} = Launcher.obituary()

      # Physical B is BTN_SOUTH, which InputEvent reports as :btn_a -- the
      # launcher moduledoc's table is the authority on that swap.
      tap_key(:btn_a)
      assert Launcher.obituary() == nil
    end

    defp tap_key(key) do
      send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, key, 1}]})
      send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, key, 0}]})
      # A call, so both casts above have been handled before the test asserts.
      Launcher.selected()
    end
  end

  # RetroArch hands its SRAM to the kernel and never fsyncs it, and this device
  # is switched off by pulling the power. So the launcher fsyncs the saves at
  # the two moments a program is *confirmed* gone -- and, just as important, at
  # no other moment. Same harness as the stop tests above, because "confirmed
  # gone" is exactly what that machinery decides. See MayonnaiOS.Saves.
  describe "flushing the saves" do
    alias MayonnaiOS.Panel

    setup do
      Unkillable.reset()

      on_exit(fn ->
        Panel.release()
        Unkillable.reset()
      end)

      :ok
    end

    defp flushing do
      test = self()
      [flush_saves: fn -> send(test, :flushed) end]
    end

    test "when the program exits on its own" do
      # A real reap: the process is killed from outside the launcher, so the
      # port's :exit_status arrives the way it does when a game quits itself.
      os_pid =
        start(@blocks_for_ever, flushing() ++ [term_timeout: 500, poll_ms: 10])

      System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])

      assert_receive :flushed, 2_000
      assert gone?(os_pid)
    end

    test "when a deliberate stop has confirmed the process is gone" do
      # Pressing Menu. The flush is in finish_stop/1, which is only reached
      # once do_stop/1 knows the process has died -- so this is the ordinary
      # way out of a game, and it is durable.
      os_pid = start(@blocks_for_ever, flushing() ++ [term_timeout: 2_000, poll_ms: 10])

      assert Launcher.stop_program() == :ok
      assert_receive :flushed
      assert gone?(os_pid)
    end

    test "not when the program survived the kill and could still be writing" do
      # The guard that matters, and the reason the flush is not simply "after
      # we asked it to stop": fsyncing a save a live RetroArch is in the middle
      # of writing can make its truncation durable and its contents not, which
      # is the one way this mechanism could destroy what it exists to protect.
      os_pid =
        start(
          @blocks_for_ever,
          flushing() ++ [signals: Unkillable, term_timeout: 60, kill_timeout: 60, poll_ms: 10]
        )

      assert Launcher.stop_program() == {:error, {:still_running, os_pid}}

      refute_received :flushed
      assert alive?(os_pid)
    end
  end
end

# The launcher's app contract with nothing behind it: starts a process that
# idles, reports its stops and its inputs to whichever test registered itself
# as the sink. One does not claim B and one does, which is the difference
# under test.
defmodule FakeReadout do
  def start, do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}
  def stop, do: notify(:stopped)
  def input(events), do: notify({:input, events})
  def scene, do: nil

  defp notify(message) do
    if pid = Process.whereis(:launcher_test_sink), do: send(pid, {__MODULE__, message})
    :ok
  end
end

defmodule FakeGame do
  def start, do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}
  def stop, do: notify(:stopped)
  def input(events), do: notify({:input, events})
  def scene, do: nil
  def claims_back?, do: true

  defp notify(message) do
    if pid = Process.whereis(:launcher_test_sink), do: send(pid, {__MODULE__, message})
    :ok
  end
end

# An operating system that will not kill anything: signals are accepted and
# dropped, and the process is always still there. Toggled through an agent-free
# persistent term so the launcher process and the test see the same answer.
defmodule Unkillable do
  @behaviour MayonnaiOS.Launcher.Signals

  @key {__MODULE__, :relented?}

  def relent, do: :persistent_term.put(@key, true)
  def reset, do: :persistent_term.erase(@key)

  @impl MayonnaiOS.Launcher.Signals
  def signal(signal, os_pid) do
    if relented?(), do: MayonnaiOS.Launcher.Kill.signal(signal, os_pid), else: :ok
  end

  @impl MayonnaiOS.Launcher.Signals
  def alive?(os_pid) do
    if relented?(), do: MayonnaiOS.Launcher.Kill.alive?(os_pid), else: true
  end

  defp relented?, do: :persistent_term.get(@key, false)
end

# An operating system that answers honestly and says what the panel looked like
# at the moment it was asked. The only way to see the order of two things that
# both happen inside one call.
defmodule Watching do
  @behaviour MayonnaiOS.Launcher.Signals

  @impl MayonnaiOS.Launcher.Signals
  defdelegate signal(signal, os_pid), to: MayonnaiOS.Launcher.Kill

  @impl MayonnaiOS.Launcher.Signals
  def alive?(os_pid) do
    alive = MayonnaiOS.Launcher.Kill.alive?(os_pid)

    if pid = Process.whereis(PanelRecorder) do
      send(pid, {:checked, alive, MayonnaiOS.Panel.held?()})
    end

    alive
  end
end
