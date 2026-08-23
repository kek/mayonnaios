defmodule MayonnaiOS.Bluetooth.ATT do
  @moduledoc """
  The Attribute Protocol: the requests a host sends and the answers to them.

  ATT is a request/response protocol with one outstanding request at a time,
  running over L2CAP channel 0x0004. Everything a GATT client does -- reading
  a characteristic, discovering services, subscribing to notifications --
  arrives here as one of a dozen opcodes.

  This module is the wire format only. What the attributes *are* and what may
  be read is `MayonnaiOS.Bluetooth.GATT`; keeping the two apart means the
  database can be exercised without constructing packets and the packets can
  be checked without a database.

  ## Every request gets exactly one reply

  A client will not send its next request until this one is answered, so a
  request dropped on the floor does not produce an error -- it produces a
  client that waits thirty seconds and then disconnects. That is the failure
  this module is shaped to avoid: `decode/1` returns `{:unsupported, opcode}`
  rather than raising for anything it does not know, so the caller always has
  something to answer with, and `error/3` exists so that answering with a
  refusal is as easy as answering properly.

  The two exceptions are the ones the specification makes: a Write Command
  (0x52) and a Handle Value Notification (0x1B) have no reply, and their
  opcodes have the low bit of the top nibble set to say so. Answering a
  command with an error response is a protocol violation; `command?/1` is how
  the caller tells.

  ## MTU, and why the default is so small

  The ATT MTU starts at 23 bytes on LE -- 20 bytes of payload once the
  notification header is subtracted -- and stays there unless the client asks
  for more. That is enough for a sixteen-byte report and not enough for a
  283-byte report descriptor, which is why Read Blob exists and why the
  server has to implement it: a client reading the Report Map at the default
  MTU gets the first 22 bytes and then asks for the rest by offset.
  """

  # Requests and responses, by opcode.
  @error_response 0x01
  @exchange_mtu_request 0x02
  @exchange_mtu_response 0x03
  @find_information_request 0x04
  @find_information_response 0x05
  @find_by_type_value_request 0x06
  @find_by_type_value_response 0x07
  @read_by_type_request 0x08
  @read_by_type_response 0x09
  @read_request 0x0A
  @read_response 0x0B
  @read_blob_request 0x0C
  @read_blob_response 0x0D
  @read_multiple_request 0x0E
  @read_multiple_response 0x0F
  @read_by_group_type_request 0x10
  @read_by_group_type_response 0x11
  @write_request 0x12
  @write_response 0x13
  @write_command 0x52
  @handle_value_notification 0x1B
  @handle_value_indication 0x1D
  @handle_value_confirmation 0x1E

  # Error codes, the ones this server can produce.
  @errors %{
    invalid_handle: 0x01,
    read_not_permitted: 0x02,
    write_not_permitted: 0x03,
    invalid_pdu: 0x04,
    insufficient_authentication: 0x05,
    request_not_supported: 0x06,
    invalid_offset: 0x07,
    attribute_not_found: 0x0A,
    attribute_not_long: 0x0B,
    invalid_attribute_value_length: 0x0D,
    unlikely_error: 0x0E,
    insufficient_encryption: 0x0F,
    unsupported_group_type: 0x10,
    insufficient_resources: 0x11
  }

  @default_mtu 23

  @doc "The ATT MTU every LE connection starts at, before anyone asks for more."
  @spec default_mtu() :: pos_integer()
  def default_mtu, do: @default_mtu

  @doc "Error code numbers by name."
  @spec errors() :: %{atom() => non_neg_integer()}
  def errors, do: @errors

  @typedoc "A decoded request."
  @type request ::
          {:exchange_mtu, pos_integer()}
          | {:find_information, non_neg_integer(), non_neg_integer()}
          | {:find_by_type_value, non_neg_integer(), non_neg_integer(), non_neg_integer(),
             binary()}
          | {:read_by_type, non_neg_integer(), non_neg_integer(), non_neg_integer() | binary()}
          | {:read_by_group_type, non_neg_integer(), non_neg_integer(),
             non_neg_integer() | binary()}
          | {:read, non_neg_integer()}
          | {:read_blob, non_neg_integer(), non_neg_integer()}
          | {:read_multiple, [non_neg_integer()]}
          | {:write, non_neg_integer(), binary()}
          | {:write_command, non_neg_integer(), binary()}
          | :handle_value_confirmation
          | {:unsupported, non_neg_integer()}
          | {:malformed, non_neg_integer(), binary()}

  @doc """
  Decode a request PDU.

  A UUID comes back as an integer when it is one of the 16-bit ones and as the
  raw 16 bytes when it is a full 128-bit UUID, because those are genuinely
  different things and folding them together would mean comparing a
  short-form UUID against a long-form one and finding no match, for a
  characteristic that is right there.
  """
  @spec decode(binary()) :: request()
  def decode(<<@exchange_mtu_request, mtu::16-little>>), do: {:exchange_mtu, mtu}

  def decode(<<@find_information_request, first::16-little, last::16-little>>),
    do: {:find_information, first, last}

  def decode(
        <<@find_by_type_value_request, first::16-little, last::16-little, type::16-little,
          value::binary>>
      ),
      do: {:find_by_type_value, first, last, type, value}

  def decode(<<@read_by_type_request, first::16-little, last::16-little, type::binary>>) do
    {:read_by_type, first, last, uuid(type)}
  end

  def decode(<<@read_by_group_type_request, first::16-little, last::16-little, type::binary>>) do
    {:read_by_group_type, first, last, uuid(type)}
  end

  def decode(<<@read_request, handle::16-little>>), do: {:read, handle}

  def decode(<<@read_blob_request, handle::16-little, offset::16-little>>),
    do: {:read_blob, handle, offset}

  def decode(<<@read_multiple_request, handles::binary>>) when byte_size(handles) >= 4 do
    {:read_multiple, for(<<handle::16-little <- handles>>, do: handle)}
  end

  def decode(<<@write_request, handle::16-little, value::binary>>), do: {:write, handle, value}

  def decode(<<@write_command, handle::16-little, value::binary>>),
    do: {:write_command, handle, value}

  def decode(<<@handle_value_confirmation>>), do: :handle_value_confirmation

  def decode(<<opcode, rest::binary>>) do
    # Two different failures, and the client needs different answers. An
    # opcode this server does not implement is Request Not Supported; a known
    # opcode with the wrong number of bytes after it is an Invalid PDU.
    if known?(opcode), do: {:malformed, opcode, rest}, else: {:unsupported, opcode}
  end

  def decode(<<>>), do: {:malformed, 0, <<>>}

  defp known?(opcode) do
    opcode in [
      @exchange_mtu_request,
      @find_information_request,
      @find_by_type_value_request,
      @read_by_type_request,
      @read_request,
      @read_blob_request,
      @read_multiple_request,
      @read_by_group_type_request,
      @write_request,
      @write_command
    ]
  end

  defp uuid(<<value::16-little>>), do: value
  defp uuid(<<value::binary-16>>), do: value
  defp uuid(other), do: other

  @doc """
  Whether an opcode is a command -- something that must not be answered.

  Bit 6 of the opcode is the command flag. Write Command is 0x52 and Write
  Request is 0x12, one bit apart, and answering the wrong one of those with an
  Error Response is a protocol violation that some clients treat as fatal.
  """
  @spec command?(non_neg_integer()) :: boolean()
  def command?(opcode), do: Bitwise.band(opcode, 0x40) != 0

  @doc "The opcode a decoded request came from, for building its error."
  @spec opcode(request()) :: non_neg_integer()
  def opcode({:exchange_mtu, _}), do: @exchange_mtu_request
  def opcode({:find_information, _, _}), do: @find_information_request
  def opcode({:find_by_type_value, _, _, _, _}), do: @find_by_type_value_request
  def opcode({:read_by_type, _, _, _}), do: @read_by_type_request
  def opcode({:read_by_group_type, _, _, _}), do: @read_by_group_type_request
  def opcode({:read, _}), do: @read_request
  def opcode({:read_blob, _, _}), do: @read_blob_request
  def opcode({:read_multiple, _}), do: @read_multiple_request
  def opcode({:write, _, _}), do: @write_request
  def opcode({:write_command, _, _}), do: @write_command
  def opcode({:unsupported, opcode}), do: opcode
  def opcode({:malformed, opcode, _}), do: opcode
  def opcode(:handle_value_confirmation), do: @handle_value_confirmation

  # -- responses --------------------------------------------------------------

  @doc """
  An Error Response.

  The handle is echoed back so the client knows which request failed; when
  there is no meaningful handle -- an unsupported opcode, say -- zero is the
  conventional filler and what every other stack sends.
  """
  @spec error(non_neg_integer(), non_neg_integer(), atom() | non_neg_integer()) :: binary()
  def error(opcode, handle, reason) do
    code = Map.get(@errors, reason, reason)
    <<@error_response, opcode, handle::16-little, code>>
  end

  @doc "Exchange MTU Response, carrying the MTU this server can receive."
  @spec exchange_mtu_response(pos_integer()) :: binary()
  def exchange_mtu_response(mtu), do: <<@exchange_mtu_response, mtu::16-little>>

  @doc """
  Find Information Response: handle/UUID pairs, all of the same UUID width.

  Format 0x01 is 16-bit UUIDs and 0x02 is 128-bit. One response cannot mix
  the two, which is why the caller passes an already-filtered list.
  """
  @spec find_information_response(1 | 2, [{non_neg_integer(), non_neg_integer() | binary()}]) ::
          binary()
  def find_information_response(format, pairs) do
    body =
      Enum.map(pairs, fn
        {handle, uuid} when is_integer(uuid) -> <<handle::16-little, uuid::16-little>>
        {handle, uuid} when is_binary(uuid) -> <<handle::16-little, uuid::binary>>
      end)

    IO.iodata_to_binary([<<@find_information_response, format>> | body])
  end

  @doc "Find By Type Value Response: found handle and group-end handle pairs."
  @spec find_by_type_value_response([{non_neg_integer(), non_neg_integer()}]) :: binary()
  def find_by_type_value_response(pairs) do
    body =
      Enum.map(pairs, fn {handle, group_end} -> <<handle::16-little, group_end::16-little>> end)

    IO.iodata_to_binary([<<@find_by_type_value_response>> | body])
  end

  @doc """
  Read By Type Response: a length byte and then fixed-width handle/value pairs.

  Every pair in one response must be the same length -- that is what the
  length byte means -- so a caller collecting attributes stops at the first
  one whose value is a different size.
  """
  @spec read_by_type_response([{non_neg_integer(), binary()}]) :: binary()
  def read_by_type_response([{_handle, value} | _] = pairs) do
    length = byte_size(value) + 2
    body = Enum.map(pairs, fn {handle, v} -> <<handle::16-little, v::binary>> end)
    IO.iodata_to_binary([<<@read_by_type_response, length>> | body])
  end

  @doc """
  Read By Group Type Response: handle, group-end handle, value.
  """
  @spec read_by_group_type_response([{non_neg_integer(), non_neg_integer(), binary()}]) ::
          binary()
  def read_by_group_type_response([{_handle, _group_end, value} | _] = groups) do
    length = byte_size(value) + 4

    body =
      Enum.map(groups, fn {handle, group_end, v} ->
        <<handle::16-little, group_end::16-little, v::binary>>
      end)

    IO.iodata_to_binary([<<@read_by_group_type_response, length>> | body])
  end

  @doc "Read Response."
  @spec read_response(binary()) :: binary()
  def read_response(value), do: <<@read_response, value::binary>>

  @doc "Read Blob Response."
  @spec read_blob_response(binary()) :: binary()
  def read_blob_response(value), do: <<@read_blob_response, value::binary>>

  @doc "Read Multiple Response: values run together with no separators."
  @spec read_multiple_response(binary()) :: binary()
  def read_multiple_response(values), do: <<@read_multiple_response, values::binary>>

  @doc "Write Response, which carries nothing but the fact of itself."
  @spec write_response() :: binary()
  def write_response, do: <<@write_response>>

  @doc "Handle Value Notification: an unsolicited value, with no acknowledgement."
  @spec notification(non_neg_integer(), binary()) :: binary()
  def notification(handle, value),
    do: <<@handle_value_notification, handle::16-little, value::binary>>

  @doc "Handle Value Indication, which the client must confirm."
  @spec indication(non_neg_integer(), binary()) :: binary()
  def indication(handle, value),
    do: <<@handle_value_indication, handle::16-little, value::binary>>
end
