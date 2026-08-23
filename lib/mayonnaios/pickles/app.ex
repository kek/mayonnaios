defmodule MayonnaiOS.Pickles.App do
  @moduledoc """
  The launcher's handle on graphical pickles.

  The launcher already has a notion of an app: a module with `start`, `stop`,
  `input/1` and `scene/0`, launched from a menu row and left with Menu. This
  module is that contract, once, for every pickle -- the row carries which
  one (`app: {MayonnaiOS.Pickles.App, "paint"}`), `start/1` remembers it, and
  everything else the launcher calls is about "the pickle currently on the
  panel".

  ## Start is attach, stop is detach

  A ui pickle is still a pickle: a background process that may be polling a
  lamp whether or not anyone is looking. So the launcher starting it means
  "ensure it runs, then put its face on the panel", and Menu means "take the
  face away" -- the pickle keeps running. Stopping it for real is what the
  web API and `MayonnaiOS.Pickles.stop/1` are for.

  ## Input never waits on Lua

  The launcher forwards input from the process that owns the gamepad, and a
  script gets a 30-second budget per call -- those two must not meet. Events
  are translated to plastic-name button messages here and *sent* to the
  runner, which execs `on_button` and pushes a fresh frame to the scene in
  its own time. A slow script means a laggy pickle, never a laggy launcher.

  Menu is dropped, as `MayonnaiOS.Controller.Report` drops it: it is the way
  out, and a button that both exits and reaches the script would be a button
  you could not press safely. Autorepeat is dropped too, matching the
  launcher's own menu.
  """

  use GenServer

  alias MayonnaiOS.Pickles
  alias MayonnaiOS.Pickles.{Frame, Runner}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Launcher contract: ensure the pickle runs and make it the one on the panel.
  """
  def start(name) do
    with {:ok, _pid} <- Pickles.start(name) do
      GenServer.call(__MODULE__, {:show, name})
      {:ok, Runner.whereis(name)}
    end
  end

  @doc """
  Launcher contract: the player pressed Menu. The face comes off the panel;
  the pickle keeps running.
  """
  def stop do
    GenServer.call(__MODULE__, :hide)
  end

  @doc """
  Launcher contract: the scene to show. One scene serves every pickle; it
  asks `current/0` which one it is wearing.
  """
  def scene, do: MayonnaiOS.Scene.Pickle

  @doc """
  The pickle currently on the panel, or `nil`.
  """
  def current, do: GenServer.call(__MODULE__, :current)

  @doc """
  Launcher contract: forwarded gamepad events. Translated and passed on as
  messages; see the moduledoc for why nothing here blocks.
  """
  def input(events) do
    GenServer.cast(__MODULE__, {:input, events})
  end

  @impl true
  def init(_opts), do: {:ok, %{current: nil}}

  @impl true
  def handle_call({:show, name}, _from, state), do: {:reply, :ok, %{state | current: name}}
  def handle_call(:hide, _from, state), do: {:reply, :ok, %{state | current: nil}}
  def handle_call(:current, _from, state), do: {:reply, state.current, state}

  @impl true
  def handle_cast({:input, _events}, %{current: nil} = state), do: {:noreply, state}

  def handle_cast({:input, events}, %{current: name} = state) do
    case Runner.whereis(name) do
      nil ->
        {:noreply, state}

      pid ->
        for {:ev_key, key, value} <- events,
            value in [0, 1],
            button = Frame.button_name(key),
            button != nil do
          send(pid, {:ui_button, button, value == 1})
        end

        {:noreply, state}
    end
  end
end
