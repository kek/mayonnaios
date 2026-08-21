defmodule MayonnaiOS.Bluetooth.L2CAPTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Bluetooth.L2CAP

  # Framing is where bytes go missing without anybody noticing, so the cases
  # here are the awkward ones: a PDU exactly as long as one fragment, a PDU
  # one byte longer, a continuation with no start, a start arriving on top of
  # an unfinished PDU. Each of those has a right answer and each of them, done
  # wrong, produces a device that works until a value gets long enough.

  describe "fragments/3" do
    test "a PDU that fits is one packet with the start flag" do
      [packet] = L2CAP.fragments(0x0040, pdu(10), 27)

      # ACL packet type, handle 0x0040 with PB 0b00 and BC 0b00 in the top
      # nibble, then the length.
      assert <<0x02, 0x0040::16-little, 14::16-little, _rest::binary>> = packet
    end

    test "a PDU exactly one fragment long is still one packet" do
      [packet] = L2CAP.fragments(0x0040, pdu(23), 27)
      assert <<0x02, _header::16-little, 27::16-little, _rest::binary>> = packet
    end

    test "one byte more is two packets, and the second is a continuation" do
      [first, second] = L2CAP.fragments(0x0040, pdu(24), 27)

      assert <<0x02, 0x0040::16-little, 27::16-little, _::binary>> = first
      # PB 0b01 lives in bits 12 and 13 of the handle field: 0x1040.
      assert <<0x02, 0x1040::16-little, 1::16-little, _::binary>> = second
    end

    test "the fragments reassemble into what went in" do
      original = pdu(100)

      rebuilt =
        0x0040
        |> L2CAP.fragments(original, 27)
        |> Enum.map_join(fn <<0x02, _handle::16-little, _len::16-little, data::binary>> ->
          data
        end)

      assert rebuilt == original
    end
  end

  describe "receive/3" do
    test "a whole PDU in one fragment comes straight back out" do
      {pdus, state} = L2CAP.receive(L2CAP.new(), :start, pdu(5))

      assert [{0x0004, payload}] = pdus
      assert byte_size(payload) == 5
      assert state == L2CAP.new()
    end

    test "a split PDU yields nothing until the last fragment" do
      whole = pdu(30)
      <<first::binary-20, second::binary>> = whole

      {pdus, state} = L2CAP.receive(L2CAP.new(), :start, first)
      assert pdus == []

      {pdus, state} = L2CAP.receive(state, :continue, second)
      assert [{0x0004, payload}] = pdus
      assert byte_size(payload) == 30
      assert state == L2CAP.new()
    end

    test "three fragments work the same way" do
      whole = pdu(60)
      <<a::binary-20, b::binary-20, c::binary>> = whole

      {[], state} = L2CAP.receive(L2CAP.new(), :start, a)
      {[], state} = L2CAP.receive(state, :continue, b)
      {[{0x0004, payload}], _state} = L2CAP.receive(state, :continue, c)

      assert byte_size(payload) == 60
    end

    test "a continuation with nothing to continue is reported, not guessed at" do
      {pdus, _state} = L2CAP.receive(L2CAP.new(), :continue, <<1, 2, 3>>)

      assert [{:error, {:orphan_continuation, 3}}] = pdus
    end

    test "a start on top of an unfinished PDU drops the old one and says so" do
      <<first::binary-20, _rest::binary>> = pdu(30)
      {[], state} = L2CAP.receive(L2CAP.new(), :start, first)

      {pdus, _state} = L2CAP.receive(state, :start, pdu(5))

      assert [{:error, {:dropped_partial, 20}}, {0x0004, payload}] = pdus
      assert byte_size(payload) == 5
    end

    test "a fragment too short to hold a header is not treated as a PDU" do
      {pdus, state} = L2CAP.receive(L2CAP.new(), :start, <<0x05, 0x00>>)

      assert [{:error, {:short_header, _}}] = pdus
      assert state == L2CAP.new()
    end

    test "the channel is carried through, so SMP and ATT do not get mixed up" do
      {[{cid, _payload}], _state} =
        L2CAP.receive(L2CAP.new(), :start, <<2::16-little, 0x0006::16-little, 0x01, 0x02>>)

      assert cid == L2CAP.cid_smp()
    end
  end

  describe "signalling" do
    test "the parameter update request asks for the shortest interval LE has" do
      request = L2CAP.connection_parameter_update_request(1)

      assert <<0x12, 1, 8::16-little, min::16-little, max::16-little, latency::16-little,
               timeout::16-little>> = request

      # 6 units of 1.25 ms is 7.5 ms, the floor.
      assert min == 6
      assert max == 12
      # No skipped connection events: any one of them may carry a press.
      assert latency == 0
      # 500 units of 10 ms is five seconds.
      assert timeout == 500
    end

    test "an accepted response is recognised as such" do
      assert L2CAP.decode_signalling(<<0x13, 7, 2::16-little, 0::16-little>>) ==
               {:connection_parameter_update_response, 7, :accepted}
    end

    test "a rejection is not mistaken for an acceptance" do
      assert L2CAP.decode_signalling(<<0x13, 7, 2::16-little, 1::16-little>>) ==
               {:connection_parameter_update_response, 7, :rejected}
    end

    test "anything else comes back with its identifier, so it can be rejected by number" do
      assert L2CAP.decode_signalling(<<0x02, 9, 2::16-little, 0x00, 0x00>>) ==
               {:unhandled, 0x02, 9}
    end

    test "a command reject names no reason beyond 'not understood'" do
      assert L2CAP.command_reject(9) == <<0x01, 9, 2::16-little, 0::16-little>>
    end
  end

  # An ATT-channel PDU with `size` bytes of payload.
  defp pdu(size) do
    L2CAP.encode(0x0004, :binary.copy(<<0xAB>>, size))
  end
end
