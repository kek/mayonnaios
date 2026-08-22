defmodule MayonnaiOS.Bluetooth.GATTTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Bluetooth.{ATT, GATT, HOGP}
  alias MayonnaiOS.Controller.Report

  # These tests walk the database the way a client does -- discover services,
  # discover characteristics, read a long value in pieces, subscribe -- because
  # that sequence is the thing that has to work and no single response proves
  # it does. A database can answer every request correctly in isolation and
  # still be undiscoverable if a group-end handle is one short.

  setup do
    %{db: HOGP.build("Xbox Wireless Controller")}
  end

  defp ask(db, pdu), do: GATT.request(db, ATT.decode(pdu))

  describe "service discovery" do
    test "a client walking Read By Group Type finds all five services", %{db: db} do
      {services, _db} = walk_services(db, 0x0001, [])

      uuids = Enum.map(services, fn {_start, _stop, uuid} -> uuid end)

      assert uuids == [0x1800, 0x1801, 0x180A, 0x180F, 0x1812]
    end

    test "each service's group end covers its characteristics and no more", %{db: db} do
      {services, _db} = walk_services(db, 0x0001, [])

      # Every attribute between a service's start and end belongs to it, and
      # the next service starts at the very next handle. A gap would leave
      # attributes no client ever asks about; an overlap would put the HID
      # report inside the battery service.
      services
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{_start, stop, uuid}, {next, _, _}] ->
        assert next == stop + 1,
               "service 0x#{Integer.to_string(uuid, 16)} does not end at #{next - 1}"
      end)

      {_start, last, _uuid} = List.last(services)
      assert last == db.attributes |> List.last() |> Map.fetch!(:handle)
    end

    test "the walk ends with Attribute Not Found rather than an empty response", %{db: db} do
      last = db.attributes |> List.last() |> Map.fetch!(:handle)

      {response, _db, _events} =
        ask(db, <<0x10, last + 1::16-little, 0xFFFF::16-little, 0x2800::16-little>>)

      assert <<0x01, 0x10, _handle::16-little, 0x0A>> = response
    end

    test "asking for a group type that is not a service says so", %{db: db} do
      {response, _db, _events} =
        ask(db, <<0x10, 0x0001::16-little, 0xFFFF::16-little, 0x2803::16-little>>)

      # 0x10, Unsupported Group Type -- not Attribute Not Found, which would
      # tell the client there were no services.
      assert <<0x01, 0x10, _handle::16-little, 0x10>> = response
    end

    test "Find By Type Value finds one service by UUID", %{db: db} do
      {response, _db, _events} =
        ask(
          db,
          <<0x06, 0x0001::16-little, 0xFFFF::16-little, 0x2800::16-little, 0x1812::16-little>>
        )

      assert <<0x07, start::16-little, stop::16-little>> = response
      assert GATT.at(db, start).value == <<0x1812::16-little>>
      assert stop > start
    end
  end

  describe "characteristic discovery" do
    test "Read By Type over the HID service finds its characteristics", %{db: db} do
      {start, stop} = service_range(db, 0x1812)

      {characteristics, _db} = walk_characteristics(db, start, stop, [])

      uuids = Enum.map(characteristics, fn {_handle, _props, _value, uuid} -> uuid end)

      # HID Information, Report Map, Control Point, Protocol Mode, then two
      # Reports: the input report and the rumble output report, told apart by
      # their Report Reference descriptors rather than by UUID.
      assert uuids == [0x2A4A, 0x2A4B, 0x2A4C, 0x2A4E, 0x2A4D, 0x2A4D]
    end

    test "the report characteristic can notify and its value handle is the next one", %{db: db} do
      {start, stop} = service_range(db, 0x1812)
      {characteristics, _db} = walk_characteristics(db, start, stop, [])

      {handle, props, value, 0x2A4D} =
        Enum.find(characteristics, fn {_h, _p, _v, uuid} -> uuid == 0x2A4D end)

      assert value == handle + 1
      # Read and Notify.
      assert Bitwise.band(props, 0x02) != 0
      assert Bitwise.band(props, 0x10) != 0

      assert HOGP.report_handles(db).value == value
    end

    test "Find Information lists the report's descriptors", %{db: db} do
      %{value: value} = HOGP.report_handles(db)

      {response, _db, _events} =
        ask(db, <<0x04, value + 1::16-little, value + 2::16-little>>)

      # Format 1, 16-bit UUIDs: the CCCD and the report reference.
      assert <<0x05, 0x01, _cccd::16-little, 0x2902::16-little, _ref::16-little,
               0x2908::16-little>> = response
    end
  end

  describe "security" do
    test "the report map is refused before the link is encrypted", %{db: db} do
      handle = GATT.find_handle(db, 0x2A4B)

      {response, _db, _events} = ask(db, <<0x0A, handle::16-little>>)

      # 0x05, Insufficient Authentication. This refusal is what makes a host
      # start pairing, so it is a feature and not an error path.
      assert <<0x01, 0x0A, ^handle::16-little, 0x05>> = response
    end

    test "and readable once it is", %{db: db} do
      # The MTU has to clear the 283-byte descriptor plus the opcode, or the
      # read comes back truncated at MTU - 1 and the rest is Read Blob's job.
      db = %{db | encrypted: true, mtu: 517}
      handle = GATT.find_handle(db, 0x2A4B)

      {response, _db, _events} = ask(db, <<0x0A, handle::16-little>>)

      assert <<0x0B, value::binary>> = response
      assert value == Report.descriptor()
    end

    test "the battery level is readable without pairing", %{db: db} do
      handle = HOGP.battery_handles(db).value

      {response, _db, _events} = ask(db, <<0x0A, handle::16-little>>)

      assert <<0x0B, 100>> = response
    end

    test "subscribing to reports is refused before encryption", %{db: db} do
      cccd = HOGP.report_handles(db).cccd

      {response, db, _events} = ask(db, <<0x12, cccd::16-little, 0x0001::16-little>>)

      assert <<0x01, 0x12, ^cccd::16-little, 0x05>> = response
      refute GATT.subscribed?(db, cccd)
    end
  end

  describe "reading a long value" do
    test "a read at the default MTU is truncated, not refused", %{db: db} do
      db = %{db | encrypted: true}
      handle = GATT.find_handle(db, 0x2A4B)

      {response, _db, _events} = ask(db, <<0x0A, handle::16-little>>)

      assert <<0x0B, value::binary>> = response
      # MTU 23: one opcode byte and twenty-two of value.
      assert byte_size(value) == 22
      assert value == binary_part(Report.descriptor(), 0, 22)
    end

    test "and Read Blob fetches the rest of it in order", %{db: db} do
      db = %{db | encrypted: true}
      handle = GATT.find_handle(db, 0x2A4B)

      assembled = read_whole(db, handle)

      assert assembled == Report.descriptor()
    end

    test "a blob read at exactly the end returns nothing, which is how a client stops",
         %{db: db} do
      db = %{db | encrypted: true}
      handle = GATT.find_handle(db, 0x2A4B)
      size = byte_size(Report.descriptor())

      {response, _db, _events} = ask(db, <<0x0C, handle::16-little, size::16-little>>)

      assert response == <<0x0D>>
    end

    test "a blob read past the end is Invalid Offset", %{db: db} do
      db = %{db | encrypted: true}
      handle = GATT.find_handle(db, 0x2A4B)
      size = byte_size(Report.descriptor())

      {response, _db, _events} = ask(db, <<0x0C, handle::16-little, size + 1::16-little>>)

      assert <<0x01, 0x0C, ^handle::16-little, 0x07>> = response
    end
  end

  describe "subscriptions" do
    test "writing the notify bit subscribes and reports it upwards", %{db: db} do
      db = %{db | encrypted: true}
      cccd = HOGP.report_handles(db).cccd

      {response, db, events} = ask(db, <<0x12, cccd::16-little, 0x0001::16-little>>)

      assert response == <<0x13>>
      assert events == [{:subscription, cccd, true, false}]
      assert GATT.subscribed?(db, cccd)
    end

    test "and the client can read back what it wrote", %{db: db} do
      db = %{db | encrypted: true}
      cccd = HOGP.report_handles(db).cccd

      {_response, db, _events} = ask(db, <<0x12, cccd::16-little, 0x0001::16-little>>)
      {response, _db, _events} = ask(db, <<0x0A, cccd::16-little>>)

      assert response == <<0x0B, 0x01, 0x00>>
    end

    test "writing zero unsubscribes", %{db: db} do
      db = %{db | encrypted: true}
      cccd = HOGP.report_handles(db).cccd

      {_response, db, _} = ask(db, <<0x12, cccd::16-little, 0x0001::16-little>>)
      {_response, db, events} = ask(db, <<0x12, cccd::16-little, 0x0000::16-little>>)

      assert events == [{:subscription, cccd, false, false}]
      refute GATT.subscribed?(db, cccd)
    end

    test "a disconnect forgets subscriptions, the MTU and the encryption", %{db: db} do
      db = %{db | encrypted: true, mtu: 247}
      cccd = HOGP.report_handles(db).cccd
      {_response, db, _} = ask(db, <<0x12, cccd::16-little, 0x0001::16-little>>)

      db = GATT.clear_subscriptions(db)

      refute GATT.subscribed?(db, cccd)
      refute db.encrypted
      assert db.mtu == 23
      # The values that are not subscriptions survive: the battery reading is
      # still true across a disconnect.
      assert GATT.value(db, :battery_level) == <<100>>
    end
  end

  describe "the awkward requests every client sends" do
    test "Exchange MTU settles on the smaller of the two", %{db: db} do
      {response, db, events} = ask(db, <<0x02, 100::16-little>>)

      assert <<0x03, server::16-little>> = response
      assert server == 247
      assert db.mtu == 100
      assert events == [{:mtu, 100}]
    end

    test "a client asking for more than the server offers gets the server's number", %{db: db} do
      {_response, db, _events} = ask(db, <<0x02, 517::16-little>>)
      assert db.mtu == 247
    end

    test "an opcode the server does not implement is Request Not Supported", %{db: db} do
      # Read Multiple Variable Length, which this server has no need of.
      {response, _db, _events} = ask(db, <<0x20, 0x0001::16-little>>)

      assert <<0x01, 0x20, 0x0000::16-little, 0x06>> = response
    end

    test "a command the server does not implement gets no answer at all", %{db: db} do
      # Signed Write Command. Answering a command is a protocol violation.
      {response, _db, events} = ask(db, <<0xD2, 0x0001::16-little, 0x00>>)

      assert response == nil
      assert events == [{:unsupported_command, 0xD2}]
    end

    test "a write to a handle that does not exist is refused", %{db: db} do
      {response, _db, _events} = ask(db, <<0x12, 0xFF00::16-little, 0x00>>)

      assert <<0x01, 0x12, 0xFF00::16-little, 0x01>> = response
    end

    test "a write to a read-only attribute is refused", %{db: db} do
      handle = GATT.find_handle(db, 0x2A00)

      {response, _db, _events} = ask(db, <<0x12, handle::16-little, "no">>)

      assert <<0x01, 0x12, ^handle::16-little, 0x03>> = response
    end

    test "a request whose range is backwards is Invalid Handle", %{db: db} do
      {response, _db, _events} =
        ask(db, <<0x10, 0x0010::16-little, 0x0001::16-little, 0x2800::16-little>>)

      assert <<0x01, 0x10, 0x0000::16-little, 0x01>> = response
    end
  end

  test "every response fits inside the MTU", %{db: db} do
    db = %{db | encrypted: true, mtu: 23}

    requests = [
      <<0x10, 0x0001::16-little, 0xFFFF::16-little, 0x2800::16-little>>,
      <<0x08, 0x0001::16-little, 0xFFFF::16-little, 0x2803::16-little>>,
      <<0x04, 0x0001::16-little, 0xFFFF::16-little>>,
      <<0x0A, GATT.find_handle(db, 0x2A4B)::16-little>>,
      <<0x0C, GATT.find_handle(db, 0x2A4B)::16-little, 0x0000::16-little>>
    ]

    for request <- requests do
      {response, _db, _events} = ask(db, request)

      assert byte_size(response) <= db.mtu,
             "#{byte_size(response)} bytes for request #{inspect(request, base: :hex)}"
    end
  end

  # -- walking the database the way a client does -----------------------------

  defp walk_services(db, from, acc) when from <= 0xFFFF do
    case ask(db, <<0x10, from::16-little, 0xFFFF::16-little, 0x2800::16-little>>) do
      {<<0x11, length, body::binary>>, db, _events} ->
        found = for <<group::binary-size(^length) <- body>>, do: group(group)
        {_start, stop, _uuid} = List.last(found)
        walk_services(db, stop + 1, acc ++ found)

      {_error, db, _events} ->
        {acc, db}
    end
  end

  defp walk_services(db, _from, acc), do: {acc, db}

  defp group(<<start::16-little, stop::16-little, uuid::16-little>>), do: {start, stop, uuid}

  defp walk_characteristics(db, from, last, acc) when from <= last do
    case ask(db, <<0x08, from::16-little, last::16-little, 0x2803::16-little>>) do
      {<<0x09, length, body::binary>>, db, _events} ->
        found = for <<entry::binary-size(^length) <- body>>, do: declaration(entry)
        {handle, _props, _value, _uuid} = List.last(found)
        walk_characteristics(db, handle + 1, last, acc ++ found)

      {_error, db, _events} ->
        {acc, db}
    end
  end

  defp walk_characteristics(db, _from, _last, acc), do: {acc, db}

  defp declaration(<<handle::16-little, props, value::16-little, uuid::16-little>>) do
    {handle, props, value, uuid}
  end

  defp service_range(db, uuid) do
    attribute = Enum.find(db.attributes, &(&1.type == 0x2800 and &1.value == <<uuid::16-little>>))
    {attribute.handle, attribute.group_end}
  end

  defp read_whole(db, handle) do
    {<<0x0B, first::binary>>, db, _} = ask(db, <<0x0A, handle::16-little>>)
    read_blobs(db, handle, byte_size(first), first)
  end

  defp read_blobs(db, handle, offset, acc) do
    case ask(db, <<0x0C, handle::16-little, offset::16-little>>) do
      {<<0x0D>>, _db, _} ->
        acc

      {<<0x0D, chunk::binary>>, db, _} ->
        read_blobs(db, handle, offset + byte_size(chunk), acc <> chunk)

      {_error, _db, _} ->
        acc
    end
  end
end
