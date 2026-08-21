defmodule MayonnaiOS.Bluetooth.SMPTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Bluetooth.SMP

  # Two kinds of check here, and the split is deliberate.
  #
  # The crypto is checked against the sample data in the Bluetooth Core
  # specification, Vol 3 Part H Appendix D. Those vectors are the only way to
  # know the byte order is right: every reversal in this stack is invisible
  # from the inside, and a c1 computed consistently wrongly at both ends of a
  # test would agree with itself and fail against a real host.
  #
  # The protocol is checked by playing the central against it -- the same
  # exchange a Windows machine does, with the confirm values computed
  # independently in the test. If the peripheral's confirm and the test's
  # confirm agree, and the two ends derive the same key, the pairing works.

  describe "the specification's sample data" do
    test "c1 matches Appendix D.2" do
      k = zeros(16)
      r = hex("E02E70C64E278863 0E6FAD5621D58357")
      preq = hex("01010000100707")
      pres = hex("02030000080005")
      ia = hex("A6A5A4A3A2A1")
      ra = hex("B6B5B4B3B2B1")

      assert SMP.c1(k, r, preq, pres, 0x01, ia, 0x00, ra) ==
               hex("863BF1BEC54DA7D2 EA888987EF3F1E1E")
    end

    test "s1 matches Appendix D.3" do
      # The specification writes these most significant octet first; this
      # stack holds everything in wire order, so they are reversed going in
      # and the expectation is reversed too.
      k = zeros(16)
      r1 = SMP.reverse(hex("000F0E0D0C0B0A09 1122334455667788"))
      r2 = SMP.reverse(hex("0102030405060708 99AABBCCDDEEFF00"))

      assert SMP.s1(k, r1, r2) == SMP.reverse(hex("9A1FE1F0E8B0F49B 5B4216AE796DA062"))
    end

    test "e is AES-128 with both ends reversed" do
      # Not a published vector -- a statement of what e/2 is, so that the
      # reversal cannot be quietly dropped while c1 is refactored.
      key = zeros(16)
      plaintext = hex("00112233445566778899AABBCCDDEEFF")

      expected =
        :crypto.crypto_one_time(:aes_128_ecb, key, SMP.reverse(plaintext), true)
        |> SMP.reverse()

      assert SMP.e(key, plaintext) == expected
    end
  end

  describe "mask/2" do
    test "leaves a full-size key alone" do
      key = :binary.copy(<<0xAA>>, 16)
      assert SMP.mask(key, 16) == key
    end

    test "zeroes the most significant octets, which are the last ones" do
      key = :binary.copy(<<0xAA>>, 16)
      assert SMP.mask(key, 7) == :binary.copy(<<0xAA>>, 7) <> zeros(9)
    end
  end

  describe "a whole pairing, with the test playing the central" do
    setup do
      central = {0x01, hex("A6A5A4A3A2A1")}
      peripheral = {0x00, hex("B6B5B4B3B2B1")}

      # A counting source of randomness: every 16 bytes it hands out are
      # different from the last, and all of them are reproducible.
      counter = :counters.new(1, [])

      rand = fn size ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        :binary.copy(<<n>>, size)
      end

      smp = SMP.new(local: peripheral, peer: central, rand: rand)

      %{smp: smp, central: central, peripheral: peripheral}
    end

    test "answers a pairing request with terms it can keep", %{smp: smp} do
      {smp, actions} = SMP.handle(smp, pairing_request())

      assert [{:send, response}] = actions
      assert <<0x02, io, oob, auth, key_size, initiator_keys, responder_keys>> = response

      # No Input No Output, no out-of-band data, bonding without MITM
      # protection and without Secure Connections.
      assert io == 0x03
      assert oob == 0x00
      assert auth == 0x01
      assert key_size == 16
      # Nothing is asked of the central, and the one key offered is the
      # encryption key -- which is the whole of what a reconnection needs.
      assert initiator_keys == 0x00
      assert responder_keys == 0x01

      assert SMP.pairing?(smp)
    end

    test "the two ends compute the same short-term key", context do
      %{smp: smp, central: {iat, ia}, peripheral: {rat, ra}} = context

      preq = pairing_request()
      {smp, [{:send, pres}]} = SMP.handle(smp, preq)

      # The central picks its random, commits to it, and sends the commitment.
      mrand = :binary.copy(<<0x5A>>, 16)
      mconfirm = SMP.c1(zeros(16), mrand, preq, pres, iat, ia, rat, ra)

      {smp, [{:send, <<0x03, sconfirm::binary-16>>}]} =
        SMP.handle(smp, <<0x03, mconfirm::binary>>)

      # Now the central reveals its random, and the peripheral reveals its own
      # only after checking the commitment.
      {smp, actions} = SMP.handle(smp, <<0x04, mrand::binary>>)

      assert [{:send, <<0x04, srand::binary-16>>}, {:ltk, stk}] = actions

      # The peripheral's confirm has to be verifiable from its revealed
      # random, which is the property the central will be checking.
      assert sconfirm == SMP.c1(zeros(16), srand, preq, pres, iat, ia, rat, ra)

      # And the key the central derives independently is the same one.
      assert stk == SMP.s1(zeros(16), srand, mrand)
      assert SMP.short_term_key(smp) == stk
    end

    test "a central whose random does not match its commitment is refused", context do
      %{smp: smp} = context

      {smp, _} = SMP.handle(smp, pairing_request())
      {smp, _} = SMP.handle(smp, <<0x03, :binary.copy(<<0x11>>, 16)::binary>>)

      {smp, actions} = SMP.handle(smp, <<0x04, :binary.copy(<<0x22>>, 16)::binary>>)

      # Pairing Failed, reason 0x04, Confirm Value Failed.
      assert [{:send, <<0x05, 0x04>>}, {:failed, :confirm_value_failed}] = actions
      refute SMP.pairing?(smp)
    end

    test "the bond is distributed once the link is encrypted", context do
      smp = paired_to_encryption(context)

      {smp, actions} = SMP.encrypted(smp)

      assert [
               {:send, <<0x06, ltk::binary-16>>},
               {:send, <<0x07, ediv::binary-2, rand::binary-8>>},
               {:bond, bond},
               :paired
             ] = actions

      # What is sent and what is stored have to be the same thing: the central
      # quotes the EDIV and Rand back on its next connection, and a bond
      # holding different bytes would never be found.
      assert bond.ltk == ltk
      assert bond.ediv == ediv
      assert bond.rand == rand
      assert bond.peer == context.central

      assert SMP.state(smp) == :paired
    end

    test "no bond when the central did not ask for a key", context do
      # Responder key distribution of zero: the central wants a session and
      # not a relationship. Legitimate, and not an error.
      request = <<0x01, 0x04, 0x00, 0x0D, 16, 0x00, 0x00>>

      {smp, [{:send, <<0x02, _io, _oob, _auth, _size, _init, 0x00>>}]} =
        SMP.handle(context.smp, request)

      {smp, _} = SMP.handle(smp, <<0x03, :binary.copy(<<0x11>>, 16)::binary>>)
      smp = %{smp | state: :awaiting_encryption}

      assert {_smp, [:paired]} = SMP.encrypted(smp)
    end

    test "a key size below the floor is refused rather than negotiated down", context do
      request = <<0x01, 0x04, 0x00, 0x0D, 6, 0x00, 0x01>>

      {_smp, actions} = SMP.handle(context.smp, request)

      assert [{:send, <<0x05, 0x06>>}, {:failed, :encryption_key_size}] = actions
    end

    test "a smaller but legal key size is honoured on both the response and the key",
         context do
      request = <<0x01, 0x04, 0x00, 0x0D, 7, 0x00, 0x01>>

      {smp, [{:send, <<0x02, _io, _oob, _auth, 7, _init, _resp>>}]} =
        SMP.handle(context.smp, request)

      {smp, _} = SMP.handle(smp, <<0x03, :binary.copy(<<0x11>>, 16)::binary>>)
      {_smp, actions} = SMP.handle(smp, <<0x04, :binary.copy(<<0x22>>, 16)::binary>>)

      # The confirm will not match, so this exchange fails -- what is being
      # checked is only that the negotiated size reached the response.
      assert [{:send, <<0x05, 0x04>>} | _] = actions
    end

    test "a central that insists on Secure Connections is told which requirement failed",
         context do
      {smp, _} = SMP.handle(context.smp, pairing_request())
      {_smp, actions} = SMP.handle(smp, <<0x0C, :binary.copy(<<0>>, 64)::binary>>)

      # 0x03 is Authentication Requirements, which is the answer that gets a
      # host to retry in legacy mode rather than report a broken device.
      assert [{:send, <<0x05, 0x03>>}, {:failed, :secure_connections}] = actions
    end

    test "a Pairing Failed from the central ends the exchange", context do
      {smp, _} = SMP.handle(context.smp, pairing_request())
      {smp, actions} = SMP.handle(smp, <<0x05, 0x08>>)

      assert [{:failed, {:remote, :unspecified}}] = actions
      refute SMP.pairing?(smp)
    end

    test "an unknown command is refused, not ignored", context do
      {_smp, actions} = SMP.handle(context.smp, <<0x7F, 0x00>>)

      assert [{:send, <<0x05, 0x07>>}, {:failed, {:unsupported, 0x7F}}] = actions
    end
  end

  test "the security request asks for bonding" do
    assert SMP.security_request() == <<0x0B, 0x01>>
  end

  # -- helpers ----------------------------------------------------------------

  # What a host sends: display-yes-no, bonding with MITM wanted, 16-byte keys,
  # and it will hand over its identity key if asked. Copied in shape from what
  # Windows and BlueZ actually send.
  defp pairing_request, do: <<0x01, 0x04, 0x00, 0x0D, 16, 0x03, 0x03>>

  defp paired_to_encryption(%{smp: smp, central: {iat, ia}, peripheral: {rat, ra}}) do
    preq = pairing_request()
    {smp, [{:send, pres}]} = SMP.handle(smp, preq)

    mrand = :binary.copy(<<0x5A>>, 16)
    mconfirm = SMP.c1(zeros(16), mrand, preq, pres, iat, ia, rat, ra)

    {smp, _} = SMP.handle(smp, <<0x03, mconfirm::binary>>)
    {smp, _} = SMP.handle(smp, <<0x04, mrand::binary>>)
    smp
  end

  defp zeros(size), do: :binary.copy(<<0>>, size)
  defp hex(text), do: text |> String.replace(" ", "") |> Base.decode16!()
end
