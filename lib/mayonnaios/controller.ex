defmodule MayonnaiOS.Controller do
  @moduledoc """
  The controller app: the handheld pretending to be a Bluetooth gamepad.

  Start it and the RG40XXV advertises itself as a BLE HID gamepad. Pair from
  a Steam Deck, a Windows machine or anything else that speaks HID over GATT,
  and the buttons go there instead of to the launcher. Menu comes back.

      iex> MayonnaiOS.Controller.start()
      iex> MayonnaiOS.Controller.status()
      iex> MayonnaiOS.Controller.stop()

  It is also a menu entry, which is the way it is meant to be used: the
  launcher starts it, forwards the gamepad to it, and stops it when Menu is
  pressed. `MayonnaiOS.Programs` calls that an app rather than a program --
  the difference is a module rather than a path, and no external process.

  ## What starting it takes over

  Four processes, all under one supervisor, all stopped together:

      MayonnaiOS.Bluetooth.Bonds       the keys paired hosts come back with
      MayonnaiOS.Bluetooth.Host        hci0, held open for as long as this runs
      MayonnaiOS.Bluetooth.Peripheral  advertising, the connection, the profile
      MayonnaiOS.Controller.Pad        buttons in, HID reports out
      MayonnaiOS.Controller.Battery    the charge level, once a minute

  `Host` holding the socket is the part with a consequence elsewhere: while
  this app is running, the raw HCI user channel is taken, so
  `MayonnaiOS.Diagnostics.probe_bluetooth/0` will answer `:eusers` rather than
  a version. That is not a fault, it is the same device being used for
  something. Stopping the app gives it back.

  The strategy is `:one_for_all` on purpose. If the socket dies the connection
  is gone whatever the peripheral believes, and a peripheral holding a stale
  connection handle would go on cheerfully dropping reports into it. Restart
  the lot, advertise again, and let the host reconnect -- which, with a bond
  stored, it does on its own.

  ## Starting it can fail, and it says so rather than looping

  `start/0` returns `{:error, reason}` when the controller cannot be opened,
  and the reasons are the bind errors listed in
  `MayonnaiOS.Bluetooth.HCISocket`. The common one on a device where something
  else took Bluetooth first is `:eusers`; `:enodev` means the Realtek part
  never appeared, which is a boot-time problem and not this app's.

  Nothing retries. A handheld that silently retries a radio it cannot open is
  a handheld with a flat battery and no explanation.
  """

  use Supervisor

  alias MayonnaiOS.Bluetooth.{Bonds, Host, Peripheral}
  alias MayonnaiOS.Controller.Pad

  @sessions MayonnaiOS.Controller.Sessions

  @doc """
  Start the app.

  Returns `{:ok, pid}`, `{:error, {:already_started, pid}}` when it is already
  running, or the reason the Bluetooth controller could not be opened.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    case DynamicSupervisor.start_child(@sessions, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:error, {:already_started, pid}}
      {:error, reason} -> {:error, unwrap(reason)}
    end
  end

  @doc "Stop the app and give hci0 back."
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@sessions, pid)
    end
  end

  @doc "Whether the app is running."
  @spec active?() :: boolean()
  def active?, do: Process.whereis(__MODULE__) != nil

  @doc """
  Forward an evdev report to the pad.

  Called by `MayonnaiOS.Launcher` while controller mode is on. Safe to call
  when the app is not running, because the launcher's view of that and the
  actual state of the supervisor can differ for the moment it takes to stop.
  """
  @spec input([tuple()]) :: :ok
  def input(events) do
    if Process.whereis(Pad), do: Pad.input(events), else: :ok
  end

  @doc """
  What the host sees, and what is stopping it if it sees nothing.

  Returns `:stopped` when the app is not running.
  """
  @spec status() :: map() | :stopped
  def status do
    if Process.whereis(Peripheral), do: Peripheral.status(), else: :stopped
  end

  @doc """
  Forget every paired host.

  The other half of this is removing the device on the host, and doing only
  one of the two leaves a host that reconnects, cannot decrypt, and reports a
  broken device. The panel says both; this is the half that is ours.
  """
  @spec unpair() :: :ok
  def unpair do
    if Process.whereis(Bonds), do: Bonds.clear(), else: :ok
    if Process.whereis(Peripheral), do: Peripheral.disconnect(), else: :ok
    :ok
  end

  @doc """
  The scene the launcher shows while this app has the buttons.

  Named by the app rather than looked up by the launcher, so that adding a
  second app is a config line and a module and touches nothing else.
  """
  @spec scene() :: module()
  def scene, do: MayonnaiOS.Scene.Controller

  @doc "The DynamicSupervisor the session runs under, for the application tree."
  @spec sessions() :: Supervisor.child_spec()
  def sessions do
    %{
      id: @sessions,
      start: {DynamicSupervisor, :start_link, [[name: @sessions, strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      # A session that cannot start should not be started again by a
      # supervisor: the reason is on the panel and in the log, and retrying a
      # radio that answered :enodev will answer :enodev again.
      restart: :temporary
    }
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      Bonds,
      {Host, Keyword.take(opts, [:dev])},
      {Peripheral, Keyword.take(opts, [:name])},
      {Pad, Keyword.take(opts, [:sink])},
      {MayonnaiOS.Controller.Battery, Keyword.take(opts, [:interval_ms])}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  # Supervisor.start_link reports a child's failure wrapped in enough
  # bookkeeping to hide the bind error, which is the only part anyone wants.
  defp unwrap({:shutdown, {:failed_to_start_child, _child, reason}}), do: unwrap(reason)
  defp unwrap(reason), do: reason
end
