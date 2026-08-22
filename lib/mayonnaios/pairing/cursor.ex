defmodule MayonnaiOS.Pairing.Cursor do
  @moduledoc """
  Which row of the paired-hosts list A acts on, and whether it is armed.

  The cursor lives in a process rather than in the scene for the same two
  reasons `MayonnaiOS.Launcher` keeps the menu cursor: the cairo-fb driver
  delivers no input, so a Scenic scene on this hardware can never receive a
  D-pad press, and `Scenic.ViewPort.set_root/3` replaces the scene process, so
  anything a scene remembered would be lost on the next repaint.

  ## Only the bonds are selectable

  The screen has two lists. The nearby devices are informational -- there is
  nothing this firmware can do with one, and a cursor that could land on a row
  where A does nothing is worse than a list with no cursor at all. So the
  cursor ranges over the paired hosts, and the one action is forgetting one.

  ## A twice, not a chord

  Forgetting a bond is not free: the host on the other side still has its key,
  reconnects, fails to encrypt, and reports a broken device until someone
  removes it there too. So the first A arms the selected row and the second
  one does it, which is a confirmation built out of the binding that already
  means "confirm" rather than a new chord nobody would discover.

  Moving the cursor disarms. Anything else -- a stray button, a direction on
  the analog stick -- leaves the arming alone, because a confirmation that can
  be cancelled by pressing a button that does nothing else is a confirmation
  someone will lose to a twitch.

  ## The index is a number, not a reference to a row

  It is taken modulo the list length wherever it is used and never clamped
  against a remembered list. Bonds appear while this screen is up -- the
  controller app is not running, so not often, but the file is shared and a
  console can write it -- and an index bounded at read time cannot point off
  the end of a list it has not seen.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Bluetooth.Bonds

  # The buttons, as printed on the shell. These atoms name the opposite
  # button; see MayonnaiOS.Launcher for the device tree that lies about it.
  # :btn_b is physical A.
  @confirm_button :btn_b
  @up_button :btn_dpad_up
  @down_button :btn_dpad_down

  defstruct selected: 0, armed: false

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Hand over one evdev report.

  A call rather than a cast, so that a console -- or a test that has just
  synthesised a press -- can read the cursor immediately afterwards and get
  the state that press produced.
  """
  @spec input([tuple()]) :: :ok
  def input(events), do: GenServer.call(__MODULE__, {:input, events})

  @doc "Where the cursor is, and whether A is armed."
  @spec state() :: %{selected: non_neg_integer(), armed: boolean()}
  def state, do: GenServer.call(__MODULE__, :state)

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:input, events}, _from, state) do
    {:reply, :ok, Enum.reduce(events, state, &press(&2, &1))}
  end

  def handle_call(:state, _from, state) do
    {:reply, %{selected: state.selected, armed: state.armed}, state}
  end

  # Value 1 is a press. 2 is autorepeat and is dropped, as it is in the
  # launcher: each move is a scene rebuild, and holding a direction down would
  # queue one per repeat.
  defp press(state, {:ev_key, @up_button, 1}), do: move(state, -1)
  defp press(state, {:ev_key, @down_button, 1}), do: move(state, +1)
  defp press(state, {:ev_key, @confirm_button, 1}), do: confirm(state)
  defp press(state, _event), do: state

  defp move(state, delta) do
    case count() do
      0 ->
        %{state | selected: 0, armed: false}

      count ->
        %{state | selected: Integer.mod(state.selected + delta, count), armed: false}
    end
  end

  # First A arms, second A forgets. Arming an empty list is not a state worth
  # having: there is nothing to confirm and the screen would say "A again to
  # forget" over a list with no rows in it.
  defp confirm(%{armed: false} = state) do
    if count() == 0, do: state, else: %{state | armed: true}
  end

  defp confirm(state) do
    case Enum.at(bonds(), Integer.mod(state.selected, max(count(), 1))) do
      nil ->
        %{state | armed: false}

      bond ->
        Logger.info("[pairing] forgetting the bond for #{inspect(bond.peer)}")
        Bonds.forget(bond.peer)

        # The cursor stays where it is rather than following the bond that was
        # just dropped. The list is one row shorter, so the row now under the
        # cursor is the one that was below -- which is what a list that shrinks
        # under a fixed cursor does everywhere else, and better than jumping to
        # the top.
        %{state | armed: false}
    end
  end

  defp bonds do
    if Process.whereis(Bonds), do: Bonds.list(), else: []
  end

  defp count, do: length(bonds())
end
