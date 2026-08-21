defmodule MayonnaiOS.Bluetooth.L2CAP do
  @moduledoc """
  Cutting L2CAP PDUs into ACL packets and putting them back together.

  On LE, L2CAP is thin: there is no channel to open and no configuration to
  negotiate, just three fixed channel IDs that exist as soon as the connection
  does -- attributes on 0x0004, signalling on 0x0005, pairing on 0x0006. What
  is left is framing, and framing is where a stack quietly loses bytes.

  ## Why reassembly is not optional even for five-byte reports

  The reports this device sends are eight bytes of L2CAP payload and will
  never be fragmented. The *responses* are a different matter: the HID report
  descriptor is around eighty bytes, and the controller's ACL payload limit on
  this part is likely to be twenty-seven. So a host reading the Report Map
  gets a response that must be split, and a host that has raised the ATT MTU
  can send us a write that arrives split.

  Both directions are here, and both are tested against the awkward cases --
  a PDU exactly as long as one fragment, a continuation arriving before its
  start, a length field that promises more than turns up.

  ## The start flag differs by direction, and that is not a mistake

  Host to controller, the first fragment of a PDU is flagged 0b00, "first
  non-automatically-flushable". Controller to host it comes back as 0b10.
  Both mean start. `MayonnaiOS.Bluetooth.HCI.decode/1` already normalises the
  two into `:start`, so nothing here has to know -- but a capture read by hand
  shows different flags going each way, and it is worth knowing that is
  correct rather than a bug being looked at.

  ## Reassembly holds one PDU per connection, not a queue

  A single ACL connection delivers fragments in order and never interleaves
  two PDUs, so the reassembler is one buffer and an expected length. When a
  start fragment arrives with a partial PDU still buffered, the partial one is
  dropped rather than prepended: something has gone wrong on the link and the
  bytes already held are not part of the new message. Dropping is reported to
  the caller so it can be logged; carrying on silently would produce one
  corrupt PDU that parses as an ATT request for a random handle.
  """

  alias MayonnaiOS.Bluetooth.HCI

  @cid_signalling 0x0005
  @cid_att 0x0004
  @cid_smp 0x0006

  # LE signalling command codes.
  @command_reject 0x01
  @connection_parameter_update_request 0x12
  @connection_parameter_update_response 0x13

  @typedoc "One connection's worth of reassembly state."
  @type t :: %__MODULE__{expected: non_neg_integer() | nil, buffer: binary()}

  defstruct expected: nil, buffer: <<>>

  @doc "The ATT channel, 0x0004."
  def cid_att, do: @cid_att
  @doc "The LE signalling channel, 0x0005."
  def cid_signalling, do: @cid_signalling
  @doc "The security manager channel, 0x0006."
  def cid_smp, do: @cid_smp

  @doc "A fresh reassembler."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Wrap a payload in its L2CAP header: length, then channel.

  The length counts the payload only, not the four header bytes.
  """
  @spec encode(non_neg_integer(), binary()) :: binary()
  def encode(cid, payload) do
    <<byte_size(payload)::16-little, cid::16-little, payload::binary>>
  end

  @doc """
  Split a PDU into ACL packets of at most `max_payload` bytes each.

  Returns packets ready for the socket, in order. `max_payload` is the
  controller's LE ACL payload limit, which comes from LE Read Buffer Size --
  not the ATT MTU, which is a different limit at a different layer and is
  usually the smaller of the two.
  """
  @spec fragments(non_neg_integer(), binary(), pos_integer()) :: [binary()]
  def fragments(handle, pdu, max_payload) when max_payload > 0 do
    pdu
    |> chunk(max_payload)
    |> Enum.with_index()
    |> Enum.map(fn
      {chunk, 0} -> HCI.acl(handle, :start, chunk)
      {chunk, _} -> HCI.acl(handle, :continue, chunk)
    end)
  end

  defp chunk(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunk(binary, size) do
    <<head::binary-size(^size), rest::binary>> = binary
    [head | chunk(rest, size)]
  end

  @doc """
  Feed one ACL fragment in; get back any PDUs it completed.

  The result is `{pdus, state}` where each PDU is `{cid, payload}`. A fragment
  that only advances the buffer yields an empty list, which is the common case
  and not worth distinguishing.

  Anything malformed comes back as `{:error, reason}` in the list, in the
  place the PDU would have had, so a caller that logs the list logs the fault
  in order rather than losing it.
  """
  @spec receive(t(), :start | :continue, binary()) ::
          {[{non_neg_integer(), binary()} | {:error, term()}], t()}
  def receive(state, :start, data) do
    dropped =
      if state.buffer != <<>>,
        do: [{:error, {:dropped_partial, byte_size(state.buffer)}}],
        else: []

    case data do
      <<length::16-little, _cid::16-little, _rest::binary>> ->
        # length + 4 is the whole PDU including its header, which is what the
        # buffer accumulates: keeping the header means the completed PDU can
        # be parsed in one place instead of two.
        {pdus, state} = advance(%__MODULE__{expected: length + 4, buffer: data})
        {dropped ++ pdus, state}

      short ->
        {dropped ++ [{:error, {:short_header, short}}], new()}
    end
  end

  def receive(%__MODULE__{expected: nil} = state, :continue, data) do
    # A continuation with nothing to continue. The start fragment was lost or
    # this is the tail of a PDU dropped above; either way there is no honest
    # way to use these bytes.
    {[{:error, {:orphan_continuation, byte_size(data)}}], state}
  end

  def receive(state, :continue, data) do
    advance(%{state | buffer: state.buffer <> data})
  end

  defp advance(%__MODULE__{expected: expected, buffer: buffer})
       when byte_size(buffer) >= expected do
    <<pdu::binary-size(^expected), rest::binary>> = buffer

    <<_length::16-little, cid::16-little, payload::binary>> = pdu

    # More than one PDU in a single ACL packet is not something LE does, but
    # the leftover is reported rather than dropped in silence.
    leftover =
      if rest == <<>>, do: [], else: [{:error, {:trailing_bytes, byte_size(rest)}}]

    {[{cid, payload} | leftover], new()}
  end

  defp advance(state), do: {[], state}

  # -- LE signalling ----------------------------------------------------------

  @doc """
  A Connection Parameter Update Request, from the peripheral to the central.

  This is the latency knob. A central picks the connection interval when it
  connects, and hosts pick conservatively: Windows commonly settles on 30 ms
  or more, which puts up to 30 ms between a button going down and the report
  that says so leaving the device. A gamepad wants the floor -- 7.5 ms, the
  shortest interval LE has.

  The central is free to refuse or to grant something in between, and this
  request is sent once after connecting rather than retried, because a host
  that said no once will say no again and a request every second is just
  radio time.

  Intervals are in 1.25 ms units and the timeout in 10 ms units, which are
  three different units in one packet and the reason each is named here.
  """
  @spec connection_parameter_update_request(non_neg_integer(), keyword()) :: binary()
  def connection_parameter_update_request(identifier, opts \\ []) do
    # 6 * 1.25 ms = 7.5 ms, the minimum the specification allows.
    min = Keyword.get(opts, :min_interval, 6)
    # 12 * 1.25 ms = 15 ms.
    max = Keyword.get(opts, :max_interval, 12)
    # Skip no connection events: every one of them may carry a button press.
    latency = Keyword.get(opts, :latency, 0)
    # 500 * 10 ms = 5 s before the link is declared dead.
    timeout = Keyword.get(opts, :supervision_timeout, 500)

    signalling(@connection_parameter_update_request, identifier, <<
      min::16-little,
      max::16-little,
      latency::16-little,
      timeout::16-little
    >>)
  end

  @doc "A Command Reject saying the command was not understood."
  @spec command_reject(non_neg_integer()) :: binary()
  def command_reject(identifier) do
    signalling(@command_reject, identifier, <<0x0000::16-little>>)
  end

  defp signalling(code, identifier, data) do
    <<code, identifier, byte_size(data)::16-little, data::binary>>
  end

  @doc """
  Decode a signalling PDU far enough to answer it.

  The peripheral only ever receives two things here: the response to the
  parameter update it asked for, and commands it has no implementation of.
  """
  @spec decode_signalling(binary()) ::
          {:connection_parameter_update_response, non_neg_integer(), :accepted | :rejected}
          | {:unhandled, non_neg_integer(), non_neg_integer()}
          | {:error, term()}
  def decode_signalling(
        <<@connection_parameter_update_response, id, 2::16-little, result::16-little>>
      ) do
    {:connection_parameter_update_response, id, if(result == 0, do: :accepted, else: :rejected)}
  end

  def decode_signalling(<<code, id, length::16-little, data::binary>>)
      when byte_size(data) == length do
    {:unhandled, code, id}
  end

  def decode_signalling(other), do: {:error, {:malformed_signalling, other}}
end
