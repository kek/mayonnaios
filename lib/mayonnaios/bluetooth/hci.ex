defmodule MayonnaiOS.Bluetooth.HCI do
  @moduledoc """
  The HCI packets this project sends and the ones it understands coming back.

  Pure functions over binaries, in the same spirit as
  `MayonnaiOS.Bluetooth.HCISocket`: the socket is four calls and needs the
  handheld, while everything that can be *wrong* is a byte layout and can be
  checked on a laptop. `MayonnaiOS.Bluetooth.Host` is the process that puts
  these on the wire.

  ## Only what is used

  HCI is a large specification and this is not an implementation of it. What
  is here is the set of commands and events needed to be a connectable BLE
  peripheral: reset, advertise, accept a connection, move ACL data, answer a
  long-term key request, and hang up. Anything else the controller sends is
  decoded as far as `{:event, code, params}` and handed on, because a stack
  that crashes on an event it did not expect is worse than one that logs it.

  ## Little-endian, everywhere, including the address

  Every multi-byte field in HCI is little-endian, and BD_ADDRs are no
  exception: the address printed as `AA:BB:CC:DD:EE:FF` goes on the wire as
  `FF EE DD CC BB AA`. `address/1` and `address_bytes/1` are the two
  directions of that, and they exist so the reversal happens in one place
  rather than at each call site -- an address that comes out backwards looks
  like a different device rather than like a bug.

  ## Command Status is not an error

  Two events can complete a command. Most return Command Complete with their
  results; the ones that take time on the air -- Disconnect is the one used
  here -- return Command Status immediately, meaning "accepted, the result
  comes later as its own event". Both carry a status byte, and both are
  decoded here, because treating a Command Status as an unmatched event is how
  a caller ends up waiting for a reply that already arrived.
  """

  import Bitwise

  # H4 packet type bytes, which the user channel uses in both directions.
  @command_pkt 0x01
  @acl_pkt 0x02
  @event_pkt 0x04

  # Events.
  @evt_disconnection_complete 0x05
  @evt_encryption_change 0x08
  @evt_command_complete 0x0E
  @evt_command_status 0x0F
  @evt_number_of_completed_packets 0x13
  @evt_encryption_key_refresh 0x30
  @evt_le_meta 0x3E

  # LE meta subevents.
  @le_connection_complete 0x01
  @le_advertising_report 0x02
  @le_connection_update_complete 0x03
  @le_read_remote_features_complete 0x04
  @le_long_term_key_request 0x05
  @le_enhanced_connection_complete 0x0A

  # Commands, by OGF/OCF as the spec numbers them.
  @op_disconnect 0x0406
  @op_set_event_mask 0x0C01
  @op_reset 0x0C03
  @op_write_le_host_support 0x0C6D
  @op_read_local_version 0x1001
  @op_read_buffer_size 0x1005
  @op_read_bd_addr 0x1009
  @op_le_set_event_mask 0x2001
  @op_le_read_buffer_size 0x2002
  @op_le_read_local_supported_features 0x2003
  @op_le_set_advertising_parameters 0x2006
  @op_le_set_advertising_data 0x2008
  @op_le_set_scan_response_data 0x2009
  @op_le_set_advertise_enable 0x200A
  @op_le_set_scan_parameters 0x200B
  @op_le_set_scan_enable 0x200C
  @op_le_long_term_key_request_reply 0x201A
  @op_le_long_term_key_request_negative_reply 0x201B

  @doc "Opcodes by name, so callers and logs can speak in words."
  @spec opcode(atom()) :: non_neg_integer()
  def opcode(:disconnect), do: @op_disconnect
  def opcode(:set_event_mask), do: @op_set_event_mask
  def opcode(:reset), do: @op_reset
  def opcode(:write_le_host_support), do: @op_write_le_host_support
  def opcode(:read_local_version), do: @op_read_local_version
  def opcode(:read_buffer_size), do: @op_read_buffer_size
  def opcode(:read_bd_addr), do: @op_read_bd_addr
  def opcode(:le_set_event_mask), do: @op_le_set_event_mask
  def opcode(:le_read_buffer_size), do: @op_le_read_buffer_size
  def opcode(:le_read_local_supported_features), do: @op_le_read_local_supported_features
  def opcode(:le_set_advertising_parameters), do: @op_le_set_advertising_parameters
  def opcode(:le_set_advertising_data), do: @op_le_set_advertising_data
  def opcode(:le_set_scan_response_data), do: @op_le_set_scan_response_data
  def opcode(:le_set_advertise_enable), do: @op_le_set_advertise_enable
  def opcode(:le_set_scan_parameters), do: @op_le_set_scan_parameters
  def opcode(:le_set_scan_enable), do: @op_le_set_scan_enable
  def opcode(:le_long_term_key_request_reply), do: @op_le_long_term_key_request_reply

  def opcode(:le_long_term_key_request_negative_reply),
    do: @op_le_long_term_key_request_negative_reply

  @doc "The name for an opcode, or the number when it is not one of ours."
  @spec opcode_name(non_neg_integer()) :: atom() | non_neg_integer()
  def opcode_name(opcode) do
    Enum.find_value(known_opcodes(), opcode, fn name ->
      if opcode(name) == opcode, do: name
    end)
  end

  defp known_opcodes do
    [
      :disconnect,
      :set_event_mask,
      :reset,
      :write_le_host_support,
      :read_local_version,
      :read_buffer_size,
      :read_bd_addr,
      :le_set_event_mask,
      :le_read_buffer_size,
      :le_read_local_supported_features,
      :le_set_advertising_parameters,
      :le_set_advertising_data,
      :le_set_scan_response_data,
      :le_set_advertise_enable,
      :le_set_scan_parameters,
      :le_set_scan_enable,
      :le_long_term_key_request_reply,
      :le_long_term_key_request_negative_reply
    ]
  end

  @doc """
  Frame a command: packet type, opcode, parameter length, parameters.
  """
  @spec command(atom() | non_neg_integer(), binary()) :: binary()
  def command(opcode, params \\ <<>>)
  def command(name, params) when is_atom(name), do: command(opcode(name), params)

  def command(opcode, params) when is_integer(opcode) do
    <<@command_pkt, opcode::16-little, byte_size(params), params::binary>>
  end

  # -- the commands, with their parameters spelled out ------------------------

  @doc """
  The event mask, with LE Meta turned on.

  The controller's default mask stops at bit 44 and LE Meta is bit 61, so
  without this command the LE Connection Complete event never arrives and a
  central can connect to a peripheral that never notices. That failure looks
  exactly like advertising not working, which is why this is the first command
  after Reset rather than something set up later.
  """
  @spec set_event_mask(non_neg_integer()) :: binary()
  def set_event_mask(mask \\ 0x3FFF_FFFF_FFFF_FFFF) do
    command(:set_event_mask, <<mask::64-little>>)
  end

  @doc """
  The LE event mask.

  Default is bit 0 alone -- Connection Complete -- and the Long Term Key
  Request event (bit 4) is the one that matters most here: without it the
  controller has nowhere to ask for the key and encryption silently never
  starts, which a host reports as "pairing failed" with no further detail.

  Remote Connection Parameter Request (bit 5) is deliberately *not* set. With
  it clear the controller answers those requests itself; with it set they
  become the host's problem, and this host has nothing useful to say about
  them.
  """
  @spec le_set_event_mask(non_neg_integer()) :: binary()
  def le_set_event_mask(mask \\ 0x1F) do
    command(:le_set_event_mask, <<mask::64-little>>)
  end

  @doc """
  Tell a dual-mode controller that this host does LE.

  Deprecated since 4.1 and harmless on a controller that ignores it, but this
  is a dual-mode Realtek part and the bit is what gates LE on some of them.
  """
  @spec write_le_host_support(boolean()) :: binary()
  def write_le_host_support(enabled \\ true) do
    command(:write_le_host_support, <<bool(enabled), 0x00>>)
  end

  @doc "Reset the controller."
  @spec reset() :: binary()
  def reset, do: command(:reset)

  @doc "Read the controller's own address."
  @spec read_bd_addr() :: binary()
  def read_bd_addr, do: command(:read_bd_addr)

  @doc "Read Local Version Information."
  @spec read_local_version() :: binary()
  def read_local_version, do: command(:read_local_version)

  @doc "How many ACL packets the controller will hold, and how big."
  @spec le_read_buffer_size() :: binary()
  def le_read_buffer_size, do: command(:le_read_buffer_size)

  @doc """
  The same question for the shared BR/EDR buffers.

  A dual-mode controller that keeps one pool for both transports answers LE
  Read Buffer Size with zeros, and zeros mean "ask the other command", not
  "no buffers". Believing the zeros would produce a peripheral that connects
  and never sends a byte.
  """
  @spec read_buffer_size() :: binary()
  def read_buffer_size, do: command(:read_buffer_size)

  @doc "The controller's LE feature bits."
  @spec le_read_local_supported_features() :: binary()
  def le_read_local_supported_features, do: command(:le_read_local_supported_features)

  @doc """
  Connectable undirected advertising, on all three channels.

  Intervals are in units of 0.625 ms. The defaults here are 30 ms to 60 ms,
  which is fast enough that a host's scan finds the device in the second or
  two someone is willing to wait at a pairing screen, and slow enough not to
  be antisocial about it.
  """
  @spec le_set_advertising_parameters(keyword()) :: binary()
  def le_set_advertising_parameters(opts \\ []) do
    min = Keyword.get(opts, :min_interval, 0x0030)
    max = Keyword.get(opts, :max_interval, 0x0060)
    # 0x00 = ADV_IND, connectable and scannable, undirected.
    type = Keyword.get(opts, :type, 0x00)
    # 0x00 = use the controller's public address. This device has a real one
    # from the Realtek part, and a stable address is what lets a bonded host
    # reconnect without resolving anything.
    own_address_type = Keyword.get(opts, :own_address_type, 0x00)
    channel_map = Keyword.get(opts, :channel_map, 0x07)
    filter_policy = Keyword.get(opts, :filter_policy, 0x00)

    command(
      :le_set_advertising_parameters,
      <<min::16-little, max::16-little, type, own_address_type, 0x00, 0::48, channel_map,
        filter_policy>>
    )
  end

  @doc """
  Advertising data: 31 bytes on the wire, zero-padded, with a length byte in
  front of them.

  The padding is not optional -- the command's parameter is always 32 bytes,
  significant length first -- and a controller handed a short parameter
  answers `Invalid HCI Command Parameters` rather than advertising anything.
  """
  @spec le_set_advertising_data(binary()) :: binary()
  def le_set_advertising_data(data) when byte_size(data) <= 31 do
    command(:le_set_advertising_data, <<byte_size(data), pad(data, 31)::binary>>)
  end

  @doc "Scan response data, framed exactly like the advertising data."
  @spec le_set_scan_response_data(binary()) :: binary()
  def le_set_scan_response_data(data) when byte_size(data) <= 31 do
    command(:le_set_scan_response_data, <<byte_size(data), pad(data, 31)::binary>>)
  end

  @doc """
  Scan parameters: active scanning, so scan responses come back too.

  Active (0x01) rather than passive because a passive scan sees only the
  advertisement, and most devices keep their name in the *scan response* --
  this project's own peripheral does, because the name did not fit in the
  31-byte advertisement. A passive scan of a room therefore produces a list
  of addresses with no names in it, which is indistinguishable from a scan
  that is not working.

  Interval and window are in units of 0.625 ms. 37.5 ms interval with a
  30 ms window is an 80% duty cycle: high enough that a device advertising
  at the slow end of the usual range turns up in a second or two, and not
  continuous, which would leave the radio no gaps at all.
  """
  @spec le_set_scan_parameters(keyword()) :: binary()
  def le_set_scan_parameters(opts \\ []) do
    # 0x01 = active. 0x00 would be passive.
    type = Keyword.get(opts, :type, 0x01)
    interval = Keyword.get(opts, :interval, 0x0060)
    window = Keyword.get(opts, :window, 0x0030)
    # 0x00 = the controller's public address, the same choice advertising
    # makes: this device has a real one from the Realtek part.
    own_address_type = Keyword.get(opts, :own_address_type, 0x00)
    # 0x00 = accept every advertisement. There is no accept list to filter
    # against, and filtering is what a scan screen exists not to do.
    filter_policy = Keyword.get(opts, :filter_policy, 0x00)

    command(
      :le_set_scan_parameters,
      <<type, interval::16-little, window::16-little, own_address_type, filter_policy>>
    )
  end

  @doc """
  Start or stop scanning.

  `filter_duplicates` defaults to **false**, which is the opposite of what
  most examples do, and it is deliberate. With duplicate filtering on, the
  controller reports each address once and then goes quiet, so a device that
  has been switched off or carried out of range stays on the screen forever
  with nothing to say it is gone. With it off, every advertisement arrives,
  which is what lets the list carry an age and an RSSI that mean something.

  The cost is one event per advertising interval per device -- tens per
  second in a busy room. That is a handful of small binaries to decode, and
  cheaper than a list that lies.
  """
  @spec le_set_scan_enable(boolean(), boolean()) :: binary()
  def le_set_scan_enable(enabled, filter_duplicates \\ false) do
    command(:le_set_scan_enable, <<bool(enabled), bool(filter_duplicates)>>)
  end

  @doc "Start or stop advertising."
  @spec le_set_advertise_enable(boolean()) :: binary()
  def le_set_advertise_enable(enabled) do
    command(:le_set_advertise_enable, <<bool(enabled)>>)
  end

  @doc """
  Hand the controller the key for a link the central is encrypting.

  The key is passed in wire order -- least significant octet first -- and goes
  out exactly as given. That is the same order the Security Manager receives
  and stores keys in, and holding one convention across the whole stack is
  worth more than each layer being individually intuitive: a key reversed an
  odd number of times produces an encrypted link that both ends believe in
  and neither can decrypt, which shows up as an immediate disconnect with no
  error anywhere. `MayonnaiOS.Bluetooth.SMP` has the note on why wire order
  is the one that was picked.
  """
  @spec le_long_term_key_request_reply(non_neg_integer(), <<_::128>>) :: binary()
  def le_long_term_key_request_reply(handle, <<ltk::binary-16>>) do
    command(:le_long_term_key_request_reply, <<handle::16-little, ltk::binary>>)
  end

  @doc """
  Tell the controller there is no key for this link.

  The central then fails encryption and, if it was reconnecting to a bond it
  thinks it has, usually drops the bond and offers to pair again -- which is
  the correct outcome after a firmware update wiped the key store.
  """
  @spec le_long_term_key_request_negative_reply(non_neg_integer()) :: binary()
  def le_long_term_key_request_negative_reply(handle) do
    command(:le_long_term_key_request_negative_reply, <<handle::16-little>>)
  end

  @doc "Hang up. 0x13 is 'remote user terminated connection', the polite one."
  @spec disconnect(non_neg_integer(), non_neg_integer()) :: binary()
  def disconnect(handle, reason \\ 0x13) do
    command(:disconnect, <<handle::16-little, reason>>)
  end

  # -- ACL data ---------------------------------------------------------------

  @doc """
  Frame an ACL data packet.

  `pb` is the packet boundary flag: `:start` for the first fragment of an
  L2CAP PDU and `:continue` for the rest. On LE the start flag is 0b00 --
  "first non-automatically-flushable" -- and not 0b10, which is what BR/EDR
  uses and what the controller sends *back*. Both are accepted on the way in
  by `decode/1`; only 0b00 is sent.
  """
  @spec acl(non_neg_integer(), :start | :continue, binary()) :: binary()
  def acl(handle, pb, data) do
    flags =
      case pb do
        :start -> 0b0000
        :continue -> 0b0001
      end

    <<@acl_pkt, bor(handle, bsl(flags, 12))::16-little, byte_size(data)::16-little, data::binary>>
  end

  # -- decoding ---------------------------------------------------------------

  @typedoc "What came off the socket."
  @type packet ::
          {:event, atom() | non_neg_integer(), map()}
          | {:acl, non_neg_integer(), :start | :continue, binary()}
          | {:unknown, binary()}

  @doc """
  Decode one packet from the controller.

  Events are decoded to `{:event, name, params}` where the name is an atom for
  the events this stack acts on and the raw code for everything else; the
  params map is only as detailed as the caller needs. ACL data comes back with
  its handle and boundary flag for `MayonnaiOS.Bluetooth.L2CAP` to reassemble.
  """
  @spec decode(binary()) :: packet()
  def decode(<<@event_pkt, code, plen, params::binary>>) when byte_size(params) == plen do
    event(code, params)
  end

  def decode(<<@acl_pkt, header::16-little, dlen::16-little, data::binary>>)
      when byte_size(data) == dlen do
    handle = band(header, 0x0FFF)

    pb =
      case band(bsr(header, 12), 0b0011) do
        0b0001 -> :continue
        _first -> :start
      end

    {:acl, handle, pb, data}
  end

  def decode(packet), do: {:unknown, packet}

  defp event(@evt_command_complete, <<ncmd, opcode::16-little, params::binary>>) do
    {:event, :command_complete,
     %{allowed_commands: ncmd, opcode: opcode, name: opcode_name(opcode), params: params}}
  end

  defp event(@evt_command_status, <<status, ncmd, opcode::16-little>>) do
    {:event, :command_status,
     %{status: status, allowed_commands: ncmd, opcode: opcode, name: opcode_name(opcode)}}
  end

  defp event(@evt_disconnection_complete, <<status, handle::16-little, reason>>) do
    {:event, :disconnection_complete, %{status: status, handle: handle, reason: reason}}
  end

  defp event(@evt_encryption_change, <<status, handle::16-little, enabled>>) do
    {:event, :encryption_change, %{status: status, handle: handle, enabled: enabled != 0}}
  end

  defp event(@evt_encryption_key_refresh, <<status, handle::16-little>>) do
    {:event, :encryption_key_refresh, %{status: status, handle: handle}}
  end

  defp event(@evt_number_of_completed_packets, <<count, rest::binary>>) do
    {:event, :number_of_completed_packets, %{handles: completed(rest, count, [])}}
  end

  defp event(@evt_le_meta, <<subevent, params::binary>>), do: le_meta(subevent, params)

  defp event(code, params), do: {:event, code, %{params: params}}

  defp le_meta(
         @le_connection_complete,
         <<status, handle::16-little, role, peer_type, peer::binary-6, interval::16-little,
           latency::16-little, timeout::16-little, accuracy>>
       ) do
    {:event, :le_connection_complete,
     %{
       status: status,
       handle: handle,
       role: role(role),
       peer_address_type: peer_type,
       peer_address: address(peer),
       interval: interval,
       latency: latency,
       supervision_timeout: timeout,
       clock_accuracy: accuracy
     }}
  end

  # The enhanced form adds the local and peer resolvable addresses in the
  # middle. Decoded to the same shape as the plain one, because nothing above
  # here cares which of the two the controller chose to send.
  defp le_meta(
         @le_enhanced_connection_complete,
         <<status, handle::16-little, role, peer_type, peer::binary-6, _local_rpa::binary-6,
           _peer_rpa::binary-6, interval::16-little, latency::16-little, timeout::16-little,
           accuracy>>
       ) do
    {:event, :le_connection_complete,
     %{
       status: status,
       handle: handle,
       role: role(role),
       peer_address_type: peer_type,
       peer_address: address(peer),
       interval: interval,
       latency: latency,
       supervision_timeout: timeout,
       clock_accuracy: accuracy
     }}
  end

  # The reports are interleaved, not columnar, and that is the trap.
  #
  # The specification writes this event's parameters as parallel arrays --
  # Event_Type[i], Address_Type[i], Address[i], Data_Length[i], Data[i],
  # RSSI[i] -- which reads as six arrays laid end to end. It is not: each
  # report is a complete record and they follow one another. The reference
  # for that reading is the kernel's own, `struct hci_ev_le_advertising_info`
  # in `include/net/bluetooth/hci.h` -- type, bdaddr_type, bdaddr, length,
  # data[] -- with the RSSI taken as the byte after the data, which is how
  # the kernel's LE advertising report handler walks the buffer.
  #
  # Num_Reports is 0x01 on every controller anyone has met, so the columnar
  # reading parses the common case correctly and falls apart only in a busy
  # room -- which is the worst possible time to find out.
  defp le_meta(@le_advertising_report, <<count, rest::binary>>) do
    {:event, :le_advertising_report, %{reports: advertising_reports(rest, count, [])}}
  end

  defp le_meta(
         @le_connection_update_complete,
         <<status, handle::16-little, interval::16-little, latency::16-little,
           timeout::16-little>>
       ) do
    {:event, :le_connection_update_complete,
     %{
       status: status,
       handle: handle,
       interval: interval,
       latency: latency,
       supervision_timeout: timeout
     }}
  end

  defp le_meta(@le_long_term_key_request, <<handle::16-little, rand::binary-8, ediv::binary-2>>) do
    # rand and ediv name the bond the central is resuming. Both are kept as
    # the bytes that arrived rather than decoded into numbers: they are
    # compared for equality against what this device generated and sent, and
    # a value that is never arithmetic has no business being an integer --
    # decoding one of the two and not the other is how a lookup misses.
    {:event, :le_long_term_key_request, %{handle: handle, rand: rand, ediv: ediv}}
  end

  defp le_meta(@le_read_remote_features_complete, <<status, handle::16-little, features::64>>) do
    {:event, :le_read_remote_features_complete,
     %{status: status, handle: handle, features: features}}
  end

  defp le_meta(subevent, params), do: {:event, {:le_meta, subevent}, %{params: params}}

  defp advertising_reports(_rest, 0, acc), do: Enum.reverse(acc)

  defp advertising_reports(
         <<event_type, address_type, peer::binary-6, length, data::binary-size(length),
           rssi::signed-8, rest::binary>>,
         count,
         acc
       ) do
    report = %{
      event_type: advertising_event_type(event_type),
      address_type: address_type,
      address: address(peer),
      address_bytes: peer,
      data: data,
      # 127 is the specification's "not available", and it is a real value a
      # controller sends. Reported as nil rather than as an absurdly strong
      # signal, because +127 dBm sorted to the top of a list would be the
      # loudest thing in the room.
      rssi: if(rssi == 127, do: nil, else: rssi)
    }

    advertising_reports(rest, count - 1, [report | acc])
  end

  # A truncated or malformed run: keep the reports that did parse. The
  # alternative is a function clause error inside the socket reader, which
  # would take the whole stack down over one bad event.
  defp advertising_reports(_rest, _count, acc), do: Enum.reverse(acc)

  # ADV_IND and ADV_DIRECT_IND are the connectable ones; SCAN_RSP is the
  # answer to an active scan and is where names usually live.
  defp advertising_event_type(0x00), do: :adv_ind
  defp advertising_event_type(0x01), do: :adv_direct_ind
  defp advertising_event_type(0x02), do: :adv_scan_ind
  defp advertising_event_type(0x03), do: :adv_nonconn_ind
  defp advertising_event_type(0x04), do: :scan_rsp
  defp advertising_event_type(other), do: other

  defp completed(<<>>, _count, acc), do: Enum.reverse(acc)

  defp completed(<<handle::16-little, packets::16-little, rest::binary>>, count, acc) do
    completed(rest, count, [{handle, packets} | acc])
  end

  defp completed(_leftover, _count, acc), do: Enum.reverse(acc)

  defp role(0x00), do: :central
  defp role(0x01), do: :peripheral
  defp role(other), do: other

  # -- return parameters this stack reads -------------------------------------

  @doc """
  Split the status byte off a command's return parameters.
  """
  @spec status(binary()) :: {:ok, binary()} | {:error, {:hci_status, non_neg_integer()}}
  def status(<<0x00, rest::binary>>), do: {:ok, rest}
  def status(<<code, _rest::binary>>), do: {:error, {:hci_status, code}}
  def status(<<>>), do: {:error, :no_return_parameters}

  @doc "LE Read Buffer Size: how big an ACL payload may be, and how many."
  @spec le_buffer_size(binary()) ::
          {:ok, %{packet_length: non_neg_integer(), count: non_neg_integer()}}
  def le_buffer_size(<<length::16-little, count>>) do
    {:ok, %{packet_length: length, count: count}}
  end

  def le_buffer_size(other), do: {:error, {:malformed_le_buffer_size, other}}

  @doc """
  A BD_ADDR as the string people read, from the six bytes on the wire.
  """
  @spec address(binary()) :: String.t()
  def address(<<addr::binary-6>>) do
    addr
    |> reverse()
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> String.upcase()
  end

  @doc "The six wire bytes for an address written the way people read it."
  @spec address_bytes(String.t()) :: binary()
  def address_bytes(text) do
    text
    |> String.split(":")
    |> Enum.map(&String.to_integer(&1, 16))
    |> :binary.list_to_bin()
    |> reverse()
  end

  @doc "Reverse a binary, which is most of what talking to HCI consists of."
  @spec reverse(binary()) :: binary()
  def reverse(binary) do
    binary |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
  end

  defp pad(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))

  defp bool(true), do: 0x01
  defp bool(false), do: 0x00
end
