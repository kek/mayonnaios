defmodule MayonnaiOS.Bluetooth.GATT do
  @moduledoc """
  An attribute database and the server that answers questions about it.

  GATT is a convention layered on ATT: services, characteristics and
  descriptors are all just attributes with particular types, arranged so that
  a client can discover the lot by walking handles. This module builds such an
  arrangement from a declaration and answers the five requests a client uses
  to walk it, plus reads and writes.

  It is pure. A request goes in with the database, a response and a new
  database come out, and every interesting behaviour -- discovery, blob reads,
  subscriptions, refusing a read until the link is encrypted -- is exercised
  in the tests without a radio. `MayonnaiOS.Bluetooth.Peripheral` supplies the
  connection and does nothing else with the protocol.

  ## Handles are positions, and clients remember them

  Every attribute has a 16-bit handle, and handles are assigned here by
  counting from one in declaration order. That makes them stable as long as
  the declaration does not change -- which matters more than it looks, because
  a bonded client caches the database and will not re-discover it. Insert a
  characteristic in the middle of the HID service in a later firmware and
  every host that has paired will go on reading the old handles, getting the
  wrong attribute, and reporting a device that pairs and then does nothing.

  The Service Changed characteristic in `MayonnaiOS.Bluetooth.HOGP` exists for
  exactly that case, and re-pairing is the reliable answer.

  ## Refusing a read is how pairing starts

  The HID attributes are marked as requiring encryption. A client that reads
  one over an unencrypted link gets Insufficient Authentication, and that
  refusal is not a failure -- it is the signal that makes the host start
  pairing. A database that let everything be read unencrypted would be read
  happily by Windows, which would then never pair, never bond, and never
  reconnect on its own afterwards.

  ## Responses are cut to the MTU

  Every response has to fit in one ATT PDU: MTU bytes including the opcode. So
  list-shaped responses stop early and the client asks again from the next
  handle, and long values come back truncated for the client to finish with
  Read Blob. Neither is an error and both must be exact -- a response one byte
  over the MTU is dropped by the client's L2CAP layer with nothing logged
  anywhere.
  """

  alias MayonnaiOS.Bluetooth.ATT

  @primary_service 0x2800
  @secondary_service 0x2801
  @characteristic 0x2803
  @cccd 0x2902

  @properties %{
    broadcast: 0x01,
    read: 0x02,
    write_without_response: 0x04,
    write: 0x08,
    notify: 0x10,
    indicate: 0x20,
    signed_write: 0x40,
    extended: 0x80
  }

  @typedoc """
  One attribute.

  `read` and `write` are `:open`, `:encrypted` or `:denied`; a value is either
  a binary or `{:dynamic, key}`, which is looked up in the database's `values`
  map at the moment of the read.
  """
  @type attribute :: %{
          handle: non_neg_integer(),
          type: non_neg_integer() | binary(),
          value: binary() | {:dynamic, atom()},
          read: :open | :encrypted | :denied,
          write: :open | :encrypted | :denied,
          group_end: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          attributes: [attribute()],
          values: %{atom() => binary()},
          mtu: pos_integer(),
          encrypted: boolean()
        }

  defstruct attributes: [], values: %{}, mtu: 23, encrypted: false

  @doc "Characteristic property bits by name."
  @spec properties() :: %{atom() => non_neg_integer()}
  def properties, do: @properties

  @doc "The Client Characteristic Configuration descriptor UUID, 0x2902."
  def cccd_uuid, do: @cccd

  @doc """
  Build a database from a declaration.

  The declaration is a list of `{:service, uuid, characteristics}`, where each
  characteristic is `{uuid, properties, opts}` and `opts` may carry
  `:value`, `:read`, `:write` and `:descriptors`. Handles are assigned in
  order, and a characteristic's declaration attribute is filled in with the
  handle its value ended up at -- doing that by hand is the classic way to
  produce a database that discovers cleanly and reads the wrong thing.
  """
  @spec build([tuple()], %{atom() => binary()}) :: t()
  def build(declaration, values \\ %{}) do
    {attributes, _next} = Enum.map_reduce(declaration, 0x0001, &service/2)

    %__MODULE__{attributes: List.flatten(attributes), values: values}
  end

  defp service({:service, uuid, characteristics}, handle) do
    {attrs, next} = Enum.map_reduce(characteristics, handle + 1, &characteristic/2)

    declaration = %{
      handle: handle,
      type: @primary_service,
      value: uuid_value(uuid),
      read: :open,
      write: :denied,
      # Every attribute up to the one before the next service belongs to this
      # one. Read By Group Type reports that range, and a client uses it to
      # decide where to stop looking for the service's characteristics.
      group_end: next - 1
    }

    {[declaration | attrs], next}
  end

  defp characteristic({uuid, props, opts}, handle) do
    value_handle = handle + 1

    declaration = %{
      handle: handle,
      type: @characteristic,
      value: <<bits(props), value_handle::16-little, uuid_value(uuid)::binary>>,
      read: :open,
      write: :denied,
      group_end: nil
    }

    value = %{
      handle: value_handle,
      type: uuid,
      value: Keyword.get(opts, :value, <<>>),
      read: Keyword.get(opts, :read, if(:read in props, do: :open, else: :denied)),
      write: Keyword.get(opts, :write, writable_default(props)),
      group_end: nil
    }

    {descriptors, next} =
      opts
      |> Keyword.get(:descriptors, [])
      |> Enum.map_reduce(value_handle + 1, &descriptor/2)

    {[declaration, value | descriptors], next}
  end

  defp descriptor({uuid, opts}, handle) do
    {%{
       handle: handle,
       type: uuid,
       value: Keyword.get(opts, :value, <<>>),
       read: Keyword.get(opts, :read, :open),
       write: Keyword.get(opts, :write, :denied),
       group_end: nil
     }, handle + 1}
  end

  defp writable_default(props) do
    if :write in props or :write_without_response in props, do: :open, else: :denied
  end

  defp bits(props), do: Enum.reduce(props, 0, &Bitwise.bor(@properties[&1], &2))

  defp uuid_value(uuid) when is_integer(uuid), do: <<uuid::16-little>>
  defp uuid_value(uuid) when is_binary(uuid), do: uuid

  @doc "The attribute at `handle`, or nil."
  @spec at(t(), non_neg_integer()) :: attribute() | nil
  def at(db, handle), do: Enum.find(db.attributes, &(&1.handle == handle))

  @doc """
  The handle of the first attribute of `type` inside the service containing
  `uuid`, or nil.

  Used to find the report and battery-level handles once rather than writing
  them down as constants that drift when the declaration changes.
  """
  @spec find_handle(t(), non_neg_integer() | binary()) :: non_neg_integer() | nil
  def find_handle(db, type) do
    case Enum.find(db.attributes, &(&1.type == type)) do
      nil -> nil
      attribute -> attribute.handle
    end
  end

  @doc """
  The handle of the CCCD that follows `value_handle`.

  A characteristic's descriptors are the attributes between its value and the
  next declaration, so the CCCD is found by walking forward rather than by
  arithmetic on handles.
  """
  @spec cccd_handle(t(), non_neg_integer()) :: non_neg_integer() | nil
  def cccd_handle(db, value_handle) do
    db.attributes
    |> Enum.drop_while(&(&1.handle <= value_handle))
    |> Enum.take_while(&(&1.type not in [@characteristic, @primary_service, @secondary_service]))
    |> Enum.find_value(fn attribute -> if attribute.type == @cccd, do: attribute.handle end)
  end

  @doc "Set a dynamic value, the one a read of that attribute will return."
  @spec put_value(t(), atom(), binary()) :: t()
  def put_value(db, key, value), do: %{db | values: Map.put(db.values, key, value)}

  @doc "Read a dynamic value."
  @spec value(t(), atom()) :: binary()
  def value(db, key), do: Map.get(db.values, key, <<>>)

  @doc """
  Answer one request.

  Returns `{response, db, events}`. `response` is nil when the request was a
  command and needs no answer. `events` are the things above this layer may
  care about -- a subscription changing, the MTU moving, a write to a
  characteristic whose meaning is not "store these bytes".
  """
  @spec request(t(), ATT.request()) :: {binary() | nil, t(), [tuple()]}
  def request(db, request)

  def request(db, {:exchange_mtu, client_mtu}) do
    # Both sides state what they can receive and the smaller wins. Ours is the
    # controller's ACL payload budget rather than anything ATT knows about.
    mtu = min(client_mtu, server_mtu())
    {ATT.exchange_mtu_response(server_mtu()), %{db | mtu: mtu}, [{:mtu, mtu}]}
  end

  def request(db, {:find_information, first, last}) when first <= last and first > 0 do
    found =
      db.attributes
      |> Enum.filter(&(&1.handle >= first and &1.handle <= last))
      |> Enum.map(&{&1.handle, &1.type})

    case found do
      [] ->
        {ATT.error(0x04, first, :attribute_not_found), db, []}

      [{_, first_type} | _] = pairs ->
        format = if is_integer(first_type), do: 1, else: 2
        width = if format == 1, do: 4, else: 18

        pairs =
          pairs
          |> Enum.take_while(fn {_, type} -> is_integer(type) == (format == 1) end)
          |> Enum.take(div(db.mtu - 2, width))

        {ATT.find_information_response(format, pairs), db, []}
    end
  end

  def request(db, {:find_by_type_value, first, last, type, value})
      when first <= last and first > 0 do
    found =
      db.attributes
      |> Enum.filter(fn attribute ->
        attribute.handle >= first and attribute.handle <= last and
          attribute.type == type and read_value(db, attribute) == value
      end)
      |> Enum.map(&{&1.handle, &1.group_end || &1.handle})
      |> Enum.take(div(db.mtu - 1, 4))

    case found do
      [] -> {ATT.error(0x06, first, :attribute_not_found), db, []}
      pairs -> {ATT.find_by_type_value_response(pairs), db, []}
    end
  end

  def request(db, {:read_by_type, first, last, type}) when first <= last and first > 0 do
    collect(db, first, last, type, 0x08, fn attribute ->
      {attribute.handle, read_value(db, attribute)}
    end)
  end

  def request(db, {:read_by_group_type, first, last, type}) when first <= last and first > 0 do
    if type in [@primary_service, @secondary_service] do
      collect(db, first, last, type, 0x10, fn attribute ->
        {attribute.handle, attribute.group_end || attribute.handle, read_value(db, attribute)}
      end)
    else
      # Only service declarations are groups. A client asking for anything
      # else gets told so rather than an empty list, which would read as "no
      # services" and stop discovery.
      {ATT.error(0x10, first, :unsupported_group_type), db, []}
    end
  end

  def request(db, {:read, handle}) do
    with {:ok, attribute} <- fetch(db, handle),
         :ok <- readable(db, attribute) do
      {ATT.read_response(clip(read_value(db, attribute), db.mtu - 1)), db, []}
    else
      {:error, reason} -> {ATT.error(0x0A, handle, reason), db, []}
    end
  end

  def request(db, {:read_blob, handle, offset}) do
    with {:ok, attribute} <- fetch(db, handle),
         :ok <- readable(db, attribute),
         value = read_value(db, attribute),
         true <- offset <= byte_size(value) do
      rest = binary_part(value, offset, byte_size(value) - offset)
      {ATT.read_blob_response(clip(rest, db.mtu - 1)), db, []}
    else
      false -> {ATT.error(0x0C, handle, :invalid_offset), db, []}
      {:error, reason} -> {ATT.error(0x0C, handle, reason), db, []}
    end
  end

  def request(db, {:read_multiple, handles}) do
    result =
      Enum.reduce_while(handles, {:ok, <<>>}, fn handle, {:ok, acc} ->
        with {:ok, attribute} <- fetch(db, handle),
             :ok <- readable(db, attribute) do
          {:cont, {:ok, acc <> read_value(db, attribute)}}
        else
          {:error, reason} -> {:halt, {:error, handle, reason}}
        end
      end)

    case result do
      {:ok, values} -> {ATT.read_multiple_response(clip(values, db.mtu - 1)), db, []}
      {:error, handle, reason} -> {ATT.error(0x0E, handle, reason), db, []}
    end
  end

  def request(db, {:write, handle, value}) do
    case write(db, handle, value) do
      {:ok, db, events} -> {ATT.write_response(), db, events}
      {:error, reason} -> {ATT.error(0x12, handle, reason), db, []}
    end
  end

  def request(db, {:write_command, handle, value}) do
    # No response either way. A refused command is reported upwards as an
    # event so it can be logged, because otherwise it leaves no trace at all.
    case write(db, handle, value) do
      {:ok, db, events} -> {nil, db, events}
      {:error, reason} -> {nil, db, [{:write_refused, handle, reason}]}
    end
  end

  def request(db, :handle_value_confirmation), do: {nil, db, [:confirmed]}

  def request(db, {:unsupported, opcode}) do
    if ATT.command?(opcode) do
      {nil, db, [{:unsupported_command, opcode}]}
    else
      {ATT.error(opcode, 0x0000, :request_not_supported), db, []}
    end
  end

  def request(db, {:malformed, opcode, _rest}) do
    if ATT.command?(opcode) do
      {nil, db, [{:malformed_command, opcode}]}
    else
      {ATT.error(opcode, 0x0000, :invalid_pdu), db, []}
    end
  end

  # A request whose handle range is backwards or starts at zero. The
  # specification says Invalid Handle, and clients do send these -- BlueZ ends
  # discovery by asking for 0xFFFF..0xFFFF and expects to be refused.
  def request(db, request) do
    {ATT.error(ATT.opcode(request), 0x0000, :invalid_handle), db, []}
  end

  defp collect(db, first, last, type, opcode, shape) do
    candidates =
      db.attributes
      |> Enum.filter(&(&1.handle >= first and &1.handle <= last and &1.type == type))

    case candidates do
      [] ->
        {ATT.error(opcode, first, :attribute_not_found), db, []}

      [first_attribute | _] ->
        case readable(db, first_attribute) do
          :ok ->
            shaped = Enum.map(candidates, shape)
            width = shaped |> hd() |> tuple_width()

            # All entries in one response share a length, and the response has
            # to fit the MTU: the two bytes of opcode and length byte come off
            # the top.
            entries =
              shaped
              |> Enum.take_while(&(tuple_width(&1) == width))
              |> Enum.take(max(div(db.mtu - 2, width), 1))

            response =
              if opcode == 0x08 do
                ATT.read_by_type_response(entries)
              else
                ATT.read_by_group_type_response(entries)
              end

            {response, db, []}

          {:error, reason} ->
            {ATT.error(opcode, first_attribute.handle, reason), db, []}
        end
    end
  end

  defp tuple_width({_handle, value}), do: byte_size(value) + 2
  defp tuple_width({_handle, _group_end, value}), do: byte_size(value) + 4

  defp fetch(db, handle) do
    case at(db, handle) do
      nil -> {:error, :invalid_handle}
      attribute -> {:ok, attribute}
    end
  end

  defp readable(_db, %{read: :denied}), do: {:error, :read_not_permitted}
  defp readable(%{encrypted: true}, %{read: :encrypted}), do: :ok
  defp readable(_db, %{read: :encrypted}), do: {:error, :insufficient_authentication}
  defp readable(_db, _attribute), do: :ok

  # A subscription descriptor's value is whatever the client last wrote to it,
  # and two zero bytes before it has written anything. Not an empty value:
  # the descriptor is defined as sixteen bits, and a client that reads it back
  # to check its own subscription -- which Windows does -- treats a
  # zero-length answer as a malformed attribute rather than as "not
  # subscribed".
  defp read_value(db, %{type: @cccd, handle: handle}) do
    case value(db, cccd_key(handle)) do
      <<_flags::16-little>> = written -> written
      _unwritten -> <<0x00, 0x00>>
    end
  end

  defp read_value(db, %{value: {:dynamic, key}}), do: value(db, key)
  defp read_value(_db, %{value: value}), do: value

  defp write(db, handle, value) do
    with {:ok, attribute} <- fetch(db, handle),
         :ok <- writable(db, attribute) do
      apply_write(db, attribute, value)
    end
  end

  defp writable(_db, %{write: :denied}), do: {:error, :write_not_permitted}
  defp writable(%{encrypted: true}, %{write: :encrypted}), do: :ok
  defp writable(_db, %{write: :encrypted}), do: {:error, :insufficient_authentication}
  defp writable(_db, _attribute), do: :ok

  # A CCCD is the one attribute whose write has a meaning above this layer:
  # bit 0 turns notifications on. It is stored as a dynamic value so that a
  # read of it returns what the client last wrote, which clients do check.
  defp apply_write(db, %{type: @cccd, handle: handle}, <<flags::16-little>> = value) do
    key = cccd_key(handle)

    {:ok, put_value(db, key, value),
     [
       {:subscription, handle, Bitwise.band(flags, 0x01) == 0x01,
        Bitwise.band(flags, 0x02) == 0x02}
     ]}
  end

  defp apply_write(_db, %{type: @cccd}, _value), do: {:error, :invalid_attribute_value_length}

  defp apply_write(db, %{value: {:dynamic, key}}, value) do
    {:ok, put_value(db, key, value), [{:written, key, value}]}
  end

  defp apply_write(db, %{handle: handle}, value) do
    {:ok, db, [{:written_static, handle, value}]}
  end

  @doc """
  The `values` key a CCCD's state is stored under.

  Derived from the handle so that a database with several subscribable
  characteristics does not need a name for each.
  """
  @spec cccd_key(non_neg_integer()) :: atom()
  def cccd_key(handle), do: :"cccd_#{handle}"

  @doc "Whether the client has turned notifications on for this CCCD handle."
  @spec subscribed?(t(), non_neg_integer() | nil) :: boolean()
  def subscribed?(_db, nil), do: false

  def subscribed?(db, handle) do
    case value(db, cccd_key(handle)) do
      <<flags::16-little>> -> Bitwise.band(flags, 0x01) == 0x01
      _ -> false
    end
  end

  @doc """
  Forget every subscription.

  A CCCD is per-connection state for a client that is not bonded, and this
  device does not keep them across connections even for one that is: a stale
  "subscribed" would mean notifications sent into a link whose client never
  asked, which some hosts answer by disconnecting.
  """
  @spec clear_subscriptions(t()) :: t()
  def clear_subscriptions(db) do
    values =
      db.values
      |> Enum.reject(fn {key, _} -> String.starts_with?(Atom.to_string(key), "cccd_") end)
      |> Map.new()

    %{db | values: values, mtu: ATT.default_mtu(), encrypted: false}
  end

  # The largest ATT PDU this server will send or receive. Chosen to fit in a
  # single ACL fragment on a controller with the common 27-byte LE payload is
  # *not* the goal -- fragmentation handles that -- but a large MTU costs a
  # buffer per connection and buys nothing for five-byte reports. 247 is the
  # number that fits an extended data-length packet exactly, and is what most
  # peripherals ask for.
  defp server_mtu, do: 247

  defp clip(value, limit) when byte_size(value) <= limit, do: value
  defp clip(value, limit), do: binary_part(value, 0, limit)
end
