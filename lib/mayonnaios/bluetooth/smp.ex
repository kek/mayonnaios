defmodule MayonnaiOS.Bluetooth.SMP do
  @moduledoc """
  Pairing, in the peripheral role: LE legacy Just Works, and the bond it
  leaves behind.

  A HID device over LE cannot skip this. The report map and the reports
  themselves are refused until the link is encrypted (see
  `MayonnaiOS.Bluetooth.HOGP`), the link cannot be encrypted without a key,
  and there is no key until the two ends have paired. Windows will not add a
  BLE input device at all without it, and BlueZ will connect, read nothing and
  give up.

  Everything here is a fold over PDUs plus four calls into `:crypto`. Give
  `new/1` a fixed source of randomness and the whole exchange is
  deterministic, which is how the tests run both sides of a pairing on a
  laptop and check the numbers against the worked example in the
  specification.

  ## Just Works, and what that does and does not buy

  This device has a screen and a D-pad, so it *could* do passkey entry and get
  protection against a man in the middle. It declares No Input No Output and
  does Just Works instead, deliberately:

  * The screen belongs to whatever is on it. Pairing happens while the user is
    looking at a Windows dialog on another machine, and a six-digit number on
    the handheld's panel would be readable only if the handheld is also in
    front of them and showing the controller app.
  * The attack Just Works fails to stop is an active man in the middle
    present at the moment of pairing, on a link that carries button presses.
  * Every commercial BLE gamepad does the same thing, so hosts' pairing flows
    are well tested against it -- no dialog, no code, the device just appears.

  It is written down here rather than left implicit because "no MITM
  protection" is a real property of this device, and the reason it is
  acceptable is about what the link carries.

  ## Byte order: everything is in wire order

  The specification writes its crypto functions most-significant-octet-first,
  and SMP puts every one of those values on the wire least-significant-octet
  first. Reversing at each boundary means reversing in a dozen places and
  being wrong in one of them, and the symptom -- an encrypted link that both
  ends believe in and neither can decrypt -- is invisible from either side.

  So one convention, everywhere in this stack: **values are held exactly as
  they appear on the wire.** `e/2` reverses its two inputs and its output,
  which is the only place in this project a 16-byte value is reversed, and it
  matches how BlueZ's `smp_e()` does the same job. `c1/8` and `s1/3` are then
  written against wire order too, which is why they do not look like the
  specification's formulas -- the concatenations are in the other order.

  ## What is not implemented, and how it fails if it is needed

  LE Secure Connections. A central that sets the SC bit is answered with a
  Pairing Response that has it clear, and every host tested falls back to
  legacy pairing. A host in Secure Connections Only mode -- not a default
  anywhere, but a Windows group policy can set it -- will instead answer with
  Pairing Failed 0x03, Authentication Requirements. That is the one failure
  worth recognising on sight: it means the host wants P-256, and adding it is
  `:crypto`'s `:ecdh` on `:secp256r1` plus the f4/f5/f6 functions, not a
  rethink of anything here.

  Nor is identity address resolution. This device does not ask the central for
  its IRK, so a bond is looked up by the EDIV and Rand the central quotes when
  it reconnects, not by who it claims to be. That works with a central using a
  resolvable private address, which is what Windows does, and it is why
  `MayonnaiOS.Bluetooth.Bonds` is keyed the way it is.
  """

  require Logger

  # SMP command codes.
  @pairing_request 0x01
  @pairing_response 0x02
  @pairing_confirm 0x03
  @pairing_random 0x04
  @pairing_failed 0x05
  @encryption_information 0x06
  @central_identification 0x07
  @identity_information 0x08
  @identity_address_information 0x09
  @signing_information 0x0A
  @security_request 0x0B
  @pairing_public_key 0x0C

  # Failure reasons.
  @reasons %{
    passkey_entry_failed: 0x01,
    oob_not_available: 0x02,
    authentication_requirements: 0x03,
    confirm_value_failed: 0x04,
    pairing_not_supported: 0x05,
    encryption_key_size: 0x06,
    command_not_supported: 0x07,
    unspecified: 0x08,
    repeated_attempts: 0x09,
    invalid_parameters: 0x0A
  }

  # No Input No Output: see the moduledoc.
  @io_capability 0x03
  @no_oob 0x00
  # Bonding, no MITM, no Secure Connections, no keypress notifications.
  @auth_req 0x01
  @max_key_size 16
  @min_key_size 7

  # Key distribution bits. EncKey is the long-term key and the EDIV/Rand that
  # name it; those three are the whole of what makes a reconnection work.
  @enc_key 0x01

  # Just Works means the temporary key is zero. Not a placeholder.
  @tk <<0::128>>

  @typedoc "One connection's pairing state."
  @type t :: %__MODULE__{}

  defstruct state: :idle,
            # The Pairing Request and Response PDUs, kept whole because the
            # confirm value is computed over their bytes.
            preq: nil,
            pres: nil,
            key_size: @max_key_size,
            distribute: 0,
            srand: nil,
            mconfirm: nil,
            stk: nil,
            local: nil,
            peer: nil,
            rand: nil

  @doc """
  A pairing state for one connection.

  `:local` and `:peer` are `{address_type, address_bytes}` with the address in
  wire order, because that is what goes into the confirm value; getting either
  backwards produces a confirm mismatch and a host that says "pairing was
  unsuccessful" with nothing more.

  `:rand` is the source of randomness, there so the tests can be
  deterministic. It defaults to `:crypto.strong_rand_bytes/1`, and there is no
  code path where it should be anything else on a device.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      local: Keyword.fetch!(opts, :local),
      peer: Keyword.fetch!(opts, :peer),
      rand: Keyword.get(opts, :rand, &:crypto.strong_rand_bytes/1)
    }
  end

  @doc """
  A Security Request, asking the central to start encryption.

  Sent once after connecting. For a central that has a bond this is what makes
  it encrypt straight away rather than waiting to be refused a read; for one
  that does not, it is an invitation to pair that most hosts ignore until the
  user asks for it. Either way it is one PDU and it removes a round trip from
  the common case.
  """
  @spec security_request() :: binary()
  def security_request, do: <<@security_request, @auth_req>>

  @doc """
  Handle one SMP PDU.

  Returns `{state, actions}`, where actions are, in order:

      {:send, pdu}          put this on the SMP channel
      {:ltk, key}           the link is about to be encrypted with this
      {:bond, bond}         pairing finished; this is worth keeping
      {:failed, reason}     pairing is over and did not work
      {:paired}             the exchange completed

  Nothing here does I/O, and nothing here decides what a bond is worth --
  `MayonnaiOS.Bluetooth.Peripheral` sends what it is told to send and
  `MayonnaiOS.Bluetooth.Bonds` decides where a bond goes.
  """
  @spec handle(t(), binary()) :: {t(), [tuple()]}
  def handle(smp, pdu)

  def handle(
        smp,
        <<@pairing_request, io, oob, auth, key_size, initiator_keys, responder_keys>> = preq
      ) do
    cond do
      key_size < @min_key_size ->
        {reset(smp), [{:send, failed(:encryption_key_size)}, {:failed, :encryption_key_size}]}

      # The central may ask for keys this device does not have. That is not a
      # failure: the response says which of them it will actually get, and the
      # intersection is what both ends then expect.
      true ->
        negotiated = min(key_size, @max_key_size)
        distribute = Bitwise.band(responder_keys, @enc_key)

        pres =
          <<@pairing_response, @io_capability, @no_oob, @auth_req, negotiated, 0x00, distribute>>

        smp = %{
          smp
          | state: :awaiting_confirm,
            preq: preq,
            pres: pres,
            key_size: negotiated,
            distribute: distribute
        }

        log_features(io, oob, auth, initiator_keys)

        {smp, [{:send, pres}]}
    end
  end

  def handle(%{state: :awaiting_confirm} = smp, <<@pairing_confirm, mconfirm::binary-16>>) do
    srand = smp.rand.(16)
    sconfirm = confirm(smp, srand)

    {%{smp | state: :awaiting_random, srand: srand, mconfirm: mconfirm},
     [{:send, <<@pairing_confirm, sconfirm::binary>>}]}
  end

  def handle(%{state: :awaiting_random} = smp, <<@pairing_random, mrand::binary-16>>) do
    if confirm(smp, mrand) == smp.mconfirm do
      # The order is s1(TK, Srand, Mrand) and it is not symmetric: swapping
      # the two produces a key the central will not have, and the only sign of
      # it is the link failing to encrypt.
      stk = @tk |> s1(smp.srand, mrand) |> mask(smp.key_size)

      {%{smp | state: :awaiting_encryption, stk: stk},
       [{:send, <<@pairing_random, smp.srand::binary>>}, {:ltk, stk}]}
    else
      # The central's random does not produce the confirm value it committed
      # to. Either something is between the two of them, or -- far more
      # likely, and worth saying in the log -- an address or a PDU went into
      # the confirm the wrong way round at this end.
      {reset(smp), [{:send, failed(:confirm_value_failed)}, {:failed, :confirm_value_failed}]}
    end
  end

  def handle(smp, <<@pairing_public_key, _rest::binary>>) do
    # A central that ignored the cleared Secure Connections bit. Refusing with
    # the reason that names the actual disagreement is what gets a host to
    # retry in legacy mode rather than reporting a broken device.
    {reset(smp), [{:send, failed(:authentication_requirements)}, {:failed, :secure_connections}]}
  end

  def handle(smp, <<@pairing_failed, reason>>) do
    {reset(smp), [{:failed, {:remote, reason_name(reason)}}]}
  end

  # Keys the central distributes. Nothing here asks for any, so these arrive
  # only from a central that ignored the response; they are accepted and
  # dropped rather than treated as an error, because refusing them mid-exchange
  # aborts a pairing that is otherwise finished.
  def handle(smp, <<code, _rest::binary>>)
      when code in [
             @encryption_information,
             @central_identification,
             @identity_information,
             @identity_address_information,
             @signing_information
           ] do
    {smp, []}
  end

  def handle(smp, <<code, _rest::binary>>) do
    {smp, [{:send, failed(:command_not_supported)}, {:failed, {:unsupported, code}}]}
  end

  def handle(smp, <<>>), do: {smp, []}

  @doc """
  The link is now encrypted with the short-term key: distribute the long-term
  one.

  This is the step that turns a pairing into a bond. The long-term key, and
  the EDIV and Rand that name it, are generated here and sent over the
  now-encrypted link; the central stores them and quotes the EDIV and Rand
  back the next time it connects.

  If the central did not ask for the key -- `distribute` is zero -- nothing is
  sent and there is no bond. That is a legitimate outcome (the session works,
  the next one needs pairing again) and not an error.
  """
  @spec encrypted(t()) :: {t(), [tuple()]}
  def encrypted(%{state: :awaiting_encryption, distribute: 0} = smp) do
    {%{smp | state: :paired}, [:paired]}
  end

  def encrypted(%{state: :awaiting_encryption} = smp) do
    ltk = smp.rand.(16) |> mask(smp.key_size)
    ediv = smp.rand.(2)
    rand = smp.rand.(8)

    bond = %{ltk: ltk, ediv: ediv, rand: rand, peer: smp.peer, key_size: smp.key_size}

    {%{smp | state: :paired},
     [
       {:send, <<@encryption_information, ltk::binary>>},
       {:send, <<@central_identification, ediv::binary, rand::binary>>},
       {:bond, bond},
       :paired
     ]}
  end

  # Encryption came up without a pairing in progress: this is a bonded central
  # reconnecting, and the key came from the store rather than from here.
  def encrypted(smp), do: {smp, [:paired]}

  @doc "Whether a pairing is part-way through."
  @spec pairing?(t()) :: boolean()
  def pairing?(%{state: state}), do: state not in [:idle, :paired]

  @doc "Where in the exchange this connection is."
  @spec state(t()) :: atom()
  def state(%{state: state}), do: state

  @doc """
  The short-term key, once there is one.

  Read by the peripheral when the controller asks for a key mid-pairing. It
  is not the key the central will quote next time -- that is the long-term
  one, distributed after this one has done its single job of encrypting the
  link the long-term key travels over.
  """
  @spec short_term_key(t()) :: binary() | nil
  def short_term_key(%{stk: stk}), do: stk

  @doc "Forget an in-progress pairing, leaving any completed bond alone."
  @spec reset(t()) :: t()
  def reset(smp) do
    %{smp | state: :idle, preq: nil, pres: nil, srand: nil, mconfirm: nil, stk: nil}
  end

  @doc "A Pairing Failed PDU."
  @spec failed(atom()) :: binary()
  def failed(reason), do: <<@pairing_failed, Map.get(@reasons, reason, 0x08)>>

  @doc "The name for a failure code, for a log line that says something."
  @spec reason_name(non_neg_integer()) :: atom() | non_neg_integer()
  def reason_name(code) do
    Enum.find_value(@reasons, code, fn {name, value} -> if value == code, do: name end)
  end

  defp log_features(io, oob, auth, initiator_keys) do
    Logger.debug(
      "[smp] central io=0x#{hex(io)} oob=0x#{hex(oob)} auth=0x#{hex(auth)} " <>
        "keys=0x#{hex(initiator_keys)}" <>
        if(Bitwise.band(auth, 0x08) != 0, do: " (wanted secure connections)", else: "")
    )
  end

  defp hex(value), do: value |> Integer.to_string(16) |> String.pad_leading(2, "0")

  # -- the crypto -------------------------------------------------------------

  @doc """
  The security function `e`: AES-128 in ECB mode, one block.

  The reversals are the whole point. AES takes its key and plaintext most
  significant octet first; every value in this module is held least
  significant octet first because that is how it arrived. Reversing here, once
  and in one place, is what lets the rest of the module hold one convention.
  """
  @spec e(binary(), binary()) :: binary()
  def e(key, plaintext) when byte_size(key) == 16 and byte_size(plaintext) == 16 do
    :crypto.crypto_one_time(:aes_128_ecb, reverse(key), reverse(plaintext), true)
    |> reverse()
  end

  @doc """
  The confirm value for a random, over this pairing's parameters.

  `c1` binds the confirm to both pairing PDUs and both addresses, so a central
  cannot be talked into completing a pairing whose terms were altered in
  flight. Which is also why every one of those inputs has to be byte-for-byte
  what went on the wire: the function has no way to tell a tampered input from
  a wrongly assembled one, and reports both as a mismatch.
  """
  @spec confirm(t(), binary()) :: binary()
  def confirm(smp, random) do
    {peer_type, peer_address} = smp.peer
    {local_type, local_address} = smp.local

    c1(
      @tk,
      random,
      smp.preq,
      smp.pres,
      peer_type,
      peer_address,
      local_type,
      local_address
    )
  end

  @doc """
  `c1`, in wire order.

  Reading against the specification: `p1 = pres || preq || rat' || iat'` and
  `p2 = padding || ia || ra` are written most significant first, and the
  buffers below are those two values reversed, which puts `iat` first and the
  padding last. Same bytes, opposite end.

  `ia` is the initiator's address -- the central's -- and `ra` the
  responder's, which is this device. In the peripheral role those are the peer
  and the local address respectively, and swapping them is the single most
  likely mistake in this file.
  """
  @spec c1(binary(), binary(), binary(), binary(), 0..1, binary(), 0..1, binary()) :: binary()
  def c1(k, r, preq, pres, iat, ia, rat, ra) do
    p1 = <<iat, rat, preq::binary-7, pres::binary-7>>
    p2 = <<ra::binary-6, ia::binary-6, 0::32>>

    e(k, xor(e(k, xor(r, p1)), p2))
  end

  @doc """
  `s1`: the short-term key from the two randoms.

  The bottom half of each random, the central's first. The top halves are
  discarded, which is not a shortcut -- it is what the function is defined to
  do.
  """
  @spec s1(binary(), binary(), binary()) :: binary()
  def s1(k, r1, r2) do
    e(k, binary_part(r2, 0, 8) <> binary_part(r1, 0, 8))
  end

  @doc """
  Cut a key down to the negotiated size.

  A key size below sixteen means the most significant octets are zeroed, and
  in wire order the most significant octets are the *last* ones. A key masked
  at the wrong end is still a valid-looking key, and the link fails to
  encrypt with no explanation.
  """
  @spec mask(binary(), pos_integer()) :: binary()
  def mask(key, 16), do: key

  def mask(key, size) do
    binary_part(key, 0, size) <> :binary.copy(<<0>>, 16 - size)
  end

  @doc "Exclusive-or of two equal-length binaries."
  @spec xor(binary(), binary()) :: binary()
  def xor(a, b), do: :crypto.exor(a, b)

  @doc "Reverse a binary."
  @spec reverse(binary()) :: binary()
  def reverse(binary) do
    binary |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
  end
end
