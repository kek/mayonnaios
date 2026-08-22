defmodule MayonnaiOS.Bluetooth.FakeController do
  @moduledoc """
  A Bluetooth controller that says yes to everything, for the tests.

  Registered under the name the real `MayonnaiOS.Bluetooth.Host` uses, so
  anything above the socket -- the peripheral, the scanner -- can be started
  against it unchanged. Commands are forwarded to the test process as
  `{:command, opcode, params}` and ACL packets as `{:acl, packets}`.

  This started life inside `MayonnaiOS.Bluetooth.PeripheralTest`, which is
  where the reasoning for it belongs and still lives: the pieces of this stack
  that are worth testing this way are the ones whose bugs are interactions
  between four protocols rather than a wrong byte. It moved out here when the
  scanner needed the same seam, because two fake controllers that drift apart
  are worse than one that is a little more general than either caller needs.

  What it buys is the part that is otherwise only testable on the device with
  another machine in the other hand. What it does not prove is that the real
  controller behaves this way; this one answers every command with success,
  and the Realtek part has opinions.

  ## Pushing events back

  `emit/1` sends a decoded packet to whoever last called `attach/1`, in the
  `{:hci, packet}` shape the real host uses. That is how a test plays a
  connection, or a room full of advertisers, without a radio.
  """

  use GenServer

  @doc """
  Start the fake under the real host's name.

  `test` is the process that receives the command and ACL notifications.
  """
  def start_link(test) when is_pid(test), do: start_link(test: test)

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: MayonnaiOS.Bluetooth.Host)
  end

  @doc "Send one decoded packet to the attached process, as the host would."
  def emit(packet), do: GenServer.call(MayonnaiOS.Bluetooth.Host, {:emit, packet})

  @doc "Every opcode this fake has been asked for, most recent first."
  def commands, do: GenServer.call(MayonnaiOS.Bluetooth.Host, :commands)

  @impl true
  def init(opts) do
    {:ok,
     %{
       test: Keyword.fetch!(opts, :test),
       address: Keyword.get(opts, :address, <<0xB6, 0xB5, 0xB4, 0xB3, 0xB2, 0xB1>>),
       owner: nil,
       commands: []
     }}
  end

  @impl true
  def handle_call({:attach, pid}, _from, state), do: {:reply, :ok, %{state | owner: pid}}

  def handle_call({:command, <<0x01, opcode::16-little, _len, params::binary>>, _t}, _from, state) do
    send(state.test, {:command, opcode, params})
    {:reply, {:ok, return_params(opcode, state)}, %{state | commands: [opcode | state.commands]}}
  end

  def handle_call({:acl, packets}, _from, state) do
    send(state.test, {:acl, packets})
    {:reply, :ok, state}
  end

  def handle_call({:buffers, _length, _count}, _from, state), do: {:reply, :ok, state}
  def handle_call(:packet_length, _from, state), do: {:reply, 27, state}
  def handle_call(:commands, _from, state), do: {:reply, state.commands, state}

  def handle_call({:emit, packet}, _from, state) do
    if state.owner, do: send(state.owner, {:hci, packet})
    {:reply, :ok, state}
  end

  # LE Read Buffer Size: four packets of 27 bytes, which is a realistic answer
  # and small enough that a report descriptor read has to fragment.
  defp return_params(0x2002, _state), do: <<27::16-little, 4>>
  defp return_params(0x1009, state), do: state.address
  defp return_params(_other, _state), do: <<>>
end
