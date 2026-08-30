defmodule MayonnaiOS.LowPower.Renderer do
  @moduledoc """
  Stops Scenic drawing to a panel nobody is looking at, and starts it again.

  The measurement this module exists for, taken on firmware `3cc86f59` over a
  30-second idle sample with a static screen:

      pid 174 (scenic_driver_l): 285 ticks = 9.5% of one core

  That is the `scenic_driver_local` port program, rendering with cairo on the
  CPU into `/dev/fb0`, and it does not stop when the backlight does -- the
  current sleep turns off a GPIO and nothing else, so the same frame is
  composited over and over behind a dark LED. Next to `beam.smp` at 3.2% it is
  the largest single piece of work this device does at rest.

  ## Stopping the driver, not the viewport

  `Scenic.ViewPort.stop_driver/2` and `start_driver/2` are the public API for
  exactly this, and they leave the viewport, the scene and the scene's state
  alone: only the driver goes. The scene is not restarted, no `Scenic.Graph`
  is rebuilt, and `MayonnaiOS.Scene.Home` never learns this happened.

  Two alternatives were rejected. `:sys.suspend/1` on the driver leaves its
  frame messages accumulating in a mailbox that nothing drains, so a night
  asleep would be a mailbox with a night of frames in it and a burst of
  rendering on waking. Setting `limit_ms` very high is not reachable at
  runtime and would still leave the port program resident.

  ## Order, and why the panel stays dark until this is back

  `MayonnaiOS.LowPower` applies this step first and therefore restores it
  last, and `MayonnaiOS.Launcher` turns the backlight on only after
  `leave/1` has returned. So the sequence on waking is: cores back, governor
  back, WiFi back, **driver back and drawing**, and only then light. What the
  panel shows when it lights is a frame this driver just rendered.

  Scenic re-sends the scene's scripts to a driver that joins a viewport, so
  the new driver draws the current scene rather than an empty screen. That is
  the part of this module least able to be checked away from the hardware, and
  the note in the test file says so.

  ## What is left running

  The display engine, the TCON and the DSI link. `card0-DSI-1` reads
  `dpms=On`, so the pipeline goes on scanning the framebuffer out of DRAM at
  60 Hz whether or not anything writes to it. Turning that off means DPMS or
  unbinding the DRM device, and `MayonnaiOS.Sleep` records why
  `/sys/class/graphics/fb0/blank` cannot be believed on this stack -- it reads
  `4` (POWERDOWN) today while the backlight is on and the connector is `On`.
  That is a separate piece of work against an out-of-tree display stack, and
  it is not attempted here.

  ## On a laptop

  There is a viewport under `MIX_TARGET=host` too, but the tests do not start
  one, so `enter/0` finds no viewport and returns `:noop`. That is the honest
  outcome: this step is checkable on the device and nowhere else.
  """

  require Logger

  @default_viewport :main_viewport

  @doc """
  The registered name of the viewport whose driver is stopped.

  Read from `config :mayonnaios, :viewport`, which is the same keyword list
  Scenic is started with, so the name is written down once.
  """
  @spec viewport_name() :: atom()
  def viewport_name do
    :mayonnaios
    |> Application.get_env(:viewport, [])
    |> Keyword.get(:name, @default_viewport)
  end

  @doc """
  Stop the local driver, returning what `leave/1` needs to start it again.

  `:noop` when there is no viewport running, or when it has no drivers
  configured to stop.
  """
  @spec enter() :: {Scenic.ViewPort.t(), keyword()} | :noop
  def enter do
    with {:ok, viewport} <- info(),
         [_ | _] = drivers <- driver_opts() do
      # Every configured driver, not just the first: the configuration is a
      # list, and stopping one of two would leave the other rendering.
      Enum.each(drivers, &stop(viewport, &1))
      {viewport, drivers}
    else
      _ -> :noop
    end
  end

  @doc """
  Start the drivers again, from the same options the viewport was built with.
  """
  @spec leave({Scenic.ViewPort.t(), keyword()}) :: :ok
  def leave({viewport, drivers}) do
    Enum.each(drivers, fn opts ->
      case Scenic.ViewPort.start_driver(viewport, opts) do
        {:ok, _pid} ->
          :ok

        other ->
          # A driver that does not come back is a black screen with a working
          # power button, so this is a warning and not a debug line. The
          # backlight still comes on -- see the Launcher -- because a dark
          # panel plus dead buttons is worse than a dark panel.
          Logger.warning("[low_power] the renderer did not restart: #{inspect(other)}")
      end
    end)
  end

  # The driver is registered under the name its own options give it, which is
  # how it is found without asking the viewport for a list it does not offer.
  defp stop(viewport, opts) do
    case opts |> Keyword.get(:name) |> whereis() do
      nil -> :ok
      pid -> Scenic.ViewPort.stop_driver(viewport, pid)
    end
  end

  defp whereis(nil), do: nil
  defp whereis(name), do: Process.whereis(name)

  defp driver_opts do
    :mayonnaios
    |> Application.get_env(:viewport, [])
    |> Keyword.get(:drivers, [])
  end

  # `info/1` raises when the viewport is not registered, which is the ordinary
  # state in a test run and on any boot where the UI never started.
  defp info do
    Scenic.ViewPort.info(viewport_name())
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end
end
