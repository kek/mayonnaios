defmodule MayonnaiOS.Launcher do
  @moduledoc """
  Runs an external program on a button press and stops it on another.

  This is the games-appliance mechanic in miniature: the Elixir UI hands the
  screen to another process, that process draws on the GPU, and the UI takes
  the screen back when it exits. kmscube stands in for an emulator here.

  ## Which button is which

  The physical A button is **not** `:btn_a`. Linux defines `BTN_A == BTN_SOUTH
  == 0x130` and `BTN_B == BTN_EAST == 0x131`, and InputEvent decodes by code,
  so its `:btn_a` means "south". This board follows the Nintendo layout, and
  its device tree puts A on the east position:

      Action-Pad A    305   BTN_EAST     -> InputEvent :btn_b
      Action-Pad B    304   BTN_SOUTH    -> InputEvent :btn_a
      Key Start       315   BTN_START    -> InputEvent :btn_start

  Read back from `/sys/firmware/devicetree/base/gpio-keys-gamepad/*/label`
  and `linux,code` on the device, not inferred. Binding `:btn_a` for "A" would
  silently bind the B button, and nothing about the failure would say so.

  ## Giving the screen back

  Scenic only writes `/dev/fb0` when its graph changes, so after the external
  program exits the panel still shows whatever that program left there. The
  viewport has to be told to repaint; `Scenic.ViewPort.set_root/3` does it.

  ## Taking the screen away, which is the harder half

  The sentence above is also a promise this module has to keep: *while the
  program runs, nothing in this VM may change a graph.* The scene is left
  alive and simply stops changing, which is why there is no compositor and no
  bar over a game -- and why the panel belongs to the program until it exits.

  Leaving the scene alive is not the same as leaving it quiet. Two things in
  this firmware draw on their own clock: `MayonnaiOS.Scene.StatusBar`, whose
  clock turns over once a minute on every screen, and
  `MayonnaiOS.Scene.Diagnostics`, which refreshes once a second. Either one
  writing `/dev/fb0` while RetroArch holds DRM master hangs this board --
  observed on hardware, not inferred.

  So "a program owns the panel" is a fact rather than an implication, and it
  lives in `MayonnaiOS.Panel`. This module is its only writer: it holds
  before `Port.open/2` and releases when the program is reaped, which is the
  same pair of moments that already bracket the handover. Everything that
  draws consults it. The input boundary also ignores ordinary navigation and
  actions while the external port exists. Only Menu stop, Select+Menu
  poweroff, Power/lid sleep, and wake-on-any-press remain global; a wake press
  is consumed. The repaint gates remain independent framebuffer safety, not
  permission to mutate hidden browser state.

  ## Giving the screen back requires the program to actually be dead

  The other half of that promise: a program is not stopped because it was
  sent a signal. RetroArch catches SIGTERM and its handler only sets a flag
  for a main loop that may never look again, so `kill -TERM` on a hung one
  returns 0 having achieved nothing -- while the process keeps
  `/dev/dri/card0` open. A launcher that reports it stopped anyway makes
  every later launch fail with `[KMS] Error when switching mode`, which reads
  as a display bug in a completely different place.

  So the stop path escalates to SIGKILL, waits for the process to be gone, and
  only then releases the hold and repaints. `do_stop/1` has the detail; the
  part that belongs up here is that "the program owns the panel until it
  exits" means *exits*, not *was asked to*.

  ## Getting the saves onto the card

  A program being *confirmed* gone is also the only moment this VM knows that
  nobody is writing to RetroArch's save files, and on a handheld switched off
  by pulling its power that moment is worth using: RetroArch flushes the SRAM
  to the kernel and never fsyncs it. So both places this module learns that a
  program has stopped -- the reap above and `finish_stop/1` -- call
  `MayonnaiOS.Saves.flush/1`, and the path that could *not* confirm it, the
  one that returns `{:error, {:still_running, pid}}`, deliberately does not.

  That is the same distinction the panel hold turns on, and it is load-bearing
  for the same kind of reason: fsyncing a file a live program is still writing
  can make a truncation durable and its contents not. `MayonnaiOS.Saves` has
  the account.

  ## The full set of bindings

      D-pad up/down   move the cursor in the focused column
      D-pad right     open the selected entry as another column
      D-pad left      close a column
      L1 / R1         page the focused column a screenful at a time
      A               open the selected entry: enter a directory, launch a
                      program, or -- on a file -- open its full view, which
                      is what "open" means for the one thing that cannot be
                      entered or run
      B               go back: close the full view, a sheet or a column;
                      first, clear an obituary. B also leaves the apps that
                      are readouts and the diagnostics screen -- but never
                      an app that needs B for itself, the controller and
                      the pickles; see `claims_back?/1`
      X               toggle the full view: one wide column about the
                      selected entry -- a detailed listing, a text viewer,
                      the image, a hexdump. On a process monitor it opens
                      the readout app, which is that row's detailed view
      Y               the second verb, and the panel says what it is: the
                      actions sheet in a directory -- Y and only Y, A never
                      opens it -- the delete on its confirmation, and
                      remove-a-character in the rename editor
      Menu            go back to the home screen, at its root column
      Power           sleep -- backlight off and low-power, any press wakes it
      Select+Menu     power off

  While the browser has a sheet up -- actions, a delete confirmation, the
  rename editor -- `MayonnaiOS.Browser.busy?/1` is true and every pad button
  is routed to `Browser.overlay_input/2` instead of the bindings above, so a
  D-pad press cannot both move a caret and a cursor. The full view is the
  same arrangement through `Browser.full_input/2`: the directions scroll it
  and B closes it. Menu and the power-off chord stay the launcher's in both
  cases, because "put me back where I started" must not depend on what is on
  the panel.

  These are the buttons as printed on the shell. Two of the atoms above name
  the opposite button; see the note on the attributes below.

  Menu is the one way back. It stops a running program if there is one and
  otherwise leaves diagnostics, so the same press always means the same thing
  -- "put me back where I started" -- rather than depending on what is
  currently on the panel. One key does all the stopping, so "get out of this"
  is never split across keys by which kind of thing you are in.

  Select+Menu powers off, so the chord is checked before the plain press.
  Switching off from the menu is immediate: the launcher replaces the UI with
  the boot splash and then calls `Nerves.Runtime.poweroff/0`. The splash makes
  the accepted press visible during the short orderly-shutdown interval and
  avoids leaving a live-looking menu on a device that is already going down.
  Select+Menu reaches the same power-off function without redrawing first.

  ## Sleep, and the press that wakes it

  The power button turns the backlight off; `MayonnaiOS.Sleep` owns both the
  mechanism and the choice of key, including why it is that button and why
  sleep is not suspend. `MayonnaiOS.LowPower` is everything else that goes
  quiet with it -- the renderer, WiFi, the governor and three of the four
  cores -- and this process holds its undo list in `low_power` so that waking
  puts each back in reverse.

  The same mechanism runs after three minutes without a real button press on
  the home launcher. Autorepeat does not buy another interval, charging does
  not time out, and neither an external program nor a BEAM app has an idle
  timer: still controls can be active use in all three cases. Returning to the
  launcher starts a fresh interval rather than inheriting time spent away.

  What belongs here is the other half: while the panel is dark, **the next
  press is consumed**. Waking is not a binding of its own -- any button wakes,
  which is the only thing someone holding a dark handheld can be expected to
  discover -- and the press that wakes must not also do what it usually does.
  The failure that rule prevents is small and infuriating: pressing A to see
  the screen again and having the launcher start a game.

  The held set is cleared at the same time, so a key that was down when the
  device woke cannot become half of a chord it was never meant to complete.

  Two limits, both deliberate. The volume rocker does not wake it, because
  `MayonnaiOS.Diagnostics` owns that input device and the Launcher never sees
  its events. And a running *program* has its own file descriptor on the pad:
  it goes on running with the panel dark, and the press that wakes the device
  reaches it too. Only the launcher's own bindings can be swallowed, which is
  the half that would have launched something.

  An app running in this VM is not a limit: the sleep binding is taken out of
  the report before the app sees it. Three reasons, in the order that decides
  it. The key is not on the pad at all, so this is not the launcher reaching
  into a button an app might want. `MayonnaiOS.Controller.Report` describes
  fifteen gamepad keys and `KEY_POWER` is not one of them, so forwarding it
  means it is dropped on the floor -- and a power button that does nothing
  while the controller screen is open is exactly the failure this codebase
  keeps naming. And it matches waking: the sleeping clause below is tested
  before the app clause, so *waking* is the launcher's whoever has the
  buttons, and sleeping behaves the same.

  That is a property of a one-key binding rather than of the mechanism. Move
  `MayonnaiOS.Sleep`'s `@binding` onto a pad chord and an app loses those
  keys, which is a reason to leave it on a key no app wants.

  This process owns the gamepad and the power key's device, so everything on
  the pad is bound here even when it belongs to something else.
  `MayonnaiOS.Diagnostics` owns the rocker and the jack for the same reason in
  reverse.

  ## Where the menu lives, and why the browser is here

  The home screen is a column browser -- `MayonnaiOS.Browser`, whose root
  column is the categories and whose deeper columns are whatever was opened:
  games, pickles, settings, or the file tree. The browser -- which columns
  are open and which row each cursor is on -- is state in this process rather
  than in the scene, for two reasons that are both about how this device is
  put together.

  First, the cairo-fb driver delivers no input. The gamepad reaches Elixir
  only through `InputEvent` on the `gpio-keys-gamepad` node, which this
  process opens, so a Scenic scene on this hardware can never receive a D-pad
  press at all.

  Second, `Scenic.ViewPort.set_root/3` stops the running scene and starts a
  fresh one. This module calls it after every program exit (that is how the
  panel gets repainted), so a selection held in the scene would reset to the
  top every time someone came back from a game -- the one moment it most
  obviously should not.

  So the browser is pushed *into* the scene as the `set_root/3` argument, and
  the scene renders it and owns nothing.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.{
    AutoSleep,
    Browser,
    Device,
    Files,
    Game,
    Input,
    Led,
    LowPower,
    Panel,
    Power,
    Sleep,
    Splash,
    Theme
  }

  # The name the driver gives the gamepad, which is the only thing this module
  # knows about which device it is. There is no numbered fallback: /dev/input
  # numbering is probe order, and `event0` is the power key -- the one device
  # on the board with no gamepad buttons on it. See `MayonnaiOS.Input`.

  # The analog stick. Opened for the same reason as the power key -- evdev is
  # not a broadcast, so a device nobody holds open is a device whose events
  # nobody sees. The launcher itself does nothing with `ev_abs`: its own
  # handlers ignore them, and the one consumer is the controller app, which
  # gets them through the same forwarding as everything else.

  # See the moduledoc: this is physical A, not the atom's name.

  # X and Y are swapped too, and the device tree does not admit it.
  #
  # The DT labels look self-consistent -- "Action-Pad X" 307 and "Action Pad
  # Y" 308, and Linux has BTN_X == BTN_NORTH == 307 and BTN_Y == BTN_WEST ==
  # 308 -- but pressing the buttons says otherwise. The button silkscreened X
  # emits 308 and the one silkscreened Y emits 307: the DT's X/Y labels are
  # the wrong way round for this board's shell, the same way A and B are.
  #
  # So :btn_x below really is the Y button, and :btn_y -- physical X -- is
  # bound to nothing.
  #
  # Y (:btn_x) is the second verb, and the panel says what it is: the actions
  # sheet in a directory, the delete on a confirmation, and
  # remove-a-character in the rename editor.

  # Physical X, which the device tree's swap makes :btn_y -- the note above.
  # X toggles the full view: the wide column about the selected entry.

  # Menu, doing double duty: alone it is the way back to the home screen,
  # and held with Select it powers off. The chord is tested first.

  # The D-pad. Codes 544-547 are BTN_DPAD_UP..RIGHT, and InputEvent decodes
  # them to these atoms (deps/input_event types table). Unlike the face
  # buttons there is no name collision to fall into here -- but the codes came
  # off this board's device tree, which has already lied once about X and Y,
  # so the catch-all `bound/2` logs unhandled keys at debug: if up and down
  # turn out to be swapped, `log_attach_all(:debug)` on the device says so
  # immediately instead of leaving a menu that scrolls the wrong way.

  # Left and right walk the columns: right opens the selected entry as a new
  # column and left closes one. Right never launches -- A is the button that
  # commits -- so walking the tree with the directions cannot start a game.

  # The shoulders page the focused column a screenful at a time. Autorepeat
  # is dropped on this menu (each move re-roots the viewport), so a directory
  # of two hundred ROMs needs a faster step than one row per press, and the
  # shoulders are the two buttons a handheld rests fingers on anyway.

  # Physical B, which is BTN_SOUTH and therefore InputEvent's :btn_a -- the
  # table at the top of this module is the authority. The "back" gesture
  # everywhere: it clears an obituary, closes the full view, a sheet or a
  # column, and leaves the readout apps and diagnostics.

  # How many of a program's last lines the obituary keeps. Three is what the
  # panel has room to draw without pushing into the menu rows.
  @obituary_lines 3

  # How long a stop waits for the program to go, per signal. See `do_stop/1`.
  #
  # SIGTERM gets the larger share because a program that honours it has work to
  # do first -- RetroArch flushes SRAM and saves its config on the way out --
  # and killing it in the middle of that loses a save. SIGKILL is not a
  # request, so the second wait is only the time the kernel needs to tear the
  # process down and the VM needs to reap it.
  #
  # Both are ceilings rather than costs. A program that exits on TERM is gone
  # in milliseconds and the wait ends when its exit arrives, not when the clock
  # runs out; only a program that has stopped listening pays the full three
  # seconds, and that program was going to cost a reboot.
  @term_timeout 2_000
  @kill_timeout 1_000

  # How often the wait asks the OS whether the process is still there, in
  # between watching for the port's exit message. Small enough that the normal
  # path is not noticeably slower than fire-and-forget.
  @poll_ms 50

  # The launcher is the only screen where inactivity means nobody is using
  # the device. Programs and BEAM apps can sit untouched while somebody
  # watches or uses another controller, so they disable this timer entirely.
  @idle_sleep_ms :timer.minutes(3)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether the external program is running right now.
  """
  def running?, do: GenServer.call(__MODULE__, :running?)

  @doc """
  The OS pid of the running program, or `nil`.

  `MayonnaiOS.Diagnostics` uses this to read GPU busy time out of that
  process's `fdinfo`. Scanning every process for a panfrost fd would cost
  thousands of procfs reads a second on this SoC, and it is unnecessary:
  Scenic renders on the CPU through cairo, so the program launched here is
  the only GPU client there is.
  """
  def os_pid, do: GenServer.call(__MODULE__, :os_pid)

  @doc """
  Press A from a console, without pressing anything: open the selected
  entry as a column, or launch it.

  `stop_program/0` returns `:ok` only when the OS process is confirmed gone.
  A program that survives both SIGTERM and SIGKILL comes back as
  `{:error, {:still_running, os_pid}}` and is still on the display -- see
  `do_stop/1` for why that is reported rather than tidied over.

  It blocks while it waits, which is a call that can take a couple of seconds
  in the bad case. That is deliberate: the alternative is returning before the
  program has let go of the display, which is the bug being fixed.
  """
  def launch, do: GenServer.call(__MODULE__, :launch)

  def stop_program(timeout \\ 10_000), do: GenServer.call(__MODULE__, :stop, timeout)

  @doc """
  The index of the highlighted row in the focused column.

  Exposed so a console -- or a test that has just injected a synthetic D-pad
  event -- can read the cursor without looking at the panel. There is
  deliberately no setter: the only way to move it is the binding the user has,
  which is the part worth testing.
  """
  def selected, do: GenServer.call(__MODULE__, :selected)

  @doc """
  The whole column browser, for a console: every open level and its cursor.
  """
  def browser, do: GenServer.call(__MODULE__, :browser)

  @doc """
  Why the last program died, or nil.

  `%{name: name, status: status, lines: lines}` after a program exits nonzero
  (`status` is the exit status) or refuses to spawn (`status` is nil and
  `lines` is the spawn error). The home scene draws it; B clears it. Public
  so a console can read the same thing the panel shows.
  """
  def obituary, do: GenServer.call(__MODULE__, :obituary)

  @doc """
  Sleep and wake without pressing anything, and ask which it is.

  `sleep/0` returns what the backlight write returned, so a console gets the
  reason rather than a cheerful `:ok` over a lit screen. `asleep?/0` answers
  from this process's own state, which is the thing that decides whether the
  next button press is swallowed; `MayonnaiOS.Sleep.asleep?/0` answers from
  sysfs, and the two can legitimately differ -- see that module.
  """
  def sleep, do: GenServer.call(__MODULE__, :sleep)
  def wake, do: GenServer.call(__MODULE__, :wake)
  def asleep?, do: GenServer.call(__MODULE__, :asleep?)

  @impl GenServer
  def init(opts) do
    # Nothing is running yet, whatever a leftover term says. The panel hold
    # lives in the VM rather than in a process, so this is the one thing that
    # clears a hold whose program died with the launcher that started it --
    # without it, a crash during a game would leave the panel frozen for
    # good, with every scene politely refusing to draw.
    Panel.release()

    Enum.each(devices(opts), &watch/1)
    {:ok, opts |> new_state() |> reset_idle_timer()}
  end

  # The gamepad, the analog stick, and whatever device the sleep key is on.
  # Three nodes: evdev is not a broadcast, so the only way to see `KEY_POWER`
  # is to have `axp20x-pek` open and the only way to see the stick is to have
  # `adc-joystick` open, and all of them deliver into the same `handle_info`.
  # `uniq` because a binding back on the pad would fold two of these into one
  # node again, as the power key was until this firmware.
  #
  # `nil` is dropped rather than opened. A device that is not there by name is
  # not there, and the alternative -- a number -- is a different device that
  # never sends the key being waited for. Which device went missing is already
  # in the log by the time this runs; see `MayonnaiOS.Input.find/1`.
  #
  # An explicit `:device` overrides the lot, which is how the tests and
  # `MayonnaiOS.Dev` drive this with synthetic events.
  defp devices(opts) do
    case Keyword.get(opts, :device) do
      nil ->
        case Enum.uniq(
               Enum.reject(
                 [
                   Input.find(Device.input(:gamepad)),
                   Input.find(Device.input(:stick)),
                   Sleep.device(),
                   lid_device()
                 ],
                 &is_nil/1
               )
             ) do
          [] ->
            # A laptop, where this is ordinary and the synthetic-event path is
            # the point -- and a device whose kernel lost both nodes, where it
            # is a disaster. The log line is the same because this process
            # cannot tell them apart; `Input.find/1` has named what it did see.
            Logger.warning("[launcher] no input devices found; no buttons are bound")
            []

          devices ->
            devices
        end

      device ->
        [device]
    end
  end

  defp watch(device) do
    case open_device(device) do
      {:ok, _pid} ->
        Logger.info("[launcher] watching #{device}")

      {:error, reason} ->
        # No buttons is not a reason to fail the boot -- the UI is still
        # useful, and this is the only thing that would be lost.
        Logger.warning("[launcher] #{device} unavailable: #{inspect(reason)}")
    end
  end

  # Check for the node before opening it, because InputEvent does not fail the
  # way the clause above expects on every machine. Its port binary is only
  # built on Linux (its Makefile skips the C build elsewhere), so on a macOS
  # host `InputEvent.start_link/1` *raises* inside a linked start -- which
  # would take this process down at boot rather than degrade to "no buttons".
  # With the guard the Launcher starts anywhere, which is what lets the tests
  # send it synthetic key events.
  defp open_device(device) do
    if File.exists?(device), do: InputEvent.start_link(device), else: {:error, :enoent}
  end

  defp new_state(opts),
    do: %{
      port: nil,
      app: nil,
      app_error: nil,
      running: nil,
      held: MapSet.new(),
      buttons: Keyword.get(opts, :buttons, Device.current!().buttons),
      lid_switch: Keyword.get(opts, :lid_switch, Device.current!().lid_switch),
      scene: :home,
      # The home screen's column browser: which columns are open, which row
      # each cursor is on, and how many columns the panel draws. Here rather
      # than in the scene so it survives every repaint; see the moduledoc.
      browser: Browser.new(),
      # The last few lines the running program wrote, kept so that if it dies
      # they can be put on the panel and not only in the ring logger. Reset
      # on every launch; capped, because a chatty program earns no more rows.
      output: [],
      # Why the last program died, or nil. Set when a program exits nonzero
      # or refuses to spawn, drawn by the home scene, cleared by B or by the
      # next launch. It exists because a program that exits in its first
      # hundred milliseconds is indistinguishable from "nothing happened"
      # from the couch -- Moonlight without its config file taught that.
      obituary: nil,
      # What actually switches the device off, injectable because the real
      # one cannot be called on a laptop and a confirmation flow nobody can
      # test is a confirmation flow that silently rots.
      poweroff: Keyword.get(opts, :poweroff, &Nerves.Runtime.poweroff/0),
      # Drawn synchronously before the menu's orderly power-off, so the last
      # visible frame acknowledges the selection. Injectable to make the
      # ordering testable without a framebuffer.
      shutdown_splash: Keyword.get(opts, :shutdown_splash, fn -> Splash.run(timeout: 0) end),
      # The seam the stop path is tested against: signalling an OS process and
      # asking whether it is still there. Injectable because the one case that
      # matters most cannot be produced for real -- a process that survives
      # SIGKILL is a process stuck in a driver, and a test cannot make one.
      signals: Keyword.get(opts, :signals, MayonnaiOS.Launcher.Kill),
      term_timeout: Keyword.get(opts, :term_timeout, @term_timeout),
      kill_timeout: Keyword.get(opts, :kill_timeout, @kill_timeout),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      idle_sleep_ms: Keyword.get(opts, :idle_sleep_ms, @idle_sleep_ms),
      # Read the persisted development switch once per Launcher lifetime.
      # Button presses reset this timer, so reading the filesystem from every
      # press would put a cold path in the hottest input path for no benefit.
      auto_sleep: Keyword.get_lazy(opts, :auto_sleep, &AutoSleep.enabled?/0),
      idle_timer: nil,
      power_state:
        Keyword.get(opts, :power_state, fn ->
          Power.values() |> Power.state()
        end),
      # Pushing the save files onto the card, at the only moments it is safe
      # to: after the program that owns them is confirmed gone. Injectable
      # because what a test can check is that it happens then and not when a
      # program survived the kill, and an fsync itself has no observable
      # result from in here.
      flush_saves: Keyword.get(opts, :flush_saves, &MayonnaiOS.Saves.flush/0),
      # Whether the backlight was turned off by the chord. Kept here rather
      # than read back from sysfs on every event, because it is this process
      # that has to decide whether to swallow a press and because the panel
      # can be dark for reasons this process did not cause -- and the reading
      # that matters is "did we turn it off", not "is it off".
      asleep: false,
      # What `MayonnaiOS.LowPower` needs in order to undo itself: the cores it
      # took offline, the governors it changed, the WiFi configuration it put
      # away and the Scenic driver it stopped. Empty while awake.
      #
      # Held here and nowhere else, and deliberately not persisted: if this
      # process dies asleep, the supervisor restarts it knowing nothing, and
      # knowing nothing is recoverable -- a remembered "the governor was
      # ondemand" that no longer matches the hardware is not.
      low_power: []
    }

  @impl GenServer
  def handle_call(:running?, _from, state), do: {:reply, state.port != nil, state}

  def handle_call(:os_pid, _from, %{port: nil} = state), do: {:reply, nil, state}

  def handle_call(:os_pid, _from, state) do
    case Port.info(state.port, :os_pid) do
      {:os_pid, pid} -> {:reply, pid, state}
      _ -> {:reply, nil, state}
    end
  end

  def handle_call(:launch, _from, state) do
    state = state |> do_launch() |> reset_idle_timer()
    {:reply, :ok, state}
  end

  # The reply is the result rather than a cheerful `:ok`, because there is now
  # an outcome worth having: `{:error, {:still_running, pid}}` means the
  # program is still on the display and this process could not shift it.
  def handle_call(:stop, _from, state) do
    {result, state} = do_stop(state)
    {:reply, result, reset_idle_timer(state)}
  end

  def handle_call(:selected, _from, state) do
    {:reply, List.last(state.browser.levels).cursor, state}
  end

  def handle_call(:browser, _from, state), do: {:reply, state.browser, state}

  def handle_call(:obituary, _from, state), do: {:reply, state.obituary, state}
  def handle_call(:asleep?, _from, state), do: {:reply, state.asleep, state}

  def handle_call(:sleep, _from, state) do
    {result, state} = enter_sleep(state)
    {:reply, result, state}
  end

  def handle_call(:wake, _from, state) do
    {result, state} = wake_up(state)
    {:reply, result, state}
  end

  @impl GenServer
  # Asleep: the panel is dark, and the next press is spent on turning it back
  # on. First clause, before the app one, because "any button wakes it" has to
  # be true of every button in every state -- someone holding a dark handheld
  # has no way to find out which button is the right one.
  #
  # The press is swallowed rather than dispatched. Pressing A to see the
  # screen again must not launch a game, and pressing Menu to see it must not
  # stop the one that is running.
  #
  # Releases are still tracked, and only a press wakes: the chord that put the
  # device to sleep is still held at that moment, and its release arriving a
  # moment later must not wake the device straight back up.
  def handle_info({:input_event, _device, events}, state) do
    case lid_transition(state, events) do
      :closed ->
        {_result, state} = enter_sleep(state)
        {:noreply, state}

      :opened when state.asleep ->
        {_result, state} = wake_up(state)
        {:noreply, state}

      _other ->
        handle_input(events, state)
    end
  end

  # An app has the buttons: the launcher's own bindings are off and every
  # event is forwarded, Menu included. The app is free to ignore what it does
  # not want -- `MayonnaiOS.Controller.Report` drops Menu on the floor -- and
  # the only thing handled here is the way out.
  #
  # This is the rule the launcher already applies to an external program:
  # whatever has the screen has the input, and Menu is the way back. The
  # difference is only in the plumbing. A program reads evdev for itself
  # through udev, so the launcher has nothing to forward; an app runs in this
  # VM and has to be handed the reports, because this process is the one
  # holding the pad open and evdev is not a broadcast.
  #
  # The exception is the sleep key, which is held back: it is not a pad button,
  # no app has a use for it, and a power button that does nothing while the
  # controller screen is open is worse than an app missing an event it would
  # have dropped. The moduledoc has the argument.
  #
  # Whole reports go across rather than single events, so a diagonal or a
  # button and a direction pressed in the same kernel report reach the app as
  # one thing and become one HID report.
  # Only the newest timeout is authoritative. Button presses cancel and
  # replace timers, but a message already delivered to this mailbox cannot be
  # recalled; the token makes that stale message harmless.
  def handle_info({:idle_sleep, token}, %{idle_timer: {_timer, token}} = state) do
    state = %{state | idle_timer: nil}

    cond do
      not idle_eligible?(state) ->
        {:noreply, state}

      state.power_state.() in [:charging, :full] ->
        {:noreply, reset_idle_timer(state)}

      true ->
        {_result, state} = enter_sleep(state)
        {:noreply, if(state.asleep, do: state, else: reset_idle_timer(state))}
    end
  end

  def handle_info({:idle_sleep, _stale_token}, state), do: {:noreply, state}

  # The program exited on its own. Name it from `running` rather than from the
  # running metadata rather than the hidden browser cursor. Ordinary launcher
  # navigation is ignored while the program owns input, and this also keeps
  # the exit name independent of presentation state.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("[launcher] #{name_of(state.running)} exited (#{status})")

    # A nonzero exit becomes an obituary before the repaint, so the menu that
    # comes back says what just happened instead of merely coming back. Zero
    # is a program that meant to exit -- quitting RetroArch from its own menu
    # -- and gets no banner. Deliberate stops never reach this clause at all:
    # `await_exit/3` consumes their exit message itself.
    state = %{state | obituary: obituary(state, status)}

    # Released before the repaint, and in that order: the repaint *is* a write
    # to the framebuffer, and it is only allowed because the program that
    # owned it is gone. This is the moment the display comes back.
    Panel.release()
    repaint(state)

    # And after the screen is back, because the program being gone is what
    # makes this safe rather than urgent: RetroArch hands the SRAM to the
    # kernel and never fsyncs it, so on a device with no `sync` and no clean
    # shutdown the save it just wrote is only as durable as the page cache. An
    # fsync on this card can take a moment and nothing can launch anything
    # before this clause returns, so the panel comes back first.
    state.flush_saves.()

    state = %{state | port: nil, running: nil, output: []}
    {:noreply, reset_idle_timer(state)}
  end

  # Log what the program says, rather than dropping it.
  #
  # An external program that dies on this device has no other way to tell
  # anyone why: there is no console, the screen belongs to whatever ran last,
  # and the ring logger is the only thing anybody can read afterwards. A
  # RetroArch that renders one frame and exits looks like "a quick flash on
  # the screen and nothing" -- while the exact reason is on the pipe:
  #
  #     [ERROR] [Video] Cannot initialize input driver. Exiting...
  #
  # Trimmed and length-capped because a chatty program should not be able to
  # push everything else out of a fixed-size ring buffer.
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, log_output(state, data)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_input(events, %{asleep: true} = state) do
    if Enum.any?(events, &match?({:ev_key, _key, 1}, &1)) do
      {_result, state} = wake_up(state)
      {:noreply, state}
    else
      state =
        Enum.reduce(events, state, fn
          {:ev_key, key, 0}, acc -> release(acc, key)
          _, acc -> acc
        end)

      {:noreply, state}
    end
  end

  defp handle_input(events, %{app: app} = state) when app != nil do
    {state, slept?} = Enum.reduce(events, {state, false}, &app_event/2)

    # B leaves the apps that do not claim it -- the readouts, where back
    # should go back -- and is then held out of the report the way the sleep
    # key is from everything: the press that closes a screen must not also
    # act inside it. The apps that need B for themselves keep it whole; see
    # claims_back?/1.
    leaving? = not slept? and back_press?(state, events) and not claims_back?(app)

    if not slept? and not leaving?, do: app_module(app).input(events)

    state = if leaving?, do: state |> stop_app() |> go_home(), else: state
    state = leave_app(state, events)
    state = if real_press?(events), do: reset_idle_timer(state), else: state
    {:noreply, state}
  end

  # An external program owns ordinary gamepad input. The evdev reader still
  # reports every key so global controls remain available, but browser state
  # must stay frozen behind the program. Select is tracked for Select+Menu;
  # Menu stops the program, and Power/lid sleep remains global.
  defp handle_input(events, %{port: port} = state) when port != nil do
    state = Enum.reduce(events, state, &external_program_event/2)
    {:noreply, state}
  end

  defp handle_input(events, state) do
    state =
      Enum.reduce(events, state, fn
        # value 1 is press and 0 is release; 2 is autorepeat and is ignored.
        # Releases matter now: the power-off chord needs to know what is held.
        #
        # Dropping autorepeat means the D-pad does not scroll when held: one
        # press, one row. That is a simplification, not an oversight -- each
        # move re-roots the viewport, and holding down would queue a scene
        # restart per repeat. Worth revisiting only if the list grows long.
        {:ev_key, key, 1}, acc -> acc |> hold(key) |> press(key)
        {:ev_key, key, 0}, acc -> release(acc, key)
        _, acc -> acc
      end)

    state = if real_press?(events), do: reset_idle_timer(state), else: state
    {:noreply, state}
  end

  defp external_program_event({:ev_key, key, 1}, state) do
    state = hold(state, key)

    cond do
      Sleep.trigger?(state.held, key) ->
        {_result, state} = enter_sleep(state)
        state

      key == button(state, :home) ->
        home(state)

      true ->
        state
    end
  end

  defp external_program_event({:ev_key, key, 0}, state), do: release(state, key)
  defp external_program_event(_event, state), do: state

  defp lid_transition(%{lid_switch: nil}, _events), do: nil

  defp lid_transition(%{lid_switch: %{key: key}}, events) do
    cond do
      Enum.any?(events, &match?({:ev_sw, ^key, 1}, &1)) -> :closed
      Enum.any?(events, &match?({:ev_sw, ^key, 0}, &1)) -> :opened
      true -> nil
    end
  end

  defp lid_device do
    case Device.current!().lid_switch do
      nil -> nil
      %{device: name} -> Input.find(name)
    end
  end

  # What the panel will say about a program that died. Status zero is a
  # program that meant to exit and merits nothing; anything else is paired
  # with the last lines it wrote, because "exited (1)" without its dying
  # words is a riddle and with them is usually the whole diagnosis.
  defp obituary(_state, 0), do: nil

  defp obituary(state, status),
    do: %{name: name_of(state.running), status: status, lines: state.output}

  # Trimmed and length-capped because a chatty program should not be able to
  # push everything else out of a fixed-size ring buffer. Shared with the stop
  # path, which reads the same pipe while it waits for the program to die --
  # that caller drops the returned state, which is fine: a deliberate stop
  # writes no obituary, so its tail of output is never read.
  #
  # Returns the state with the last few lines retained, which is what the
  # obituary quotes if the program then exits nonzero.
  defp log_output(state, data) do
    lines =
      data
      |> String.split("\n", trim: true)
      |> Enum.map(&String.slice(&1, 0, 300))

    Enum.each(lines, fn line -> Logger.info("[#{program_name(state)}] #{line}") end)

    %{state | output: Enum.take(state.output ++ lines, -@obituary_lines)}
  end

  # The running program's name, for log lines. Falls back to "program" rather
  # than crashing the log call if a message arrives after the state is cleared.
  defp program_name(%{running: %{name: name}}), do: name
  defp program_name(_), do: "program"

  defp hold(state, key), do: %{state | held: MapSet.put(state.held, key)}
  defp release(state, key), do: %{state | held: MapSet.delete(state.held, key)}

  defp real_press?(events),
    do: Enum.any?(events, &match?({:ev_key, _key, 1}, &1))

  defp idle_eligible?(state),
    do:
      state.auto_sleep and not state.asleep and state.port == nil and state.app == nil and
        state.scene == :home

  defp reset_idle_timer(state) do
    state = cancel_idle_timer(state)

    if idle_eligible?(state) and is_integer(state.idle_sleep_ms) and state.idle_sleep_ms > 0 do
      token = make_ref()
      timer = Process.send_after(self(), {:idle_sleep, token}, state.idle_sleep_ms)
      %{state | idle_timer: {timer, token}}
    else
      state
    end
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  # The held set is folded one event at a time and the trigger is asked after
  # each press, exactly as the ordinary path does it, so a future binding with
  # a modifier would still see the set the way the user pressed it rather than
  # the set the whole report leaves behind.
  #
  # The whole report is dropped when the sleep key is in it, not just that one
  # event. A report cannot span two devices and the sleep device carries one
  # key, so "the report contains the sleep key" and "the report is the sleep
  # key" are the same statement on this hardware.
  defp app_event({:ev_key, key, 1}, {state, slept?}) do
    state = hold(state, key)

    if Sleep.trigger?(state.held, key) do
      {_result, state} = enter_sleep(state)
      {state, true}
    else
      {state, slept?}
    end
  end

  defp app_event({:ev_key, key, 0}, {state, slept?}), do: {release(state, key), slept?}
  defp app_event(_event, acc), do: acc

  # Menu while an app is running. The power-off chord is checked first, for
  # the same reason it is checked first everywhere else: a bare Menu must
  # never be able to switch the device off, and someone holding Select while
  # using the controller is holding Select on purpose.
  defp leave_app(state, events) do
    if pressed?(events, button(state, :home)) do
      if MapSet.member?(state.held, button(state, :poweroff_modifier)) do
        poweroff(state, "Select+Menu")
      else
        state |> stop_app() |> go_home()
      end
    else
      state
    end
  end

  defp back_press?(state, events), do: pressed?(events, button(state, :back))

  # Whether the app keeps B for itself. The controller forwards it to the
  # host as a gamepad button and a pickle's script reads it as "b"; for
  # those, a launcher that eats B is a controller with a dead button. An app
  # says so by exporting `claims_back?/0` returning true; the readouts do
  # not, so for them B is the way back. RetroArch and the other external
  # programs are not in question here at all -- they read evdev themselves,
  # and nothing in this clause sees their buttons.
  defp claims_back?(app) do
    module = app_module(app)
    function_exported?(module, :claims_back?, 0) and module.claims_back?()
  end

  defp stop_app(%{app: nil} = state), do: state

  defp stop_app(%{app: app} = state) do
    app_module(app).stop()
    Logger.info("[launcher] stopped #{name_of(state.running)}")
    %{state | app: nil, running: nil}
  end

  # An app is a module, or a module carrying which of its many it is this
  # time -- `{MayonnaiOS.Pickles.App, "paint"}` is the row for the pickle
  # called paint. The argument matters once, at start; stop, input and scene
  # are conversations with the module about its current tenant.
  defp app_module({module, _arg}), do: module
  defp app_module(module), do: module

  defp app_start({module, arg}), do: module.start(arg)
  defp app_start(module), do: module.start()

  # The sleep binding is tested before any single-key binding, for the reason
  # the power-off chord is tested before Menu: a modifier that only works when
  # the other key happens to be unbound is not a modifier, and moving
  # `MayonnaiOS.Sleep`'s one-line binding onto a key that *is* bound is a
  # change to one tuple. It does not matter today -- `KEY_POWER` is bound to
  # nothing else and arrives from its own device -- and the ordering is what
  # keeps that a property of the binding rather than of this function.
  defp press(state, key) do
    cond do
      Sleep.trigger?(state.held, key) ->
        {_result, state} = enter_sleep(state)
        state

      Browser.busy?(state.browser) ->
        overlay(state, key)

      Browser.full?(state.browser) ->
        full_view(state, key)

      true ->
        bound(state, key)
    end
  end

  # A sheet has the buttons: the actions list, a delete confirmation, or the
  # rename editor. Everything goes to the browser except the two things that
  # must mean the same wherever they are pressed -- the power-off chord, and
  # Menu as the way home. The sleep key was already tested above.
  defp overlay(state, key) do
    if key == button(state, :home) do
      overlay_home(state)
    else
      browse(state, Browser.overlay_input(state.browser, semantic(state, key)))
    end
  end

  defp overlay_home(state) do
    if MapSet.member?(state.held, button(state, :poweroff_modifier)) do
      poweroff(state, "Select+Menu")
    else
      go_home(state)
    end
  end

  # The full view has the buttons: scrolling to the browser, and the same two
  # exceptions as the sheets -- the power-off chord, and Menu as the way
  # home. The sleep key was already tested above.
  defp full_view(state, key) do
    if key == button(state, :home) do
      full_home(state)
    else
      browse(state, Browser.full_input(state.browser, semantic(state, key)))
    end
  end

  defp full_home(state) do
    if MapSet.member?(state.held, button(state, :poweroff_modifier)) do
      poweroff(state, "Select+Menu")
    else
      go_home(state)
    end
  end

  # The browser speaks verbs, not scan codes: it should not have to know that
  # this board's device tree swaps A/B and X/Y, and `:other` still matters --
  # on the delete confirmation any unnamed button cancels.
  defp semantic(state, key) do
    Enum.find_value(
      [
        up: :up,
        down: :down,
        left: :left,
        right: :right,
        page_up: :l1,
        page_down: :r1,
        launch: :a,
        back: :b,
        confirm: :y,
        full: :x
      ],
      :other,
      fn {binding, verb} -> if key == button(state, binding), do: verb end
    )
  end

  # Entering sleep only counts if the backlight write landed. A dark-panel
  # flag over a lit screen would swallow the next press for nothing, which is
  # the same failure as not sleeping at all plus a button that does not work.
  # `Sleep` has already logged why.
  defp enter_sleep(state) do
    case Sleep.sleep() do
      :ok ->
        # Slow flashing green: asleep, still running. Only when the backlight
        # write landed, for the same reason as the flag -- a sleep signal over
        # a lit screen would be the LED lying about the panel.
        Led.set(:sleeping)
        # And only then the rest of it. The backlight is the measure that is
        # certain to work and the only one the user can see, so it goes first
        # and it alone decides whether this counts as sleep; the cores, the
        # governor, the radio and the renderer are what make the dark panel
        # actually cost less. `LowPower.enter/0` cannot fail -- a step that
        # will not run is logged and left out of the undo list -- so there is
        # nothing here to branch on. See MayonnaiOS.LowPower.
        state =
          state
          |> Map.put(:asleep, true)
          |> Map.put(:low_power, LowPower.enter())
          |> cancel_idle_timer()

        {:ok, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  # Waking clears the flag whether or not the write landed, deliberately. If
  # the backlight cannot be turned back on, more presses will not do it, and a
  # device that keeps eating them is worse off than one with a dark panel and
  # working buttons -- a game can still be started, and Select+Menu still
  # powers it off. `Sleep` logs the failure and the console call returns it.
  #
  # The held set goes too: the press that woke the device was consumed, so it
  # must not also count as the modifier half of a chord.
  defp wake_up(state) do
    # Back to solid green whether or not the backlight write landed, matching
    # the flag: this process now treats the device as awake, and the LED
    # reports what this process does with button presses, not the panel.
    Led.set(:running)
    # Before the backlight, and in reverse: cores back, governor back, WiFi
    # back, renderer back. The renderer coming back last is what makes the
    # order matter -- the frame is redrawn while the panel is still dark, so
    # the light comes up over a finished picture instead of over whatever the
    # framebuffer was left holding. `leave/1` is always :ok and rescues each
    # step separately; see MayonnaiOS.LowPower.
    LowPower.leave(state.low_power)

    state = %{state | asleep: false, held: MapSet.new(), low_power: []}
    {Sleep.wake(), reset_idle_timer(state)}
  end

  defp bound(state, key) do
    cond do
      key == button(state, :launch) -> do_launch(state)
      key == button(state, :up) -> move(state, -1)
      key == button(state, :down) -> move(state, +1)
      key == button(state, :left) -> browse(state, Browser.ascend(state.browser))
      key == button(state, :right) -> browse(state, Browser.descend(state.browser))
      key == button(state, :page_up) -> browse(state, Browser.page(state.browser, :up))
      key == button(state, :page_down) -> browse(state, Browser.page(state.browser, :down))
      key == button(state, :actions) -> browse(state, Browser.open_actions(state.browser))
      key == button(state, :full) -> full(state)
      key == button(state, :back) -> back(state)
      key == button(state, :home) -> home(state)
      true -> unhandled(state, key)
    end
  end

  # X: the full view of the selected entry -- except the process monitors,
  # whose detailed view is the readout app itself, so X opens it the way A
  # does. `MayonnaiOS.Browser` owns every other shape of the full view.
  defp full(state) do
    case Browser.selected(state.browser) do
      %{kind: :program, program: %{app: {MayonnaiOS.Top, _which}} = program} ->
        start_program(program, state)

      _node ->
        browse(state, Browser.open_full(state.browser))
    end
  end

  # Menu: back to the home screen, or -- with Select held -- power off.
  #
  # The chord is checked first, so the modifier is not decorative: a bare
  # Menu must never be able to shut the device down, because it is the key
  # someone reaches for to get out of a game.
  defp home(state) do
    if MapSet.member?(state.held, button(state, :poweroff_modifier)) do
      poweroff(state, "Select+Menu")
    else
      go_home(state)
    end
  end

  defp unhandled(state, key) do
    # Debug, not info: this fires for every unbound button on the pad. It
    # exists because the D-pad codes are inherited from the device tree and
    # this board's device tree has been wrong before -- if up and down feel
    # swapped, this is the line that says which atom the hardware really sent.
    Logger.debug("[launcher] unhandled key #{inspect(key)}")
    state
  end

  defp button(state, semantic), do: Map.fetch!(state.buttons, semantic)
  defp pressed?(events, key), do: Enum.any?(events, &match?({:ev_key, ^key, 1}, &1))

  # B: on the diagnostics screen there is no column to close, so back is the
  # way out -- the same press that leaves the readout apps. Only with nothing
  # running: while a program has the display, its buttons are its own and a
  # stop stays Menu's.
  defp back(%{scene: scene, port: nil} = state) when scene != :home, do: go_home(state)

  # The obituary goes next -- it is the thing most recently put on the
  # panel, and "back" should take back the last thing shown. With nothing to
  # clear, B closes a column, which is what B means on every other screen.
  defp back(%{obituary: nil} = state), do: browse(state, Browser.ascend(state.browser))
  defp back(state), do: dismiss_obituary(state)

  # Takes the obituary off the panel. The repaint is gated the same way
  # `browse/2` gates its own: only when the menu is the thing on screen. A B
  # pressed during a game reaches here (the pad is this process's), and the
  # state clears either way -- only the write waits, and the exit-time repaint
  # draws whatever the state then says.
  defp dismiss_obituary(state) do
    state = %{state | obituary: nil}

    if state.port == nil and state.scene == :home do
      show(:home, state)
    end

    state
  end

  defp move(state, delta), do: browse(state, Browser.move(state.browser, delta))

  # Adopt a changed browser, and repaint only when the menu is actually the
  # thing on screen. While an external program is running it owns KMS, and
  # pushing the viewport would write the menu into /dev/fb0 underneath its
  # output -- visible as the menu bleeding through a game. On the diagnostics
  # screen the browser is not drawn at all, so a repaint there would be pure
  # cost. The state still moves in both cases; only the redraw waits.
  #
  # The program half of that is also enforced one level down -- `set_root/2`
  # refuses while `MayonnaiOS.Panel` is held, which is what catches the
  # buttons this clause does not. It stays here because the diagnostics half
  # is this function's own business and because a guard that says why it
  # exists is worth more than one line saved.
  #
  # And only when something actually changed. `set_root/3` is not a redraw:
  # it stops the running scene process and starts a new one. A move in an
  # empty column, a descend on a leaf and an ascend at the root all return
  # the browser they were given, so an idle press does not tear down and
  # rebuild the scene for no visible change.
  defp browse(state, browser) do
    if browser == state.browser do
      state
    else
      state = %{state | browser: browser}

      if state.port == nil and state.scene == :home do
        show(:home, state)
      end

      state
    end
  end

  # Back to the menu, from wherever we are.
  #
  # `scene` is set before `do_stop/1` rather than after, because do_stop
  # repaints whatever `scene` says: setting it first makes one viewport push
  # do both jobs. Pushing twice would be visible -- diagnostics for a frame,
  # then the menu.
  defp go_home(state) do
    home = %{state | scene: :home}

    cond do
      state.port != nil ->
        # A program that would not die keeps the screen, and this returns the
        # state that says so: still running, panel still held, nothing
        # repainted. Pressing Menu again tries again, which is the only thing
        # left to offer.
        {_result, state} = do_stop(home)
        state

      state.scene != :home ->
        show(:home, home)
        home

      # Already home with nothing running: back to the root column. This is
      # the button people press to get out of wherever they are, and deep in
      # the file tree that is the top of the menu, not one column up. When the
      # browser is already at its root the reset changes nothing and nothing
      # repaints -- `browse/2` is the guard -- so an idle press does not make
      # the panel flicker.
      true ->
        browse(state, Browser.reset(state.browser))
    end
  end

  defp poweroff(state, how) do
    Logger.info("[launcher] #{how}: powering off")

    # Orderly, and verified on the hardware to actually cut power -- which
    # it did not always: the kernel's power-off wrote a register the AXP717
    # does not have, the write was silently dropped, and every "power off"
    # fell through PSCI into a watchdog reboot. The BSP's linux patch 0003
    # (SOFT_PWROFF, 0x27) is what closed that; if power off ever regresses
    # into a reboot again, start there. The power button is unchanged: a
    # short press is sleep, and a long one is the PMIC cutting the rail in
    # hardware after 4000 ms with nothing flushed. Two ways to ask for the
    # orderly one -- the Select+Menu chord and the menu row -- and one
    # function they both reach.
    state.poweroff.()
    state
  end

  # A on the browser: a category, a root or a directory opens as another
  # column; a program, a pickle or a verb starts; a file opens its full
  # view, because "open" on the one kind of thing that cannot be entered or
  # run means "show me it". A never opens the actions sheet -- that is Y's,
  # and only Y's.
  #
  # The busy and full clauses are for `launch/0` from a console -- a pad
  # press never reaches here in those states, `press/2` routes it first.
  defp do_launch(%{port: nil, app: nil} = state) do
    node = Browser.selected(state.browser)

    cond do
      Browser.busy?(state.browser) -> browse(state, Browser.overlay_input(state.browser, :a))
      Browser.full?(state.browser) -> state
      Browser.expandable?(node) -> browse(state, Browser.descend(state.browser))
      match?(%{kind: :program}, node) -> start_program(node.program, state)
      match?(%{kind: :rom}, node) -> launch_game(node.system, node.path, state)
      match?(%{kind: :file}, node) -> launch_file(node, state)
      true -> state
    end
  end

  defp do_launch(state) do
    Logger.info("[launcher] already running")
    state
  end

  defp launch_file(node, state) do
    with %{} = system <- Game.system_for(node.name),
         {:ok, location} <- Files.descend(Browser.focused(state.browser).location, node.name),
         {:ok, path} <- Files.resolve(location) do
      launch_game(system.key, path, state)
    else
      _ -> browse(state, Browser.open_full(state.browser))
    end
  end

  defp launch_game(system, path, state) do
    case Game.program(system, path) do
      {:ok, program} ->
        start_program(program, state)

      {:error, :no_core} ->
        browse(
          state,
          Browser.put_message(state.browser, :error, "No installed core for this system.")
        )

      {:error, :no_retroarch} ->
        browse(state, Browser.put_message(state.browser, :error, "RetroArch is not configured."))
    end
  end

  defp start_program(%{installed?: false} = program, state) do
    Logger.warning("[launcher] #{program.path} not installed")
    state
  end

  # The Power off row. Draw the splash before asking the runtime to shut down,
  # so the panel immediately acknowledges the selection while services and
  # filesystems stop.
  defp start_program(%{action: :poweroff}, state) do
    state.shutdown_splash.()
    poweroff(state, "the menu")
  end

  # The Diagnostics row: the readout that makes the physical checks --
  # charger, volume keys, headphone jack -- answerable by looking at the
  # device instead of over SSH. Menu is the way back out.
  defp start_program(%{action: :diagnostics}, state) do
    state = %{state | scene: :diagnostics}
    show(:diagnostics, state)
    state
  end

  # The Sleep row: the same backlight-off the power key does, and waking is
  # unchanged -- the next press is consumed on turning the panel back on.
  defp start_program(%{action: :sleep}, state) do
    {_result, state} = enter_sleep(state)
    state
  end

  # Persisted development switch: automatic idle sleep is disabled without
  # weakening either explicit route to sleep (the power key and row above).
  defp start_program(%{action: :toggle_auto_sleep}, state) do
    case AutoSleep.toggle() do
      {:ok, enabled} ->
        browser =
          state.browser
          |> Browser.refresh()
          |> Browser.put_message(
            :ok,
            "Automatic sleep #{if(enabled, do: "enabled", else: "disabled")}."
          )

        state = %{state | browser: browser, auto_sleep: enabled}
        state = if enabled, do: reset_idle_timer(state), else: cancel_idle_timer(state)
        show(:home, state)
        state

      {:error, reason} ->
        browse(
          state,
          Browser.put_message(state.browser, :error, "Could not save setting: #{inspect(reason)}")
        )
    end
  end

  # The Theme row: advances `MayonnaiOS.Theme` to the next built-in theme and
  # repaints in place. Not a program and not an app -- it neither takes the
  # display nor changes what scene is showing, so `show(:home, state)` rather
  # than `browse/2`: the browser value itself has not changed, and `browse/2`
  # would see that and skip the repaint that is the entire point here.
  defp start_program(%{action: :cycle_theme}, state) do
    Theme.cycle()
    show(:home, state)
    state
  end

  # An app: no port, no external process, no screen to hand over. It starts
  # here in this VM and the panel switches to whatever scene it names.
  #
  # A failure to start is put on the panel rather than only in the log. The
  # reasons are Bluetooth bind errors -- `:eusers`, `:enodev` -- and they are
  # exactly the kind of thing that is diagnosable in one glance and
  # impenetrable without one. The scene is shown either way, and the error
  # travels to it as the scene's start argument, the same route the home
  # scene's cursor takes.
  defp start_program(%{app: app} = program, state) when app != nil do
    Logger.info("[launcher] starting #{program.name}")

    state =
      case app_start(app) do
        {:ok, _pid} ->
          %{state | app: app, running: program, app_error: nil}

        {:error, {:already_started, _pid}} ->
          %{state | app: app, running: program, app_error: nil}

        {:error, reason} ->
          Logger.warning("[launcher] #{program.name} would not start: #{inspect(reason)}")
          %{state | app: nil, running: nil, app_error: reason}
      end

    state = %{state | scene: {:app, app}}
    repaint(state)
    state
  end

  defp start_program(program, state) do
    Logger.info("[launcher] launching #{Enum.join([program.path | program.args], " ")}")

    # The panel is the program's from here until it is reaped. Taken before
    # the spawn rather than after it, so there is no window in which the
    # program has the display and this VM still thinks it may draw -- and
    # before the udev start below, which is a daemon and takes time.
    Panel.hold(program.name)

    # Programs that read input through udev need the daemon running and the
    # input devices in its database first. Nothing in this application does --
    # InputEvent reads evdev directly -- but RetroArch has no other way to see
    # a gamepad, and without this it renders a frame and exits with "Cannot
    # initialize input driver".
    #
    # Opt-in per program rather than always, because it is a daemon start for
    # the benefit of one kind of program, and because a launcher that silently
    # starts services is harder to reason about than one that is told to.
    if Map.get(program, :needs_udev, false) do
      case MayonnaiOS.Udev.ensure_started() do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[launcher] udev unavailable: #{inspect(reason)}")
      end
    end

    # Port.open raises rather than returning an error, and `installed?` is only
    # File.exists?/1 -- so a configured path that is a directory, or a file
    # without the execute bit, reaches here looking launchable and then throws
    # :eacces or :enoent. This runs inside handle_info, so an uncaught raise
    # takes the Launcher down and with it the only route to the buttons: the
    # device would stop responding to the gamepad entirely because one menu
    # entry was misconfigured.
    try do
      port =
        Port.open({:spawn_executable, String.to_charlist(program.path)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          # :spawn_executable does not go through a shell and does not search
          # $PATH, so argv is passed explicitly and paths must be absolute.
          args: program.args
        ])

      # A fresh spawn clears the previous obituary and starts a fresh tail of
      # output: whatever the panel says when this program exits should be
      # about this program.
      %{state | port: port, running: program, obituary: nil, output: []}
    rescue
      e ->
        Logger.warning("[launcher] #{program.path} would not start: #{Exception.message(e)}")

        # Nothing was spawned, so nothing owns the panel. Without this a
        # mistyped path would leave the UI unable to draw with no program on
        # screen to explain why -- the worst failure in this file, because it
        # looks exactly like a dead device.
        Panel.release()

        # And the reason goes on the panel, not only in the log: a spawn that
        # raised has status nil and the exception's message for last words.
        # The repaint is safe -- the hold was just released -- and needed,
        # because unlike an exit there is no later :exit_status to trigger one.
        state = %{
          state
          | obituary: %{name: program.name, status: nil, lines: [Exception.message(e)]}
        }

        repaint(state)
        state
    end
  end

  # Stop the running program, and do not come back until it is actually gone.
  #
  # ## Why SIGTERM is not enough
  #
  # RetroArch **catches** SIGTERM. Read off a running one rather than assumed:
  # `/proc/<pid>/status` has bit 15 set in `SigCgt` and clear in `SigIgn`. Its
  # handler only sets a quit flag, which the main loop has to notice -- and a
  # main loop blocked in `poll()` on a stalled audio device never gets back to
  # looking. `kill -TERM` on that process returns 0, having done nothing at
  # all. Verified on the device: TERM delivered, four seconds later the process
  # was still there, still sleeping.
  #
  # So the signal escalates. TERM first, because a program that honours it
  # exits cleanly and saves what it was holding; SIGKILL after, which cannot be
  # caught, ignored or blocked.
  #
  # ## Why it waits, and why the wait is the point
  #
  # Signalling, closing the port, releasing the panel and repainting, in that
  # order, without ever asking whether the program has gone, is wrong at every
  # step about a program that has not died yet:
  #
  #   * A hung RetroArch keeps `/dev/dri/card0` and `card1` open. A launcher
  #     that reports it stopped makes every later launch fail with `[KMS]
  #     Error when switching mode` / `Cannot open video driver` -- which from
  #     the outside looks like a completely different bug in a completely
  #     different subsystem.
  #   * The repaint is a write to a framebuffer whose DRM master is still that
  #     program, which is the thing `MayonnaiOS.Panel` exists to prevent and
  #     which hangs this SoC.
  #
  # And if even SIGKILL does not land, the honest thing is to report that
  # rather than tidy up around it. Nothing is closed, nothing is released,
  # `running?/0` stays true, and the state is returned untouched -- so the port
  # is still open, its `:exit_status` still arrives if the process ever dies,
  # and pressing Menu again tries again. A launcher that reports a program
  # stopped while its process is alive is how a display bug gets invented.
  defp do_stop(%{port: nil} = state), do: {:ok, state}

  defp do_stop(%{port: port} = state) do
    case os_pid(port) do
      nil ->
        # No OS pid to signal: the VM has already reaped the process, so the
        # only thing left is the bookkeeping.
        {:ok, finish_stop(state)}

      os_pid ->
        case terminate_process(state, os_pid) do
          :gone ->
            {:ok, finish_stop(state)}

          :alive ->
            Logger.error(
              "[launcher] #{name_of(state.running)} (pid #{os_pid}) survived SIGKILL: " <>
                "still holding the display, not reporting it stopped"
            )

            {{:error, {:still_running, os_pid}}, state}
        end
    end
  end

  # The bookkeeping, and only ever after the process is confirmed gone.
  #
  # Closing the port means no `:exit_status` message will arrive, so this is
  # the only place the hold can be lifted on the Menu-out-of-a-game path.
  defp finish_stop(%{port: port} = state) do
    _ = try do: Port.close(port), rescue: (_ -> :ok)

    Logger.info("[launcher] stopped #{name_of(state.running)}")

    Panel.release()
    repaint(state)

    # Same flush as the reap clause, and for the same reason it is allowed
    # here: this function only runs once `do_stop/1` has confirmed the process
    # is gone, so RetroArch is not going to write that `.srm` again. A stop
    # that could not confirm it never reaches this line.
    state.flush_saves.()

    %{state | port: nil, running: nil}
  end

  # Named for the OS process rather than as `terminate/2`, which is a GenServer
  # callback and would be silently taken for one.
  defp terminate_process(state, os_pid) do
    case signal_and_wait(state, os_pid, "TERM", state.term_timeout) do
      :gone -> :gone
      :alive -> signal_and_wait(state, os_pid, "KILL", state.kill_timeout)
    end
  end

  defp signal_and_wait(state, os_pid, signal, timeout) do
    Logger.info("[launcher] SIG#{signal} to #{name_of(state.running)} (pid #{os_pid})")

    # A signal that will not send is not a reason to stop waiting: the usual
    # reason is that the process has already gone, which the wait below is
    # exactly the thing that finds out.
    case state.signals.signal(signal, os_pid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[launcher] SIG#{signal} to #{os_pid} failed: #{inspect(reason)}")
    end

    await_exit(state, os_pid, System.monotonic_time(:millisecond) + timeout)
  end

  # Two independent answers to "is it gone", because neither is sufficient
  # alone. The port's `:exit_status` is authoritative -- it means the VM has
  # reaped the process -- but it only arrives for a program this VM spawned and
  # only once. Asking the OS covers the rest, and has to be a fallback rather
  # than the primary: between a process exiting and being reaped it is a zombie,
  # and a zombie answers signal 0 exactly like a live process.
  #
  # The exit message is consumed here rather than left for `handle_info/2`.
  # Deliberately: `finish_stop/1` is about to do everything that clause would
  # do, and a leftover message would repaint the panel a second time.
  defp await_exit(state, os_pid, deadline) do
    port = state.port
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      if state.signals.alive?(os_pid), do: :alive, else: :gone
    else
      receive do
        {^port, {:exit_status, status}} ->
          Logger.info("[launcher] #{name_of(state.running)} exited (#{status})")
          :gone

        # Still worth reading. A program's dying words are the only thing it
        # can say about why it would not go, and dropping them here is what
        # cost an evening the last time this module discarded port output.
        {^port, {:data, data}} ->
          log_output(state, data)
          await_exit(state, os_pid, deadline)
      after
        min(remaining, state.poll_ms) ->
          if state.signals.alive?(os_pid),
            do: await_exit(state, os_pid, deadline),
            else: :gone
      end
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  end

  defp name_of(%{name: name}), do: name
  defp name_of(_), do: "program"

  # Scenic redraws on change, so the panel keeps the external program's last
  # frame until the viewport is pushed again. Coming back from kmscube has to
  # return to whichever scene was showing, not always the home one -- watching
  # the GPU temperature climb means being on diagnostics before and after.
  defp repaint(%{scene: scene} = state), do: show(scene, state)

  defp show(:diagnostics, _state), do: set_root(MayonnaiOS.Scene.Diagnostics, nil)

  # An app names its own scene, so the launcher does not have to know about
  # any of them. The start argument carries why it did not start, which is nil
  # in the ordinary case.
  defp show({:app, app}, state), do: set_root(app_module(app).scene(), %{error: state.app_error})

  # The browser travels as the scene's start argument, whole: the scene draws
  # exactly the columns this process navigates, and the two cannot disagree
  # because there is one copy and it is here.
  defp show(_home, state) do
    set_root(default_scene(), %{
      browser: state.browser,
      obituary: state.obituary
    })
  end

  defp set_root(nil, _param), do: :ok

  # Re-rooting the viewport is a repaint of the whole panel, so it is exactly
  # what must not happen while a program holds the display. The pad is this
  # process's even during a game, so presses still arrive; `browse/2` already
  # guards its own writes for the same reason, and this catches the rest.
  #
  # The state still moves -- the scene flips, the cursor moves -- and only the
  # write waits. `repaint/1` on the way out is what puts whichever screen that
  # left us on back on the panel, and by then the hold has been released.
  defp set_root(scene, param) do
    if Panel.held?(), do: :ok, else: do_set_root(scene, param)
  end

  # Repainting must never take the Launcher down when there is no UI running.
  # Scenic.ViewPort.info/1 is a bare GenServer.call, so on a missing viewport
  # it *exits* rather than returning an error -- no `case` around it can catch
  # that, which is why `Process.whereis/1` guards the call instead.
  #
  # That matters beyond the tests: Scenic is deliberately not started at boot
  # (see MayonnaiOS), so on a device where start_ui/0 has not been called yet,
  # one button press must not crash the process that owns the buttons.
  defp do_set_root(scene, param) do
    with pid when is_pid(pid) <- Process.whereis(viewport_name()),
         {:ok, vp} <- Scenic.ViewPort.info(pid) do
      Scenic.ViewPort.set_root(vp, scene, param)
    else
      _ -> :ok
    end
  end

  defp viewport_name do
    get_in(Application.get_env(:mayonnaios, :viewport), [:name]) || :main_viewport
  end

  defp default_scene do
    get_in(Application.get_env(:mayonnaios, :viewport), [:default_scene])
  end

  defmodule Signals do
    @moduledoc """
    The two things the stop path needs from the operating system.

    `signal/2` sends one signal; `alive?/1` says whether a pid is still there.
    That is the whole interface, and it is a seam rather than a direct
    `System.cmd/3` for one reason: the case that matters most cannot be
    produced for real. A process that survives `SIGKILL` is a process wedged
    in a driver, a test cannot make one, and "what does the launcher do when
    the program will not die" is precisely the question that was answered
    wrongly before -- it reported the program stopped.

    So a test supplies a module whose signals go nowhere and whose `alive?/1`
    keeps saying yes, and asserts that the launcher does *not* release the
    panel, does *not* repaint, and does *not* report success. Everything else
    in the stop path is tested against real OS processes, which the host has.
    """

    @callback signal(signal :: String.t(), os_pid :: pos_integer()) :: :ok | {:error, term()}
    @callback alive?(os_pid :: pos_integer()) :: boolean()
  end

  defmodule Kill do
    @moduledoc """
    Signals, through `kill(1)`.

    `kill -0` for the liveness check: it sends nothing and only reports whether
    the signal *could* be sent, which is the cheapest question there is. Not
    `/proc/<pid>`, even though this is Linux, because the host these tests run
    on has no procfs and a seam that only works on the target is a seam that
    only gets exercised on the target.

    One thing it cannot distinguish, and the caller has to know it: a process
    that has exited but has not yet been reaped -- a zombie -- answers signal 0
    exactly like a live one. `MayonnaiOS.Launcher.await_exit/3` handles that by
    treating the port's own exit message as the authoritative answer and this
    as the fallback.
    """

    @behaviour MayonnaiOS.Launcher.Signals

    @impl MayonnaiOS.Launcher.Signals
    def signal(signal, os_pid) when is_binary(signal) and is_integer(os_pid) do
      case kill(["-" <> signal, Integer.to_string(os_pid)]) do
        {:ok, _out} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @impl MayonnaiOS.Launcher.Signals
    def alive?(os_pid) when is_integer(os_pid) do
      match?({:ok, _out}, kill(["-0", Integer.to_string(os_pid)]))
    end

    # `System.cmd/3` raises when the executable is not on the path, and a stop
    # that takes the launcher down with it would leave the buttons dead as well
    # as the program running.
    defp kill(args) do
      case System.cmd("kill", args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, status} -> {:error, {:exit, status, String.trim(out)}}
      end
    rescue
      _ -> {:error, {:no_tool, "kill"}}
    end
  end
end
