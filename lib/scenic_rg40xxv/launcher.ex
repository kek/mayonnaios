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
  """

  use GenServer
  require Logger

  @device "/dev/input/event0"

  # See the moduledoc: these are physical A and Start, not the atoms' names.
  @launch_button :btn_b
  @stop_button :btn_start

  @program "/usr/bin/kmscube"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether the external program is running right now.
  """
  def running?, do: GenServer.call(__MODULE__, :running?)

  @doc """
  Start or stop it from a console, without pressing anything.
  """
  def launch, do: GenServer.call(__MODULE__, :launch)
  def stop_program, do: GenServer.call(__MODULE__, :stop)

  @impl GenServer
  def init(_opts) do
    case InputEvent.start_link(@device) do
      {:ok, _pid} ->
        Logger.info("[launcher] watching #{@device}: A launches, Start stops")
        {:ok, %{port: nil}}

      {:error, reason} ->
        # No buttons is not a reason to fail the boot -- the UI is still
        # useful, and this is the only thing that would be lost.
        Logger.warning("[launcher] #{@device} unavailable: #{inspect(reason)}")
        {:ok, %{port: nil}}
    end
  end

  @impl GenServer
  def handle_call(:running?, _from, state), do: {:reply, state.port != nil, state}
  def handle_call(:launch, _from, state), do: {:reply, :ok, do_launch(state)}
  def handle_call(:stop, _from, state), do: {:reply, :ok, do_stop(state)}

  @impl GenServer
  def handle_info({:input_event, _device, events}, state) do
    state =
      Enum.reduce(events, state, fn
        # value 1 is press; 2 is autorepeat and 0 is release, both ignored.
        {:ev_key, @launch_button, 1}, acc -> do_launch(acc)
        {:ev_key, @stop_button, 1}, acc -> do_stop(acc)
        _, acc -> acc
      end)

    {:noreply, state}
  end

  # The program exited on its own.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("[launcher] #{Path.basename(@program)} exited (#{status})")
    repaint()
    {:noreply, %{state | port: nil}}
  end

  def handle_info({port, {:data, _}}, %{port: port} = state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

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
    repaint()
    %{state | port: nil}
  end

  # Scenic redraws on change, so the panel keeps the external program's last
  # frame until the viewport is pushed again.
  defp repaint do
    with {:ok, vp} <- Scenic.ViewPort.info(:main_viewport),
         scene when not is_nil(scene) <-
           get_in(Application.get_env(:scenic_rg40xxv, :viewport), [:default_scene]) do
      Scenic.ViewPort.set_root(vp, scene)
    else
      _ -> :ok
    end
  end
end
