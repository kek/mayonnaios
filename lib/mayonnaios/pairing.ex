defmodule MayonnaiOS.Pairing do
  @moduledoc """
  The Bluetooth devices app: what is nearby, what is paired, and what this
  firmware can actually do with either.

      iex> MayonnaiOS.Pairing.start()
      iex> MayonnaiOS.Pairing.status()
      iex> MayonnaiOS.Pairing.stop()

  An app rather than a program, on the same terms as `MayonnaiOS.Controller`:
  a module in this firmware, started in this VM, with a scene of its own and
  no external process. It takes hci0 for as long as it runs, so it and the
  controller app cannot both be up -- which is why both are menu entries and
  neither is in the boot supervision tree.

  ## Headphones do not work, and this screen says so on purpose

  This app was asked for as "a UI for pairing and connecting Bluetooth
  devices like headphones". It does not connect headphones, and it is built so
  that nobody can spend an evening finding that out.

  Bluetooth audio is A2DP. A2DP runs over BR/EDR -- the classic transport --
  and needs, in order: BR/EDR HCI (inquiry, create connection, link keys,
  Secure Simple Pairing), connection-oriented L2CAP channels, an SDP client,
  AVDTP signalling, an SBC encoder, and something to route the audio a game
  is producing into that stream. None of those exist here:

    * There is no BlueZ in the image. Checked on the device rather than
      inferred -- no `/usr/lib/bluetooth`, no `/etc/bluetooth`, no
      `bluetoothctl`, `hciconfig`, `btmon` or `sdptool` anywhere on `$PATH`
      -- and no `BR2_PACKAGE_BLUEZ5_UTILS` in the system's `nerves_defconfig`
      to put one there.
    * `MayonnaiOS.Bluetooth.HCI` implements no BR/EDR command at all, and
      `MayonnaiOS.Bluetooth.L2CAP` is the three fixed LE channels with no
      connection-oriented channel to carry AVDTP over.
    * There is no PulseAudio, PipeWire or `bluez-alsa` in the image either,
      so even a working A2DP source in this VM would have no way to be handed
      RetroArch's audio.

    The first and last of those are Buildroot options, so getting there is a
    full system rebuild before any of the Elixir exists. That is why this
    app scans and lists rather than offering a Connect button: a button that
    can never produce sound is this project's characteristic failure written
    into the UI.

  So the screen names the missing piece, and `MayonnaiOS.Bluetooth.Scan`
  reads the BR/EDR flag out of each advertisement so that the row for a pair
  of headphones says which transport it would need. Adding audio later is a
  profile under `MayonnaiOS.Bluetooth` and a row action in
  `MayonnaiOS.Scene.Pairing`; nothing else here has to move.

  ## What it does do

      scan          active LE scan, names and signal strength, ages out
      paired hosts  the LE bonds from the controller app, listed
      forget        drop one bond, fsynced, survives a power cut

  Forgetting a bond has until now been an IEx call, which means the only way
  to undo a pairing on a handheld with no keyboard was over SSH.

  ## What starting it takes over

      MayonnaiOS.Bluetooth.Bonds     the keys paired hosts come back with
      MayonnaiOS.Bluetooth.Host      hci0, held open for as long as this runs
      MayonnaiOS.Bluetooth.Scanner   scan parameters, scan enable, the list
      MayonnaiOS.Pairing.Cursor      the D-pad, and which row A acts on

  `:one_for_all`, because a scanner holding a list built through a socket that
  has died would go on showing devices that stopped advertising minutes ago.
  """

  use Supervisor

  alias MayonnaiOS.Bluetooth.{Bonds, HCI, Host, Scanner}
  alias MayonnaiOS.Pairing.Cursor

  @sessions MayonnaiOS.Pairing.Sessions

  @doc """
  Start the app.

  The failure reasons are the bind errors in
  `MayonnaiOS.Bluetooth.HCISocket`, plus `{:already_started, pid}` from `Host`
  when the controller app has hci0. Nothing retries, with the one exception
  `Host` makes for `:enodev` -- it rebinds the serdev driver once and opens
  again, so a missing hci0 is recovered here as well as in the controller app.
  See `MayonnaiOS.Bluetooth.Serdev`. Otherwise the reason goes to the panel.
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
  Forward an evdev report to the cursor.

  Called by `MayonnaiOS.Launcher` while this app has the buttons. Menu never
  reaches here -- the launcher keeps that one for itself as the way out --
  and everything else this app does not use is dropped by the cursor.
  """
  @spec input([tuple()]) :: :ok
  def input(events) do
    if Process.whereis(Cursor), do: Cursor.input(events), else: :ok
  end

  @doc "The scene the launcher shows while this app has the buttons."
  @spec scene() :: module()
  def scene, do: MayonnaiOS.Scene.Pairing

  @doc """
  Everything the screen draws, in one call.

  Assembled here rather than in the scene so that the scene has no opinion
  about where any of it comes from, and so that a console can read the whole
  screen as a term. Returns `:stopped` when there is nothing to report, which
  is a state the scene renders rather than crashes on.

  The test is for the scanner rather than for this supervisor, and that is on
  purpose: the scanner is the part that holds the radio, so its absence is the
  thing that makes the screen meaningless. It also means the pieces can be
  stood up individually against a fake controller and this function still
  answers, which is how the screen is tested on a machine with no
  `AF_BLUETOOTH` at all.
  """
  @spec status() :: map() | :stopped
  def status do
    if Process.whereis(Scanner) do
      cursor = cursor_state()
      bonds = list_bonds()

      %{
        scan: Scanner.status(),
        devices: Scanner.devices(),
        bonds: bonds,
        # Bounded here rather than trusted: the list is re-read on every
        # refresh and a bond forgotten a moment ago would otherwise leave the
        # cursor pointing past the end.
        selected: bounded(cursor.selected, length(bonds)),
        armed: cursor.armed
      }
    else
      :stopped
    end
  end

  @doc """
  The paired hosts, in the shape the screen wants them.

  The bond store keys on EDIV and Rand, which are the right thing to look a
  key up by and useless to show anyone. The peer address is what a person can
  match against the machine in front of them, so that is what comes out here.
  """
  @spec list_bonds() :: [map()]
  def list_bonds do
    Enum.map(bonds(), fn bond ->
      {type, address} = bond.peer

      %{
        peer: bond.peer,
        address: HCI.address(address),
        # 0x01 is a random address. Windows connects from a resolvable
        # private one that changes every fifteen minutes, so a random address
        # here is not something to match against a sticker on a laptop -- it
        # is worth saying on the row rather than letting someone try.
        random?: type == 0x01,
        key_size: bond.key_size
      }
    end)
  end

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
      # As with the controller app: a session that could not open the radio
      # will not open it on a retry either, and the reason belongs on the
      # panel rather than in a restart loop.
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
      {Scanner, Keyword.take(opts, [:type])},
      Cursor
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp bonds do
    if Process.whereis(Bonds), do: Bonds.list(), else: []
  end

  defp cursor_state do
    if Process.whereis(Cursor), do: Cursor.state(), else: %{selected: 0, armed: false}
  end

  defp bounded(_selected, 0), do: 0
  defp bounded(selected, count), do: Integer.mod(selected, count)

  defp unwrap({:shutdown, {:failed_to_start_child, _child, reason}}), do: unwrap(reason)
  defp unwrap(reason), do: reason
end
