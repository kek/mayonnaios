defmodule MayonnaiOS.Bluetooth.Bonds do
  @moduledoc """
  The keys that let a host reconnect without pairing again.

  A bond is a long-term key plus the EDIV and Rand that name it. The central
  keeps a copy, and when it reconnects it quotes the EDIV and Rand back; this
  device looks the pair up, hands the key to the controller, and the link
  encrypts without anyone touching a pairing dialog. Lose the file and every
  host that has paired has to be told to forget the device and pair again --
  which is not a crash, but it is the kind of thing that gets blamed on
  Bluetooth rather than on a missing file.

  ## Looked up by EDIV and Rand, not by address

  There is no address in the lookup, and that is deliberate. Windows connects
  from a resolvable private address that changes every fifteen minutes; a
  bond keyed by address would miss on the second reconnection. EDIV and Rand
  are chosen by this device precisely so that they can name a bond without
  needing to know who is asking.

  The peer address *is* stored, but only so that the UI has something to show
  and a person clearing one bond can tell which is which.

  ## Why a term file and not a database

  Two keys, sixteen bytes each, written when someone pairs. `:erlang.term_to_binary`
  and a rename over the top is the whole implementation, and a rename is
  atomic on ext4, so a power cut during a write leaves the previous file
  rather than half of a new one -- which matters on a handheld that is turned
  off by pulling the power.

  The file has no format version. When the shape here changes, a file that
  does not decode is treated as no bonds at all: re-pairing is a known, small
  cost, and code that migrates a two-key file is more of a liability than the
  thing it protects.
  """

  use GenServer
  require Logger

  @default_path "/root/bluetooth/bonds.bin"

  @typedoc "One host's bond."
  @type bond :: %{
          ltk: binary(),
          ediv: binary(),
          rand: binary(),
          peer: {0..1, binary()},
          key_size: pos_integer()
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Where the bonds live.

  Configurable so that the tests and a host session do not write to a path
  that only exists on the device.
  """
  @spec path() :: String.t()
  def path, do: Application.get_env(:mayonnaios, :bond_path, @default_path)

  @doc "Every bond, newest first."
  @spec list() :: [bond()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc """
  The key for an EDIV and Rand a central has quoted, or nil.

  Both are compared in wire order, as they arrived, because that is the only
  order either value is ever handled in.
  """
  @spec find(binary(), binary()) :: bond() | nil
  def find(ediv, rand), do: GenServer.call(__MODULE__, {:find, ediv, rand})

  @doc "Remember a bond, and write the file."
  @spec put(bond()) :: :ok
  def put(bond), do: GenServer.call(__MODULE__, {:put, bond})

  @doc """
  Forget everything.

  The counterpart to removing the device on the host side. Doing only one of
  the two leaves a host that reconnects, fails to encrypt, and reports a
  problem with the device -- so the UI offers this next to the instruction to
  remove it there as well.
  """
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(_opts) do
    {:ok, %{bonds: read()}}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.bonds, state}

  def handle_call({:find, ediv, rand}, _from, state) do
    {:reply, Enum.find(state.bonds, &(&1.ediv == ediv and &1.rand == rand)), state}
  end

  def handle_call({:put, bond}, _from, state) do
    # Newest first, and the same central pairing again replaces its old entry
    # rather than accumulating: a host that has been told to forget the device
    # and pair again would otherwise leave a key nothing can ever use.
    bonds = [bond | Enum.reject(state.bonds, &(&1.peer == bond.peer))]
    write(bonds)
    {:reply, :ok, %{state | bonds: bonds}}
  end

  def handle_call(:clear, _from, state) do
    write([])
    {:reply, :ok, %{state | bonds: []}}
  end

  defp read do
    with {:ok, binary} <- File.read(path()),
         {:ok, bonds} <- decode(binary) do
      bonds
    else
      {:error, :enoent} ->
        []

      other ->
        # A file that will not decode is reported and then ignored. Crashing
        # here would take the controller app down at boot over something that
        # costs one re-pairing to fix.
        Logger.warning("[bonds] ignoring #{path()}: #{inspect(other)}")
        []
    end
  end

  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :undecodable}
  end

  defp write(bonds) do
    path = path()
    temporary = path <> ".new"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, :erlang.term_to_binary(bonds)),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        Logger.error("[bonds] could not write #{path}: #{inspect(error)}")
        error
    end
  end
end
