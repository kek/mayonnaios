defmodule MayonnaiOS.Bluetooth.PeripheralTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Bluetooth.{GATT, HCI, HOGP, L2CAP, Peripheral, SMP}
  alias MayonnaiOS.Controller.Report

  # The peripheral is the one piece of this stack that cannot be checked by
  # calling a function with a binary: it is a connection's worth of state
  # spread over four protocols, and every interesting bug in it is an
  # interaction rather than a wrong byte. So this stands a fake controller
  # under it -- a process registered under the name the real one uses -- and
  # plays a whole central: connect, discover, pair, subscribe, press a button.
  #
  # The fake itself lives in `test/support/fake_controller.exs`, because
  # `MayonnaiOS.Bluetooth.ScannerTest` needs exactly the same seam and two
  # doubles that drift apart are worse than one that is slightly more general
  # than either caller.
  alias MayonnaiOS.Bluetooth.FakeController

  @handle 0x0040
  @central {0x01, <<0xA6, 0xA5, 0xA4, 0xA3, 0xA2, 0xA1>>}
  @peripheral_address <<0xB6, 0xB5, 0xB4, 0xB3, 0xB2, 0xB1>>

  setup do
    start_supervised!({FakeController, self()})
    start_supervised!({Peripheral, name: "Test Controller"})

    # Setup runs in a handle_continue, which is executed before any call the
    # test makes -- so one call is enough to know it has finished, and it does
    # not take the setup commands out of the mailbox the way waiting for a
    # particular one would.
    Peripheral.status()

    %{db: HOGP.build("Test Controller")}
  end

  describe "starting up" do
    test "resets, unmasks the events it needs, and only then advertises" do
      # The order is the assertion, so the whole sequence is drained and
      # compared as a list. `assert_received` would not do: it searches the
      # mailbox and would pass just as happily if advertising had been enabled
      # before the data was set, which is the mistake worth catching.
      assert commands() == [
               # Reset
               0x0C03,
               # Set Event Mask, then LE Set Event Mask -- before anything can
               # arrive, or a connection is one this host never hears about.
               0x0C01,
               0x2001,
               # Write LE Host Support
               0x0C6D,
               # LE Read Buffer Size, Read BD_ADDR
               0x2002,
               0x1009,
               # Advertising: parameters, data, scan response...
               0x2006,
               0x2008,
               0x2009,
               # ...and only then on the air.
               0x200A
             ]
    end

    test "says it is advertising, and nothing more" do
      status = Peripheral.status()

      assert status.advertising
      refute status.connected
      refute status.encrypted
      refute status.subscribed
      assert status.address == "B1:B2:B3:B4:B5:B6"
    end
  end

  describe "a host that connects and reads" do
    setup do
      connect()
      :ok
    end

    test "the connection is reported" do
      status = Peripheral.status()

      assert status.connected
      assert status.peer == "A1:A2:A3:A4:A5:A6"
      refute status.advertising
    end

    test "an MTU exchange is answered and remembered" do
      att(<<0x02, 100::16-little>>)

      assert <<0x03, _server::16-little>> = expect_pdu(0x0004)
      assert Peripheral.status().mtu == 100
    end

    test "service discovery works over the wire" do
      att(<<0x10, 0x0001::16-little, 0xFFFF::16-little, 0x2800::16-little>>)

      assert <<0x11, 6, first::binary-6, _rest::binary>> = expect_pdu(0x0004)
      assert <<0x0001::16-little, _stop::16-little, 0x1800::16-little>> = first
    end

    test "the report map is refused, which is what makes a host pair" do
      handle = GATT.find_handle(HOGP.build("Test Controller"), 0x2A4B)

      att(<<0x0A, handle::16-little>>)

      assert <<0x01, 0x0A, _handle::16-little, 0x05>> = expect_pdu(0x0004)
    end

    test "a report before anything is subscribed is dropped and counted" do
      Peripheral.report(<<1, 2, 3, 4, 5>>)

      refute_receive {:acl, _}, 50
      assert Peripheral.status().dropped.unencrypted == 1
    end

    test "a disconnect goes back to advertising" do
      send(
        Peripheral,
        {:hci, {:event, :disconnection_complete, %{status: 0, handle: @handle, reason: 0x13}}}
      )

      assert_receive {:command, 0x200A, <<0x01>>}, 500
      status = Peripheral.status()
      assert status.advertising
      refute status.connected
    end
  end

  describe "pairing, subscribing and pressing a button" do
    setup do
      connect()
      pair()
      :ok
    end

    test "the link ends up paired and encrypted" do
      status = Peripheral.status()

      assert status.encrypted
      assert status.paired
    end

    test "reading the report map is noticed, so a re-pair can be told from a cached one" do
      refute Peripheral.status().report_map_read

      handle = GATT.find_handle(HOGP.build("Test Controller"), 0x2A4B)
      att(<<0x0A, handle::16-little>>)
      assert <<0x0B, _first::binary>> = expect_pdu(0x0004)

      assert Peripheral.status().report_map_read
    end

    test "the report map is readable once encrypted, in blob-sized pieces" do
      db = HOGP.build("Test Controller")
      handle = GATT.find_handle(db, 0x2A4B)

      att(<<0x0A, handle::16-little>>)
      assert <<0x0B, first::binary>> = expect_pdu(0x0004)

      whole = read_blobs(handle, byte_size(first), first)

      assert whole == Report.descriptor()
    end

    test "a long read is fragmented across ACL packets and arrives whole" do
      # Raise the MTU so the response is bigger than the 27-byte ACL payload
      # the fake controller advertised. This is the case that only shows up
      # once a host negotiates a larger MTU, which every modern host does.
      att(<<0x02, 247::16-little>>)
      assert <<0x03, _::16-little>> = expect_pdu(0x0004)

      handle = GATT.find_handle(HOGP.build("Test Controller"), 0x2A4B)
      att(<<0x0A, handle::16-little>>)

      assert <<0x0B, value::binary>> = expect_pdu(0x0004)
      # A 247-byte MTU truncates the 283-byte descriptor at MTU - 1; the rest
      # is Read Blob's job and the blob test above proves it. What this test
      # is about is the 246 bytes crossing several 27-byte ACL packets whole.
      assert value == binary_part(Report.descriptor(), 0, 246)
      assert byte_size(value) > 27
    end

    test "a rejected connection parameter request is answered with one Apple allows" do
      # A Mac refuses the first request outright: it asks for a 7.5 ms floor
      # where 15 ms is the minimum allowed, and the connection then stays on
      # whatever interval the host picked, which is felt as late buttons.
      signalling(<<0x13, 1, 2::16-little, 1::16-little>>)

      assert <<0x12, _id, 8::16-little, min::16-little, max::16-little, 0::16-little,
               _timeout::16-little>> = expect_pdu(0x0005)

      # 15 ms to 30 ms: at the floor, and a ceiling a clear 15 ms above it.
      assert min == 12
      assert max == 24
      assert max >= min + 12
    end

    test "and a second rejection is left alone rather than asked again" do
      signalling(<<0x13, 1, 2::16-little, 1::16-little>>)
      assert <<0x12, _id, _::binary>> = expect_pdu(0x0005)

      signalling(<<0x13, 2, 2::16-little, 1::16-little>>)

      refute_receive {:acl, _}, 50
    end

    test "an accepted request is not followed by another" do
      signalling(<<0x13, 1, 2::16-little, 0::16-little>>)

      refute_receive {:acl, _}, 50
    end

    test "the interval the central chose is reported, in milliseconds" do
      # 24 units of 1.25 ms, from the connection complete event in connect/0.
      assert Peripheral.status().interval_ms == 30.0

      send(
        Peripheral,
        {:hci,
         {:event, :le_connection_update_complete,
          %{status: 0, handle: @handle, interval: 12, latency: 0, supervision_timeout: 500}}}
      )

      sync()
      assert Peripheral.status().interval_ms == 15.0
    end

    test "subscribing turns reports on" do
      subscribe()

      assert Peripheral.status().subscribed
    end

    test "and a report then arrives as a notification on the report handle" do
      subscribe()
      report_handle = HOGP.report_handles(HOGP.build("Test Controller")).value

      Peripheral.report(<<15, 0x01, 0x00>>)

      assert <<0x1B, handle::16-little, 15, 0x01, 0x00>> = expect_pdu(0x0004)
      assert handle == report_handle
      assert Peripheral.status().sent == 1
    end

    test "the battery is notified only once a host has asked for it" do
      Peripheral.battery(42)
      refute_receive {:acl, _}, 50

      battery = HOGP.battery_handles(HOGP.build("Test Controller"))
      att(<<0x12, battery.cccd::16-little, 0x0001::16-little>>)
      assert <<0x13>> = expect_pdu(0x0004)

      Peripheral.battery(41)
      assert <<0x1B, handle::16-little, 41>> = expect_pdu(0x0004)
      assert handle == battery.value
    end
  end

  describe "a bonded host coming back" do
    setup do
      path = Path.join(System.tmp_dir!(), "bonds-#{System.unique_integer([:positive])}.bin")
      Application.put_env(:mayonnaios, :bond_path, path)

      on_exit(fn ->
        File.rm(path)
        Application.delete_env(:mayonnaios, :bond_path)
      end)

      start_supervised!(MayonnaiOS.Bluetooth.Bonds)

      connect()
      keys = pair()

      # The host goes away.
      send(
        Peripheral,
        {:hci, {:event, :disconnection_complete, %{status: 0, handle: @handle, reason: 0x13}}}
      )

      sync()
      commands()

      %{keys: keys}
    end

    test "the bond was written down" do
      assert [bond] = MayonnaiOS.Bluetooth.Bonds.list()
      assert bond.peer == @central
      assert byte_size(bond.ltk) == 16
    end

    test "reconnecting prompts the host to encrypt rather than waiting to be refused" do
      connect()

      # A Security Request, with the bonding bit set. Only sent when there is
      # a bond to resume; a host that has never paired is left alone.
      assert expect_pdu(0x0006) == <<0x0B, 0x01>>
    end

    test "and the stored key is handed to the controller when it is asked for", %{keys: keys} do
      connect()
      assert expect_pdu(0x0006) == <<0x0B, 0x01>>

      send(
        Peripheral,
        {:hci,
         {:event, :le_long_term_key_request, %{handle: @handle, rand: keys.rand, ediv: keys.ediv}}}
      )

      expected = keys.ltk
      assert_receive {:command, 0x201A, <<@handle::16-little, ^expected::binary-16>>}, 500

      send(
        Peripheral,
        {:hci, {:event, :encryption_change, %{status: 0, handle: @handle, enabled: true}}}
      )

      sync()
      assert Peripheral.status().encrypted
    end

    test "an EDIV and Rand nothing matches gets a negative reply, not silence" do
      connect()
      assert expect_pdu(0x0006) == <<0x0B, 0x01>>

      send(
        Peripheral,
        {:hci,
         {:event, :le_long_term_key_request,
          %{handle: @handle, rand: <<9, 9, 9, 9, 9, 9, 9, 9>>, ediv: <<9, 9>>}}}
      )

      # Without this the central's encryption attempt times out and the host
      # reports a device that is broken rather than one that needs pairing
      # again.
      assert_receive {:command, 0x201B, <<@handle::16-little>>}, 500
    end
  end

  # -- driving the central ----------------------------------------------------

  defp connect do
    # The setup commands are of no interest to a test that is about what
    # happens after a connection, and leaving them in the mailbox would let
    # an assertion about a *new* command match an old one.
    commands()

    send(
      Peripheral,
      {:hci,
       {:event, :le_connection_complete,
        %{
          status: 0,
          handle: @handle,
          role: :peripheral,
          peer_address_type: elem(@central, 0),
          peer_address: HCI.address(elem(@central, 1)),
          interval: 24,
          latency: 0,
          supervision_timeout: 500,
          clock_accuracy: 0
        }}}
    )

    sync()
  end

  # A legacy Just Works pairing, with the test computing the confirm values
  # the way a real central would.
  defp pair do
    preq = <<0x01, 0x04, 0x00, 0x0D, 16, 0x03, 0x03>>
    smp(preq)
    pres = expect_pdu(0x0006)

    mrand = :binary.copy(<<0x5A>>, 16)
    {iat, ia} = @central

    mconfirm =
      SMP.c1(:binary.copy(<<0>>, 16), mrand, preq, pres, iat, ia, 0x00, @peripheral_address)

    smp(<<0x03, mconfirm::binary>>)
    assert <<0x03, _sconfirm::binary-16>> = expect_pdu(0x0006)

    smp(<<0x04, mrand::binary>>)
    assert <<0x04, _srand::binary-16>> = expect_pdu(0x0006)

    # The controller now asks for the key, quoting zeros because there is no
    # bond yet, and the peripheral answers with the short-term key.
    send(
      Peripheral,
      {:hci,
       {:event, :le_long_term_key_request, %{handle: @handle, rand: <<0::64>>, ediv: <<0, 0>>}}}
    )

    assert_receive {:command, 0x201A, <<@handle::16-little, _key::binary-16>>}, 500

    send(
      Peripheral,
      {:hci, {:event, :encryption_change, %{status: 0, handle: @handle, enabled: true}}}
    )

    sync()

    # Key distribution, then the connection parameter update request.
    assert <<0x06, ltk::binary-16>> = expect_pdu(0x0006)
    assert <<0x07, ediv::binary-2, rand::binary-8>> = expect_pdu(0x0006)
    assert <<0x12, _id, 8::16-little, 6::16-little, _::binary>> = expect_pdu(0x0005)

    %{ltk: ltk, ediv: ediv, rand: rand}
  end

  defp subscribe do
    cccd = HOGP.report_handles(HOGP.build("Test Controller")).cccd
    att(<<0x12, cccd::16-little, 0x0001::16-little>>)
    assert <<0x13>> = expect_pdu(0x0004)
  end

  defp read_blobs(handle, offset, acc) do
    att(<<0x0C, handle::16-little, offset::16-little>>)

    case expect_pdu(0x0004) do
      <<0x0D>> -> acc
      <<0x0D, chunk::binary>> -> read_blobs(handle, offset + byte_size(chunk), acc <> chunk)
    end
  end

  defp att(payload), do: incoming(L2CAP.cid_att(), payload)
  defp smp(payload), do: incoming(L2CAP.cid_smp(), payload)
  defp signalling(payload), do: incoming(L2CAP.cid_signalling(), payload)

  defp incoming(cid, payload) do
    send(Peripheral, {:hci, {:acl, @handle, :start, L2CAP.encode(cid, payload)}})
    sync()
  end

  # Collect the ACL packets of one PDU and hand back its payload.
  defp expect_pdu(expected_cid) do
    assert_receive {:acl, packets}, 500

    {pdus, _state} =
      Enum.reduce(packets, {[], L2CAP.new()}, fn packet, {acc, state} ->
        {:acl, @handle, pb, data} = HCI.decode(packet)
        {new, state} = L2CAP.receive(state, pb, data)
        {acc ++ new, state}
      end)

    assert [{cid, payload}] = pdus
    assert cid == expected_cid, "expected channel #{expected_cid}, got #{cid}"
    payload
  end

  # The peripheral handles these as casts and infos; a call flushes them.
  defp sync, do: Peripheral.status()

  # Every command the fake controller has been given, in the order it was
  # given them, draining the mailbox as it goes.
  defp commands(acc \\ []) do
    receive do
      {:command, opcode, _params} -> commands([opcode | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
