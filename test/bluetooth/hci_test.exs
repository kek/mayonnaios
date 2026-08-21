defmodule MayonnaiOS.Bluetooth.HCITest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Bluetooth.{Advertising, HCI}

  describe "commands" do
    test "an opcode goes out little-endian, with its parameter length" do
      assert HCI.reset() == <<0x01, 0x03, 0x0C, 0x00>>
      assert HCI.read_bd_addr() == <<0x01, 0x09, 0x10, 0x00>>
    end

    test "the event mask turns on LE Meta, which is bit 61" do
      assert <<0x01, 0x01, 0x0C, 8, mask::64-little>> = HCI.set_event_mask()
      assert Bitwise.band(mask, Bitwise.bsl(1, 61)) != 0
    end

    test "the LE event mask turns on the long-term key request, which is bit 4" do
      assert <<0x01, 0x01, 0x20, 8, mask::64-little>> = HCI.le_set_event_mask()
      assert Bitwise.band(mask, Bitwise.bsl(1, 4)) != 0
    end

    test "the LE event mask leaves the connection parameter request to the controller" do
      # Bit 5. Enabled, it becomes the host's job to answer, and this host has
      # nothing to say about it.
      assert <<0x01, 0x01, 0x20, 8, mask::64-little>> = HCI.le_set_event_mask()
      assert Bitwise.band(mask, Bitwise.bsl(1, 5)) == 0
    end

    test "advertising parameters are connectable, undirected, on all three channels" do
      assert <<0x01, 0x06, 0x20, 15, min::16-little, max::16-little, type, own, _peer_type,
               _peer::48, channels, policy>> = HCI.le_set_advertising_parameters()

      assert type == 0x00
      assert own == 0x00
      assert channels == 0x07
      assert policy == 0x00
      assert min <= max
      # The specification's floor for connectable undirected advertising.
      assert min >= 0x0020
    end

    test "advertising data is padded to a fixed 32-byte parameter" do
      data = Advertising.data()

      assert <<0x01, 0x08, 0x20, 32, length, rest::binary-31>> =
               HCI.le_set_advertising_data(data)

      assert length == byte_size(data)
      assert binary_part(rest, 0, length) == data
      # The rest is zeroes: a controller handed a short parameter refuses the
      # command outright.
      assert binary_part(rest, length, 31 - length) == :binary.copy(<<0>>, 31 - length)
    end

    test "the long-term key goes out exactly as held, with no reversal" do
      key = :binary.list_to_bin(Enum.to_list(1..16))

      assert <<0x01, 0x1A, 0x20, 18, 0x0040::16-little, sent::binary-16>> =
               HCI.le_long_term_key_request_reply(0x0040, key)

      assert sent == key
    end
  end

  describe "ACL framing" do
    test "the start flag on the way out is 0b00, not the 0b10 that comes back" do
      assert <<0x02, header::16-little, 2::16-little, 0xAA, 0xBB>> =
               HCI.acl(0x0040, :start, <<0xAA, 0xBB>>)

      assert Bitwise.bsr(header, 12) == 0b0000
      assert Bitwise.band(header, 0x0FFF) == 0x0040
    end

    test "a continuation is 0b01" do
      assert <<0x02, header::16-little, _len::16-little, _data::binary>> =
               HCI.acl(0x0040, :continue, <<0xAA>>)

      assert Bitwise.bsr(header, 12) == 0b0001
    end
  end

  describe "decoding" do
    test "a Command Complete carries its opcode and the parameters after it" do
      packet = <<0x04, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00>>

      assert {:event, :command_complete, event} = HCI.decode(packet)
      assert event.opcode == 0x0C03
      assert event.name == :reset
      assert event.params == <<0x00>>
    end

    test "a Command Status is decoded rather than left as an unmatched event" do
      packet = <<0x04, 0x0F, 0x04, 0x00, 0x01, 0x06, 0x04>>

      assert {:event, :command_status, event} = HCI.decode(packet)
      assert event.status == 0
      assert event.name == :disconnect
    end

    test "an LE Connection Complete gives the handle, the role and the peer" do
      packet =
        <<0x04, 0x3E, 19, 0x01, 0x00, 0x0040::16-little, 0x01, 0x01, 0xA6, 0xA5, 0xA4, 0xA3, 0xA2,
          0xA1, 0x0018::16-little, 0x0000::16-little, 0x01F4::16-little, 0x00>>

      assert {:event, :le_connection_complete, event} = HCI.decode(packet)
      assert event.handle == 0x0040
      # This device is the peripheral; a central that reported otherwise would
      # mean the controller was scanning, not advertising.
      assert event.role == :peripheral
      assert event.peer_address == "A1:A2:A3:A4:A5:A6"
      assert event.interval == 24
    end

    test "the enhanced form of the same event decodes to the same shape" do
      packet =
        <<0x04, 0x3E, 31, 0x0A, 0x00, 0x0040::16-little, 0x01, 0x01, 0xA6, 0xA5, 0xA4, 0xA3, 0xA2,
          0xA1, 0::48, 0::48, 0x0018::16-little, 0x0000::16-little, 0x01F4::16-little, 0x00>>

      assert {:event, :le_connection_complete, event} = HCI.decode(packet)
      assert event.handle == 0x0040
      assert event.peer_address == "A1:A2:A3:A4:A5:A6"
    end

    test "a long-term key request keeps EDIV and Rand as the bytes that arrived" do
      rand = <<1, 2, 3, 4, 5, 6, 7, 8>>
      ediv = <<0xAA, 0xBB>>
      packet = <<0x04, 0x3E, 13, 0x05, 0x0040::16-little, rand::binary, ediv::binary>>

      assert {:event, :le_long_term_key_request, event} = HCI.decode(packet)
      assert event.rand == rand
      assert event.ediv == ediv
    end

    test "Number Of Completed Packets is read as handle and count pairs" do
      packet = <<0x04, 0x13, 5, 0x01, 0x0040::16-little, 0x0003::16-little>>

      assert {:event, :number_of_completed_packets, %{handles: [{0x0040, 3}]}} =
               HCI.decode(packet)
    end

    test "ACL data comes back with its handle and boundary flag" do
      assert {:acl, 0x0040, :start, <<0xAA, 0xBB>>} =
               HCI.decode(<<0x02, 0x2040::16-little, 2::16-little, 0xAA, 0xBB>>)

      assert {:acl, 0x0040, :continue, <<0xAA>>} =
               HCI.decode(<<0x02, 0x1040::16-little, 1::16-little, 0xAA>>)
    end

    test "an event nobody handles is passed through rather than dropped" do
      assert {:event, 0x77, %{params: <<0x01>>}} = HCI.decode(<<0x04, 0x77, 1, 0x01>>)
    end

    test "a truncated packet is not silently reinterpreted" do
      assert {:unknown, _} = HCI.decode(<<0x04, 0x0E, 0x04, 0x01>>)
    end
  end

  describe "addresses" do
    test "the wire order is the reverse of the printed order" do
      assert HCI.address(<<0xA6, 0xA5, 0xA4, 0xA3, 0xA2, 0xA1>>) == "A1:A2:A3:A4:A5:A6"
    end

    test "and the round trip gets back to where it started" do
      wire = <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>
      assert HCI.address_bytes(HCI.address(wire)) == wire
    end

    test "a byte below 0x10 keeps its leading zero" do
      assert HCI.address(<<0x0F, 0x00, 0x00, 0x00, 0x00, 0x01>>) == "01:00:00:00:00:0F"
    end
  end

  describe "status/1" do
    test "zero is success and the rest is the parameters" do
      assert HCI.status(<<0x00, 0xAA>>) == {:ok, <<0xAA>>}
    end

    test "anything else is the controller refusing" do
      assert HCI.status(<<0x12>>) == {:error, {:hci_status, 0x12}}
    end
  end
end
