defmodule MayonnaiOS.Bluetooth.Host do
  @moduledoc """
  The process that owns hci0 and turns it into messages.

  One socket, one process, for as long as Bluetooth is in use. That is a
  change from `MayonnaiOS.Bluetooth.HCISocket.probe/1`, which opens the
  controller and closes it again within a call: a peripheral has to hold the
  device, because closing the user channel closes hci0 and drops any
  connection with it.

  Above this process everything is messages. Commands are calls that block
  until the controller answers; events and ACL data are sent to whichever
  process called `attach/1`.

  ## Commands go one at a time

  HCI allows several commands outstanding at once and this sends one. The
  controller answers a command in well under a millisecond and nothing here
  sends them in bulk, so the queue never grows; what serialising buys is that
  a Command Complete can be matched to its command by opcode without also
  having to reason about two commands with the same opcode being in flight.

  A command that is never answered would otherwise wedge the queue for good,
  so each has a deadline and a timed-out command is reported and dropped.
  That case is worth watching for rather than papering over: on this board it
  most likely means the H5 link to the controller has desynchronised, which
  `dmesg` will say and nothing at this level can fix.

  ## Reading without blocking

  `:socket.recv/3` in `:nowait` mode returns `{:select, info}` when there is
  nothing to read and then sends `{:"$socket", socket, :select, handle}` when
  there is. So the GenServer never blocks on the socket and never needs a
  second process to read it -- which matters because a socket read from two
  processes is a socket whose ownership on close is a matter of opinion.

  ## ACL credits, and why a dropped report is the right answer

  The controller can hold a small number of ACL packets -- typically four to
  eight on a part like this one -- and sending more than it can hold is a
  protocol violation, not a queue. `send_acl/1` therefore counts credits and
  refuses a PDU that will not fit, and the refusal goes back to the caller.

  For a gamepad that is the correct behaviour and not a compromise. The thing
  being sent is the *current* state of the buttons; if it cannot go now, the
  next one supersedes it a few milliseconds later. Queueing them would deliver
  a burst of stale states after the stall, which in a game reads as the
  controller sticking and then catching up.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Bluetooth.{HCI, HCISocket}

  @command_timeout 5_000

  # Used only until LE Read Buffer Size answers. Small enough to be safe on
  # any controller, and never used to send anything before that answer.
  @fallback_packet_length 27
  @fallback_credits 1

  defstruct socket: nil,
            owner: nil,
            monitor: nil,
            pending: nil,
            queue: :queue.new(),
            credits: @fallback_credits,
            total_credits: @fallback_credits,
            packet_length: @fallback_packet_length

  @doc """
  Open hci0 and hold it.

  Fails with the bind error when the controller is not there or is already
  owned; `MayonnaiOS.Bluetooth.HCISocket`'s moduledoc has what each one means.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the socket is open right now."
  @spec running?() :: boolean()
  def running?, do: Process.whereis(__MODULE__) != nil

  @doc """
  Receive events and ACL data.

  The attached process gets `{:hci, decoded}` for everything the controller
  sends that is not the completion of a command in flight. Only one process at
  a time; attaching replaces whoever was there.
  """
  @spec attach(pid()) :: :ok
  def attach(pid \\ self()), do: GenServer.call(__MODULE__, {:attach, pid})

  @doc """
  Send a command and wait for its completion.

  Takes a whole command packet as `MayonnaiOS.Bluetooth.HCI` builds them.
  Returns the return parameters with the status byte already checked, so
  `{:ok, <<>>}` is the ordinary answer for a command that returns nothing.
  """
  @spec command(binary(), timeout()) :: {:ok, binary()} | {:error, term()}
  def command(packet, timeout \\ @command_timeout) do
    GenServer.call(__MODULE__, {:command, packet, timeout}, timeout + 1_000)
  end

  @doc """
  Send the ACL packets of one PDU, or none of them.

  `{:error, :no_credits}` means the controller's buffers are full. See the
  moduledoc for why that is reported rather than queued.
  """
  @spec send_acl([binary()]) :: :ok | {:error, term()}
  def send_acl(packets), do: GenServer.call(__MODULE__, {:acl, packets})

  @doc "The controller's ACL payload limit, which is what fragments are cut to."
  @spec packet_length() :: pos_integer()
  def packet_length, do: GenServer.call(__MODULE__, :packet_length)

  @doc """
  Read the controller's buffer sizes and remember them.

  Called during setup, after Reset. Falls back to the BR/EDR buffer sizes when
  the LE ones come back as zero, which is what a controller sharing one pool
  between the two transports reports -- taking that zero at face value would
  mean never sending anything.

  This runs in the *caller's* process and reaches the socket only through
  `command/2`, which is a call like any other. That is deliberate and not an
  accident of style: this process has a `recv` selected on the socket almost
  all of the time, and a second read issued from inside the same process while
  that select is outstanding is not a queued read -- it is an error, and one
  that would only show up on the device.
  """
  @spec read_buffers() :: {:ok, map()} | {:error, term()}
  def read_buffers do
    with {:ok, params} <- command(HCI.le_read_buffer_size()),
         {:ok, length, count, source} <- sizes(params) do
      :ok = GenServer.call(__MODULE__, {:buffers, length, count})
      Logger.info("[hci] #{source} buffers: #{count} packets of #{length} bytes")
      {:ok, %{packet_length: length, count: count, source: source}}
    end
  end

  defp sizes(<<length::16-little, count>>) when length > 0 and count > 0 do
    {:ok, length, count, :le}
  end

  defp sizes(_zeros) do
    case command(HCI.read_buffer_size()) do
      {:ok, <<length::16-little, _sco, count::16-little, _sco_count::16-little>>}
      when length > 0 and count > 0 ->
        {:ok, length, count, :shared}

      {:ok, _unusable} ->
        {:error, :no_buffer_size}

      error ->
        error
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case HCISocket.open(Keyword.get(opts, :dev, 0)) do
      {:ok, socket} ->
        state = %__MODULE__{socket: socket}
        {:ok, poll(state)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    {:reply, :ok, %{state | owner: pid, monitor: Process.monitor(pid)}}
  end

  def handle_call({:command, packet, timeout}, from, state) do
    state = %{state | queue: :queue.in({packet, from, timeout}, state.queue)}
    {:noreply, dispatch(state)}
  end

  def handle_call({:acl, packets}, _from, state) do
    count = length(packets)

    if count <= state.credits do
      Enum.each(packets, &:socket.send(state.socket, &1))
      {:reply, :ok, %{state | credits: state.credits - count}}
    else
      {:reply, {:error, :no_credits}, state}
    end
  end

  def handle_call(:packet_length, _from, state), do: {:reply, state.packet_length, state}

  def handle_call({:buffers, length, count}, _from, state) do
    {:reply, :ok, %{state | packet_length: length, credits: count, total_credits: count}}
  end

  @impl true
  # The socket has something to read, or is ready to be asked again.
  def handle_info({:"$socket", socket, :select, _handle}, %{socket: socket} = state) do
    {:noreply, poll(state)}
  end

  def handle_info({:"$socket", socket, :abort, {_handle, reason}}, %{socket: socket} = state) do
    Logger.error("[hci] socket aborted: #{inspect(reason)}")
    {:stop, reason, state}
  end

  def handle_info({:command_timeout, opcode}, %{pending: {opcode, from, _}} = state) do
    Logger.error("[hci] no answer to #{inspect(HCI.opcode_name(opcode))}")
    GenServer.reply(from, {:error, {:timeout, opcode}})
    {:noreply, dispatch(%{state | pending: nil})}
  end

  def handle_info({:command_timeout, _opcode}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    {:noreply, %{state | owner: nil, monitor: nil}}
  end

  def handle_info(message, state) do
    Logger.debug("[hci] unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) when socket != nil do
    # Closing the socket closes hci0 with it, which drops any connection. That
    # is correct: a peripheral whose stack has stopped should not leave a host
    # believing it is still connected to a controller that will never report
    # another button.
    HCISocket.close(socket)
  end

  def terminate(_reason, _state), do: :ok

  # -- the socket -------------------------------------------------------------

  # Drain everything the socket has, then arm the select. Reading in a loop
  # matters when a burst arrives: one message from the socket layer can stand
  # for several packets, and stopping after the first would leave the rest
  # unread until something else happened to wake this process.
  defp poll(state) do
    case :socket.recv(state.socket, 0, :nowait) do
      {:ok, packet} ->
        state |> handle_packet(HCI.decode(packet)) |> poll()

      {:select, _info} ->
        state

      {:error, :closed} ->
        state

      {:error, reason} ->
        Logger.error("[hci] recv: #{inspect(reason)}")
        state
    end
  end

  defp handle_packet(state, {:event, :command_complete, %{opcode: opcode, params: params}}) do
    complete(state, opcode, HCI.status(params))
  end

  defp handle_packet(state, {:event, :command_status, %{opcode: opcode, status: status}}) do
    # Command Status carries no return parameters; an accepted command is
    # reported as an empty success so callers do not have to know which of the
    # two events their command produces.
    result = if status == 0, do: {:ok, <<>>}, else: {:error, {:hci_status, status}}
    complete(state, opcode, result)
  end

  defp handle_packet(state, {:event, :number_of_completed_packets, %{handles: handles}}) do
    returned = handles |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    %{state | credits: min(state.credits + returned, state.total_credits)}
  end

  defp handle_packet(state, packet) do
    if state.owner do
      send(state.owner, {:hci, packet})
    else
      Logger.debug("[hci] no owner for #{inspect(packet)}")
    end

    state
  end

  # A completion for the command in flight replies to its caller and starts
  # the next one. A completion for anything else is a completion for a command
  # that already timed out, and saying so is more useful than dropping it.
  defp complete(%{pending: {opcode, from, timer}} = state, opcode, result) do
    Process.cancel_timer(timer)
    GenServer.reply(from, result)
    dispatch(%{state | pending: nil})
  end

  defp complete(state, opcode, _result) do
    # Opcode 0x0000 with a nonzero allowed-commands count is the controller
    # saying "you may send commands again" rather than completing anything.
    unless opcode == 0x0000 do
      Logger.debug("[hci] late completion for #{inspect(HCI.opcode_name(opcode))}")
    end

    state
  end

  defp dispatch(%{pending: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {packet, from, timeout}}, queue} ->
        <<0x01, opcode::16-little, _rest::binary>> = packet

        case :socket.send(state.socket, packet) do
          :ok ->
            timer = Process.send_after(self(), {:command_timeout, opcode}, timeout)
            %{state | queue: queue, pending: {opcode, from, timer}}

          {:error, reason} ->
            GenServer.reply(from, {:error, reason})
            dispatch(%{state | queue: queue})
        end

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch(state), do: state
end
