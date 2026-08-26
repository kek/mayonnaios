defmodule MayonnaiOS.PanelTest do
  # Not async: it starts a viewport, a launcher and a driver, all of which are
  # named, and it writes the application environment.
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Launcher, Panel, Status}
  alias MayonnaiOS.Scene.StatusBar

  # A driver that records what the ViewPort asked it to draw, and nothing else.
  #
  # This is the framebuffer as far as this file is concerned. On the device the
  # driver at this seam is scenic_driver_local's cairo-fb, and `update_scene/2`
  # is the callback in which it writes `/dev/fb0` -- the write that hangs the
  # board while RetroArch holds DRM master. So a test that asserts nothing
  # arrives here is asserting the thing that actually went wrong, one layer
  # closer to the hardware than "no push_graph".
  #
  # `reset_scene/1` counts as a write too: it is what the ViewPort sends when
  # the root scene is replaced, and re-rooting repaints the whole panel.
  defmodule Recorder do
    use Scenic.Driver

    @impl Scenic.Driver
    def validate_opts(opts), do: {:ok, opts}

    @impl Scenic.Driver
    def init(driver, opts), do: {:ok, Scenic.Driver.assign(driver, test: opts[:test])}

    @impl Scenic.Driver
    def reset_scene(driver) do
      send(driver.assigns.test, {:panel_write, :reset_scene})
      {:ok, driver}
    end

    @impl Scenic.Driver
    def update_scene(ids, driver) do
      send(driver.assigns.test, {:panel_write, ids})
      {:ok, driver}
    end
  end

  setup do
    # The hold lives in the VM, not in a process, so it outlives a test that
    # set it. Cleared on both sides: a leaked hold would make every later test
    # in this run pass for the wrong reason.
    Panel.release()
    on_exit(&Panel.release/0)
    :ok
  end

  describe "who owns the panel" do
    test "nobody, until a program is launched" do
      assert Panel.owner() == :ui
      refute Panel.held?()
    end

    test "a program by name, and then nobody again" do
      assert Panel.hold("RetroArch") == :ok
      assert Panel.owner() == {:program, "RetroArch"}
      assert Panel.held?()

      assert Panel.release() == :ok
      assert Panel.owner() == :ui
      refute Panel.held?()
    end

    test "a launcher that has just started owns nothing" do
      # The recovery path for a hold whose holder died. The launcher is the
      # only writer, so if it goes down mid-game there is nothing else that
      # would ever clear the term -- and a panel nobody may draw on is a dead
      # device with no explanation on it.
      Panel.hold("kmscube")
      start_supervised!({Launcher, device: "/nonexistent/event0"})

      refute Panel.held?()
    end
  end

  describe "the status bar while a program owns the panel" do
    setup :one_screen

    test "a battery percent that moves does not reach the panel", %{bar: bar} do
      Panel.hold("RetroArch")
      settle()

      send(bar, {:mayonnaios_status, reading(41)})

      refute_write("a battery reading arriving during a game")
    end

    test "a reading going stale does not reach the panel", %{bar: bar} do
      # The reason pausing `MayonnaiOS.Status` would not have been a fix. This
      # reading is older than the six-second window, so the fields collapse to
      # the `no reading` form -- a change, produced by nothing but the passage
      # of time, and drawn by the `:tick` handler. The bar still knocks on the
      # reader while it is stale; knocking is a message and costs no pixels.
      Panel.hold("RetroArch")
      settle()

      send(bar, {:mayonnaios_status, reading(62, System.monotonic_time(:millisecond) - 7_000)})
      send(bar, :tick)

      refute_write("a reading going stale during a game")
    end

    test "a tick that finds something to draw does not draw it", %{bar: bar} do
      # How the clock reaches the panel: once a minute a `:tick` finds that
      # the fields differ from what was drawn, and pushes. There is no way to
      # step the wall clock from here, so the difference is made with a
      # reading instead -- the tick is the same tick, and the push it would
      # produce is the same push. That the minute really is one of the fields
      # a tick compares is asserted below.
      Panel.hold("RetroArch")
      settle()

      send(bar, {:mayonnaios_status, reading(41)})
      send(bar, :tick)
      send(bar, :tick)

      refute_write("a clock tick during a game")
    end

    test "the minute is one of the fields a tick compares" do
      {:ok, before} = DateTime.new(~D[2026-08-22], ~T[14:32:59], "Etc/UTC")
      {:ok, later} = DateTime.new(~D[2026-08-22], ~T[14:33:00], "Etc/UTC")

      refute StatusBar.fields(nil, utc: before) == StatusBar.fields(nil, utc: later)
    end

    test "the same reading does reach the panel when no program is running", %{bar: bar} do
      # The control. Without this the three tests above would pass on a bar
      # that had simply stopped working, and the seam they assert on would be
      # asserting nothing.
      send(bar, {:mayonnaios_status, reading(41)})

      assert_write("a battery reading with the panel free")
    end

    test "the bar is drawing again after the program exits", %{bar: bar, viewport: viewport} do
      Panel.hold("RetroArch")
      settle()
      send(bar, {:mayonnaios_status, reading(41)})
      refute_write("a reading during the game")

      # What the launcher does when it reaps the program: release, then
      # re-root. `set_root/3` stops the running scene and starts a fresh one,
      # so the bar that comes back is a new process -- asserted here rather
      # than assumed, because if it were the *same* process the resume would
      # need an explicit push to undo the frame it suppressed.
      Panel.release()
      :ok = Scenic.ViewPort.set_root(viewport, MayonnaiOS.Scene.Home, %{selected: 0})

      resumed = wait_for_bar(MapSet.new([bar]))
      refute resumed == bar

      assert_write("the repaint on the way back from a game")

      # And it is a bar that draws, not just a bar that exists.
      drain()
      send(resumed, {:mayonnaios_status, reading(17)})
      assert_write("a reading after the program exited")
      assert eventually(fn -> drawn(resumed).battery.percent == "17%" end)
    end
  end

  describe "the diagnostics screen while a program owns the panel" do
    test "refreshes without drawing, and is repainted on the way back" do
      # The other route to the same hang, and the worse one: this screen
      # rebuilds its graph once a second rather than once a minute. Somebody
      # can press A here to start a game, or X during one, and the scene stays
      # alive with its timer running.
      %{viewport: viewport} = start_viewport(MayonnaiOS.Scene.Diagnostics, nil)

      Panel.hold("kmscube")
      settle()

      # Long enough for two refreshes. Unguarded, the first one lands within a
      # second: measured on this test's own driver.
      refute_write("the diagnostics refresh during a game", 2_200)

      Panel.release()
      :ok = Scenic.ViewPort.set_root(viewport, MayonnaiOS.Scene.Diagnostics, nil)

      assert_write("the repaint on the way back")
    end

    test "its refresh restarts the bar, which is why the hold cannot be a subscription" do
      # The measurement behind `MayonnaiOS.Panel`'s design note, kept as a
      # test because it is invisible from the outside and it is the reason the
      # suppression is a synchronous read.
      #
      # Scenic restarts a component when its parent scene pushes a graph, and
      # this screen pushes once a second -- so the status bar on the
      # diagnostics screen is a new process every second. A flag delivered by
      # notification would not survive that: each new instance would start out
      # knowing nothing and draw in `init/3` before it could be told.
      %{bar: bar} = start_viewport(MayonnaiOS.Scene.Diagnostics, nil)

      assert eventually(fn -> Enum.any?(bars(), &(&1 != bar)) end, 150)
      refute Process.alive?(bar)
    end
  end

  describe "an app is not an external program" do
    test "the bar keeps drawing while an app is on screen" do
      # The other direction of the same distinction. An app is a Scenic scene
      # in this VM: it takes no display away from anything, so a bar with a
      # frozen clock on the process readout would be this fix overreaching.
      %{bar: bar} = start_viewport(MayonnaiOS.Scene.Top, %{error: nil})

      refute Panel.held?()
      send(bar, {:mayonnaios_status, reading(41)})

      assert_write("a reading while an app is on screen")
    end
  end

  describe "the launcher while a program owns the panel" do
    setup do
      program = %{name: "sleeper", path: System.find_executable("cat")}
      Application.put_env(:mayonnaios, :programs, [program])
      on_exit(fn -> Application.delete_env(:mayonnaios, :programs) end)

      context = one_screen(%{})

      # The launcher finds the viewport by the name in the configuration, so
      # without this its repaints go nowhere -- and a test asserting that a
      # repaint did not happen would pass on a launcher that could never
      # repaint anything.
      Application.put_env(:mayonnaios, :viewport,
        name: context.name,
        default_scene: MayonnaiOS.Scene.Home
      )

      on_exit(fn -> Application.delete_env(:mayonnaios, :viewport) end)

      start_supervised!({Launcher, device: "/nonexistent/event0"})

      context
    end

    test "does not re-root the viewport, and repaints when the program exits" do
      # `cat` with no arguments stands in for RetroArch: a real external
      # process, spawned the same way through `Port.open/2`, that stays up
      # until it is killed. What it draws is irrelevant -- the launcher's job
      # here is not drawing. `launch/0` is A: the first press opens the Games
      # column, the second runs its first row.
      Launcher.launch()
      Launcher.launch()
      assert Panel.owner() == {:program, "sleeper"}
      settle()

      # X, which flips between the menu and diagnostics. During a game it
      # must not re-root the viewport and paint a whole screen into a
      # framebuffer the game owns.
      press(:btn_y)
      assert :sys.get_state(Launcher).scene == :diagnostics
      refute_write("pressing X during a game")

      # And Menu out of the game: the hold is lifted and the screen X asked
      # for is finally painted.
      Launcher.stop_program()
      refute Panel.held?()
      assert_write("the repaint after the program was stopped")
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp one_screen(_context), do: start_viewport(MayonnaiOS.Scene.Home, %{selected: 0})

  # A real ViewPort with the recording driver, and the bar the root scene
  # mounted. Torn down on the way out so that nothing here leaves a subscriber
  # behind for another test file to count.
  defp start_viewport(scene, param) do
    # Under the test supervisor rather than linked to the test process, so it
    # is *stopped* between tests instead of being left to die on its own. A
    # `Scenic.start_link/1` that races the previous test's teardown gets
    # `{:already_started, pid}` for a `:scenic` that is already on its way
    # down, and the viewport start that follows then finds no supervisor.
    start_supervised!({Scenic, []})

    before = bars()
    name = :"panel_test_viewport_#{System.unique_integer([:positive])}"

    {:ok, viewport} =
      Scenic.ViewPort.start(%{
        name: name,
        size: {640, 480},
        default_scene: {scene, param},
        drivers: [[module: Recorder, test: self()]]
      })

    # `Scenic.start_link/1` links to whoever called it, which here is the test
    # process, so Scenic and everything under it is already on its way down by
    # the time this runs. Stopping the viewport is belt and braces for the
    # case where it is not, and must not itself fail the test.
    on_exit(fn ->
      try do
        Scenic.ViewPort.stop(viewport)
      catch
        :exit, _reason -> :ok
      end
    end)

    bar = wait_for_bar(before)
    settle()

    %{viewport: viewport, name: name, bar: bar}
  end

  defp press(key) do
    send(Launcher, {:input_event, "/nonexistent/event0", [{:ev_key, key, 1}]})
    # A call, so it is ordered behind the message above.
    Launcher.selected()
  end

  # One reading in the shape `MayonnaiOS.Status` sends, so what the bar is
  # asked to draw is what the reader would really hand it.
  defp reading(capacity, at \\ nil) do
    at = at || System.monotonic_time(:millisecond)

    %{
      battery: %{value: %{capacity: capacity, status: "Discharging"}, error: nil, at: at},
      wifi: %{value: :internet, error: nil, at: at},
      at: at
    }
  end

  defp drawn(bar), do: :sys.get_state(bar).assigns.drawn

  defp bars,
    do: Status |> :sys.get_state() |> Map.fetch!(:subscribers) |> Map.keys() |> MapSet.new()

  # The one bar that is not in `exclude`. Which bar is which matters here: the
  # question this file has to answer is whether the bar after a program exits
  # is the same process as the bar before it.
  defp wait_for_bar(exclude, attempts \\ 100) do
    case MapSet.difference(bars(), exclude) |> MapSet.to_list() do
      [pid] ->
        pid

      _other when attempts > 0 ->
        Process.sleep(20)
        wait_for_bar(exclude, attempts - 1)

      other ->
        flunk("expected exactly one new status bar, found #{inspect(other)}")
    end
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts > 0 -> Process.sleep(20) && eventually(check, attempts - 1)
      true -> false
    end
  end

  # Let whatever is already in flight land, then forget it. Everything after
  # this is attributable to the thing the test did next.
  defp settle do
    Process.sleep(80)
    drain()
  end

  defp drain do
    receive do
      {:panel_write, _ids} -> drain()
    after
      0 -> :ok
    end
  end

  defp refute_write(what, timeout \\ 250) do
    receive do
      {:panel_write, ids} ->
        flunk("#{what} wrote the panel (#{inspect(ids)}) while a program owned the display")
    after
      timeout -> :ok
    end
  end

  defp assert_write(what, timeout \\ 2_000) do
    receive do
      {:panel_write, _ids} -> :ok
    after
      timeout -> flunk("#{what} did not reach the panel")
    end
  end
end
