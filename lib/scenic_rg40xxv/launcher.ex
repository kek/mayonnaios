defmodule ScenicRg40xxv.Launcher do
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
  viewport has to be told to repaint; `Scenic.ViewPort.set_root/2` does it.

  ## The full set of bindings

      A             launch kmscube
      Start         stop it
      X             switch between the demo scene and diagnostics
      Y             run the audio test, if it has been armed
      Select+Menu   power off

  These are the buttons as printed on the shell. Two of the four atoms above
  name the opposite button; see the note on the attributes below.

  This process owns `event0`, so everything on the gamepad is bound here even
  when it belongs to something else -- `ScenicRg40xxv.Audio` decides whether X
  does anything, and it refuses by default. `ScenicRg40xxv.Diagnostics` owns
  the other two input devices for the same reason in reverse.
  """

  use GenServer
  require Logger

  @device "/dev/input/event0"

  # See the moduledoc: these are physical A and Start, not the atoms' names.
  @launch_button :btn_b
  @stop_button :btn_start

  # X and Y are swapped too, and the device tree does not admit it.
  #
  # The first version of this file said X and Y needed no translation: the DT
  # labels "Action-Pad X" 307 and "Action Pad Y" 308, and Linux has
  # BTN_X == BTN_NORTH == 307 and BTN_Y == BTN_WEST == 308, so the labels
  # looked self-consistent. Pressing the buttons says otherwise. The button
  # silkscreened X emits 308 and the one silkscreened Y emits 307 -- the DT's
  # X/Y labels are the wrong way round for this board's shell.
  #
  # So :btn_y below really is the X button. Reading the device tree was not
  # enough here, which is the same lesson as A and B and was available the
  # whole time; it just was not applied twice.
  @diagnostics_button :btn_y
  @audio_button :btn_x

  # Power off is a chord rather than a button, because it is not undoable and
  # the device is a handheld that will be carried in a pocket.
  @poweroff_modifier :btn_select
  @poweroff_button :btn_mode

  @program "/usr/bin/kmscube"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether the external program is running right now.
  """
  def running?, do: GenServer.call(__MODULE__, :running?)

  @doc """
  The OS pid of the running program, or `nil`.

  `ScenicRg40xxv.Diagnostics` uses this to read GPU busy time out of that
  process's `fdinfo`. Scanning every process for a panfrost fd would cost
  thousands of procfs reads a second on this SoC, and it is unnecessary:
  Scenic renders on the CPU through cairo, so the program launched here is
  the only GPU client there is.
  """
  def os_pid, do: GenServer.call(__MODULE__, :os_pid)

  @doc """
  Start or stop it from a console, without pressing anything.
  """
  def launch, do: GenServer.call(__MODULE__, :launch)
  def stop_program, do: GenServer.call(__MODULE__, :stop)

  @impl GenServer
  def init(_opts) do
    case InputEvent.start_link(@device) do
      {:ok, _pid} ->
        Logger.info("[launcher] watching #{@device}: A launches, Start stops, Y diagnostics")
        {:ok, new_state()}

      {:error, reason} ->
        # No buttons is not a reason to fail the boot -- the UI is still
        # useful, and this is the only thing that would be lost.
        Logger.warning("[launcher] #{@device} unavailable: #{inspect(reason)}")
        {:ok, new_state()}
    end
  end

  defp new_state, do: %{port: nil, held: MapSet.new(), scene: :home}

  @impl GenServer
  def handle_call(:running?, _from, state), do: {:reply, state.port != nil, state}

  def handle_call(:os_pid, _from, %{port: nil} = state), do: {:reply, nil, state}

  def handle_call(:os_pid, _from, state) do
    case Port.info(state.port, :os_pid) do
      {:os_pid, pid} -> {:reply, pid, state}
      _ -> {:reply, nil, state}
    end
  end

  def handle_call(:launch, _from, state), do: {:reply, :ok, do_launch(state)}
  def handle_call(:stop, _from, state), do: {:reply, :ok, do_stop(state)}

  @impl GenServer
  def handle_info({:input_event, _device, events}, state) do
    state =
      Enum.reduce(events, state, fn
        # value 1 is press and 0 is release; 2 is autorepeat and is ignored.
        # Releases matter now: the power-off chord needs to know what is held.
        {:ev_key, key, 1}, acc -> acc |> hold(key) |> press(key)
        {:ev_key, key, 0}, acc -> release(acc, key)
        _, acc -> acc
      end)

    {:noreply, state}
  end

  # The program exited on its own.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("[launcher] #{Path.basename(@program)} exited (#{status})")
    repaint(state)
    {:noreply, %{state | port: nil}}
  end

  def handle_info({port, {:data, _}}, %{port: port} = state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp hold(state, key), do: %{state | held: MapSet.put(state.held, key)}
  defp release(state, key), do: %{state | held: MapSet.delete(state.held, key)}

  defp press(state, @launch_button), do: do_launch(state)
  defp press(state, @stop_button), do: do_stop(state)
  defp press(state, @diagnostics_button), do: toggle_scene(state)

  defp press(state, @poweroff_button) do
    if MapSet.member?(state.held, @poweroff_modifier), do: poweroff()
    state
  end

  defp press(state, @audio_button) do
    # Refuses unless config :scenic_rg40xxv, audio_test: true. Pressing X on a
    # device that has not been armed does nothing and says so in the log.
    case ScenicRg40xxv.Audio.run() do
      :ok -> Logger.info("[launcher] audio test finished")
      {:error, reason} -> Logger.info("[launcher] audio test skipped: #{inspect(reason)}")
    end

    state
  end

  defp press(state, _key), do: state

  # Flip between the demo scene and the diagnostics readout. The readout is
  # what makes the physical checks -- charger, volume keys, headphone jack --
  # answerable by looking at the device instead of over SSH.
  defp toggle_scene(state) do
    next = if state.scene == :home, do: :diagnostics, else: :home
    show(next)
    %{state | scene: next}
  end

  defp poweroff do
    Logger.info("[launcher] Select+Menu: powering off")

    # Whether poweroff/0 brings this board down cleanly is the genuinely
    # unknown part. The PMIC power key is not wired into Linux here
    # (CONFIG_INPUT_AXP20X_PEK is unset and there is no power-key node), so
    # this is the only orderly shutdown the device has.
    Nerves.Runtime.poweroff()
  end

  defp do_launch(%{port: nil} = state) do
    if File.exists?(@program) do
      Logger.info("[launcher] launching #{@program}")

      port =
        Port.open({:spawn_executable, String.to_charlist(@program)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout
        ])

      %{state | port: port}
    else
      Logger.warning("[launcher] #{@program} not installed")
      state
    end
  end

  defp do_launch(state) do
    Logger.info("[launcher] already running")
    state
  end

  defp do_stop(%{port: nil} = state), do: state

  defp do_stop(%{port: port} = state) do
    # Closing the port shuts the pipes but does not reliably stop a program
    # that never reads stdin, and kmscube does not. Signal the OS process.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
      _ -> :ok
    end

    _ = try do: Port.close(port), rescue: (_ -> :ok)

    Logger.info("[launcher] stopped")
    repaint(state)
    %{state | port: nil}
  end

  # Scenic redraws on change, so the panel keeps the external program's last
  # frame until the viewport is pushed again. Coming back from kmscube has to
  # return to whichever scene was showing, not always the home one -- watching
  # the GPU temperature climb means being on diagnostics before and after.
  defp repaint(%{scene: scene}), do: show(scene)

  defp show(:diagnostics), do: set_root(ScenicRg40xxv.Scene.Diagnostics)
  defp show(_home), do: set_root(default_scene())

  defp set_root(nil), do: :ok

  defp set_root(scene) do
    case Scenic.ViewPort.info(:main_viewport) do
      {:ok, vp} -> Scenic.ViewPort.set_root(vp, scene)
      _ -> :ok
    end
  end

  defp default_scene do
    get_in(Application.get_env(:scenic_rg40xxv, :viewport), [:default_scene])
  end
end
