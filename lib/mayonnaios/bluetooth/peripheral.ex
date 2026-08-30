defmodule MayonnaiOS.Bluetooth.Peripheral do
  @moduledoc """
  A BLE peripheral: advertise, accept one central, and be a HID gamepad to it.

  This is the process that owns a connection. Everything below it is pure --
  `MayonnaiOS.Bluetooth.HCI` for packets, `L2CAP` for framing, `ATT` and
  `GATT` for the database, `SMP` for pairing -- and everything those modules
  cannot do without state happens here: the setup sequence, the connection,
  the key, and the decision about whether a report can be sent.

  ## One central at a time

  The controller could hold several connections and this holds one. A gamepad
  connected to two machines at once has to decide which of them the buttons
  are for, and there is no answer to that which is not a menu. So advertising
  stops when a central connects and starts again when it goes away, and the
  second machine sees a device that is not there.

  ## The order of the setup sequence is load-bearing

  Reset, then the event masks, then the buffer sizes, then the advertising
  parameters, then the data, then enable. Two of those orderings matter:

  * The event masks come before anything that could produce an event. LE Meta
    is masked off by default, so a connection that arrives before
    `LE Set Event Mask` is a connection this host never hears about -- and
    the controller will happily be connected while this process still thinks
    it is advertising.

  * `LE Set Advertising Data` comes before `LE Set Advertise Enable`.
    Advertising with the data set afterwards works, but for the first
    interval the device is on the air with an empty packet, which is what a
    host caches if it happened to be scanning at that moment. A cached
    nameless entry is remarkably persistent in Windows' device list.

  ## What a dropped report means

  `report/1` is a cast and can fail silently in three ways: no connection, no
  encryption, or no subscription. All three are normal -- the host has not
  finished setting up, or has gone away -- and none of them should cost the
  input path anything. They are counted, and `status/0` reports the counts,
  because "the buttons do nothing" is the symptom for all three and the
  counters are what tell them apart without a packet capture.
  """

  use GenServer
  require Logger

  alias MayonnaiOS.Bluetooth.{ATT, Advertising, Bonds, GATT, HCI, HOGP, Host, L2CAP, SMP}

  # The real pad's name, because the name is part of the identity: it is the
  # first thing a host shows and some third-party drivers match on it. See
  # `MayonnaiOS.Bluetooth.HOGP` -- the numbers, the name and the report
  # format change together or not at all.
  @default_name "Xbox Wireless Controller"

  defstruct name: @default_name,
            address: nil,
            db: nil,
            report_handle: nil,
            report_cccd: nil,
            report_map_handle: nil,
            battery_handle: nil,
            battery_cccd: nil,
            advertising?: false,
            connection: nil,
            packet_length: 27,
            signalling_id: 1,
            sent: 0,
            dropped: %{disconnected: 0, unencrypted: 0, unsubscribed: 0, no_credits: 0}

  @doc """
  Start advertising as a gamepad.

  `MayonnaiOS.Bluetooth.Host` must already be running: this process attaches
  to it rather than opening the controller itself, so that the socket's
  lifetime is not tied to a profile that may be restarted.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Send an input report.

  A cast, and deliberately: the input path must not wait on a radio. Reports
  that cannot be sent are dropped and counted rather than queued -- see the
  moduledoc.
  """
  @spec report(binary()) :: :ok
  def report(bytes), do: GenServer.cast(__MODULE__, {:report, bytes})

  @doc "Update the battery percentage the host sees."
  @spec battery(0..100) :: :ok
  def battery(percent), do: GenServer.cast(__MODULE__, {:battery, percent})

  @doc """
  What is going on, for the panel and for IEx.

  Every field here answers a question someone asks when it is not working:
  whether it is advertising at all, whether anything connected, whether that
  connection got as far as encryption, and whether the host ever subscribed.
  """
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Drop the current connection, if there is one, and advertise again."
  @spec disconnect() :: :ok
  def disconnect, do: GenServer.call(__MODULE__, :disconnect)

  @impl true
  def init(opts) do
    name =
      Keyword.get(opts, :name, Application.get_env(:mayonnaios, :controller_name, @default_name))

    db = HOGP.build(name)
    report = HOGP.report_handles(db)
    battery = HOGP.battery_handles(db)

    state = %__MODULE__{
      name: name,
      db: db,
      report_handle: report.value,
      report_cccd: report.cccd,
      report_map_handle: HOGP.report_map_handle(db),
      battery_handle: battery.value,
      battery_cccd: battery.cccd
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    :ok = Host.attach(self())

    with {:ok, _} <- Host.command(HCI.reset()),
         {:ok, _} <- Host.command(HCI.set_event_mask()),
         {:ok, _} <- Host.command(HCI.le_set_event_mask()),
         {:ok, _} <- Host.command(HCI.write_le_host_support()),
         {:ok, buffers} <- Host.read_buffers(),
         {:ok, address} <- Host.command(HCI.read_bd_addr()) do
      Logger.info("[peripheral] hci0 is #{HCI.address(address)}, advertising as #{state.name}")

      state = %{state | address: address, packet_length: buffers.packet_length}
      {:noreply, advertise(state)}
    else
      {:error, reason} ->
        # Setup failing is not a crash loop worth having: the panel needs to
        # be able to say what happened, and a supervisor restarting this every
        # second would bury the reason in a log that scrolls.
        Logger.error("[peripheral] setup failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    connection = state.connection

    {:reply,
     %{
       name: state.name,
       address: state.address && HCI.address(state.address),
       advertising: state.advertising?,
       connected: connection != nil,
       peer: connection && HCI.address(elem(connection.peer, 1)),
       encrypted: connection != nil and state.db.encrypted,
       subscribed: GATT.subscribed?(state.db, state.report_cccd),
       report_map_read: connection != nil and connection.report_map_read,
       # The latency budget, and the first number to look at when presses feel
       # late: nothing this device does can beat the interval the central
       # chose. Units on the wire are 1.25 ms.
       interval_ms: connection && connection.interval * 1.25,
       paired: connection != nil and SMP.state(connection.smp) == :paired,
       mtu: state.db.mtu,
       bonds: length(safe_bonds()),
       sent: state.sent,
       dropped: state.dropped
     }, state}
  end

  def handle_call(:disconnect, _from, %{connection: nil} = state), do: {:reply, :ok, state}

  def handle_call(:disconnect, _from, state) do
    Host.command(HCI.disconnect(state.connection.handle))
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:report, bytes}, state) do
    {:noreply, notify(state, state.report_handle, state.report_cccd, :report, bytes)}
  end

  def handle_cast({:battery, percent}, state) do
    state = %{state | db: GATT.put_value(state.db, :battery_level, <<percent>>)}

    # Battery notifications are best-effort in a stronger sense than reports:
    # a host that never subscribed still reads the value when it wants it.
    {:noreply,
     notify(state, state.battery_handle, state.battery_cccd, :battery_level, <<percent>>, false)}
  end

  @impl true
  def handle_info({:hci, {:event, :le_connection_complete, event}}, state) do
    {:noreply, connected(state, event)}
  end

  def handle_info({:hci, {:event, :disconnection_complete, event}}, state) do
    Logger.info("[peripheral] disconnected, reason 0x#{Integer.to_string(event.reason, 16)}")

    state = %{
      state
      | connection: nil,
        db: GATT.clear_subscriptions(state.db),
        advertising?: false
    }

    {:noreply, advertise(state)}
  end

  def handle_info(
        {:hci, {:event, :le_connection_update_complete, %{status: 0} = event}},
        %{connection: connection} = state
      )
      when connection != nil do
    Logger.info("[peripheral] connection interval now #{event.interval * 1.25} ms")
    {:noreply, put_in(state.connection.interval, event.interval)}
  end

  def handle_info({:hci, {:event, :le_long_term_key_request, event}}, state) do
    {:noreply, long_term_key(state, event)}
  end

  def handle_info({:hci, {:event, :encryption_change, %{status: 0, enabled: true}}}, state) do
    Logger.info("[peripheral] link encrypted")
    {:noreply, encrypted(state)}
  end

  def handle_info({:hci, {:event, :encryption_change, event}}, state) do
    Logger.warning("[peripheral] encryption did not start: #{inspect(event)}")
    {:noreply, state}
  end

  def handle_info({:hci, {:acl, handle, pb, data}}, %{connection: %{handle: handle}} = state) do
    {pdus, l2cap} = L2CAP.receive(state.connection.l2cap, pb, data)
    state = put_in(state.connection.l2cap, l2cap)

    {:noreply, Enum.reduce(pdus, state, &pdu/2)}
  end

  def handle_info({:hci, packet}, state) do
    Logger.debug("[peripheral] #{inspect(packet)}")
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("[peripheral] unexpected #{inspect(message)}")
    {:noreply, state}
  end

  # -- advertising ------------------------------------------------------------

  defp advertise(state) do
    with {:ok, _} <- Host.command(HCI.le_set_advertising_parameters()),
         {:ok, _} <- Host.command(HCI.le_set_advertising_data(Advertising.data())),
         {:ok, _} <-
           Host.command(HCI.le_set_scan_response_data(Advertising.scan_response(state.name))),
         {:ok, _} <- Host.command(HCI.le_set_advertise_enable(true)) do
      %{state | advertising?: true}
    else
      {:error, reason} ->
        Logger.error("[peripheral] could not advertise: #{inspect(reason)}")
        %{state | advertising?: false}
    end
  end

  # -- the connection ---------------------------------------------------------

  defp connected(state, %{status: 0} = event) do
    Logger.info("[peripheral] #{event.peer_address} connected, interval #{event.interval}")

    peer = {event.peer_address_type, HCI.address_bytes(event.peer_address)}

    connection = %{
      handle: event.handle,
      peer: peer,
      l2cap: L2CAP.new(),
      smp: SMP.new(local: {0x00, state.address}, peer: peer),
      interval: event.interval,
      report_map_read: false,
      parameters_retried: false
    }

    state = %{
      state
      | connection: connection,
        advertising?: false,
        db: GATT.clear_subscriptions(state.db)
    }

    # Only prompt for encryption when there is a bond to resume. Asking a host
    # that has never paired produces a pairing dialog nobody asked for, in the
    # middle of whatever they were doing; asking one that has paired saves a
    # round trip and gets the HID service readable before the host has to be
    # refused a read to find that out.
    if safe_bonds() == [] do
      state
    else
      send_smp(state, SMP.security_request())
    end
  end

  defp connected(state, event) do
    Logger.warning(
      "[peripheral] connection failed: status 0x#{Integer.to_string(event.status, 16)}"
    )

    advertise(state)
  end

  # Encryption events can arrive after the connection they belong to is gone:
  # the disconnection and the encryption change race on the way up from the
  # controller. Without this clause that race takes the peripheral down and,
  # because the session is one_for_all, the socket with it.
  defp encrypted(%{connection: nil} = state), do: state

  defp encrypted(state) do
    state = %{state | db: %{state.db | encrypted: true}}

    {smp, actions} = SMP.encrypted(state.connection.smp)
    state = put_in(state.connection.smp, smp)

    state = Enum.reduce(actions, state, &smp_action/2)

    # Now that the link is up and useful, ask for a shorter connection
    # interval. After encryption rather than before, because a host busy with
    # pairing has been observed to ignore the request and this device only
    # sends it once.
    request =
      L2CAP.connection_parameter_update_request(state.signalling_id)

    state = send_pdu(state, L2CAP.cid_signalling(), request)
    %{state | signalling_id: state.signalling_id + 1}
  end

  # Same race as above, and a worse outcome if it is not handled: the
  # controller is waiting for an answer, and a peripheral that crashed instead
  # of sending one leaves the central's encryption attempt to time out.
  defp long_term_key(%{connection: nil} = state, event) do
    Host.command(HCI.le_long_term_key_request_negative_reply(event.handle))
    state
  end

  defp long_term_key(state, event) do
    smp = state.connection.smp

    key =
      cond do
        # Mid-pairing: the key is the short-term one just derived, and the
        # central quotes zeros for EDIV and Rand because there is no bond yet.
        SMP.pairing?(smp) and SMP.short_term_key(smp) != nil ->
          SMP.short_term_key(smp)

        bond = find_bond(event.ediv, event.rand) ->
          Logger.info("[peripheral] resuming a bond")
          bond.ltk

        true ->
          nil
      end

    command =
      if key do
        HCI.le_long_term_key_request_reply(event.handle, key)
      else
        # No key for what the central is quoting. It will fail encryption and
        # most hosts then offer to pair again, which is the correct outcome
        # after the bond file was lost.
        Logger.warning("[peripheral] no key for this link; the host will have to pair again")
        HCI.le_long_term_key_request_negative_reply(event.handle)
      end

    Host.command(command)
    state
  end

  # -- L2CAP routing ----------------------------------------------------------

  defp pdu({:error, reason}, state) do
    Logger.warning("[peripheral] l2cap: #{inspect(reason)}")
    state
  end

  defp pdu({cid, payload}, state) do
    cond do
      cid == L2CAP.cid_att() -> att(state, payload)
      cid == L2CAP.cid_smp() -> smp(state, payload)
      cid == L2CAP.cid_signalling() -> signalling(state, payload)
      true -> log_unknown_channel(state, cid, payload)
    end
  end

  defp att(state, payload) do
    request = ATT.decode(payload)
    state = note_report_map_read(state, request)
    {response, db, events} = GATT.request(state.db, request)
    state = %{state | db: db}

    state = Enum.reduce(events, state, &gatt_event/2)

    if response, do: send_pdu(state, L2CAP.cid_att(), response), else: state
  end

  # A host reads the report map once per pairing and caches it against the
  # bond. So this is the line that says a descriptor change has actually
  # landed: without it, a firmware that changed the button layout and a host
  # still parsing the old one look exactly the same from here.
  defp note_report_map_read(state, request) do
    handle =
      case request do
        {:read, handle} -> handle
        {:read_blob, handle, _offset} -> handle
        _other -> nil
      end

    if (is_integer(handle) and handle == state.report_map_handle and
          state.connection) && not state.connection.report_map_read do
      Logger.info("[peripheral] host read the report map")
      put_in(state.connection.report_map_read, true)
    else
      state
    end
  end

  defp gatt_event({:subscription, handle, notify?, _indicate?}, state) do
    what = if handle == state.report_cccd, do: "reports", else: "handle #{handle}"

    Logger.info(
      "[peripheral] host #{if notify?, do: "subscribed to", else: "unsubscribed from"} #{what}"
    )

    state
  end

  defp gatt_event({:mtu, mtu}, state) do
    Logger.info("[peripheral] att mtu #{mtu}")
    state
  end

  defp gatt_event(event, state) do
    Logger.debug("[peripheral] gatt: #{inspect(event)}")
    state
  end

  defp smp(state, payload) do
    {smp, actions} = SMP.handle(state.connection.smp, payload)
    state = put_in(state.connection.smp, smp)
    Enum.reduce(actions, state, &smp_action/2)
  end

  defp smp_action({:send, pdu}, state), do: send_smp(state, pdu)

  defp smp_action({:bond, bond}, state) do
    Logger.info("[peripheral] bonded")
    safe_put_bond(bond)
    state
  end

  defp smp_action({:failed, reason}, state) do
    Logger.warning("[peripheral] pairing failed: #{inspect(reason)}")
    state
  end

  defp smp_action({:ltk, _key}, state), do: state
  defp smp_action(:paired, state), do: state

  defp signalling(state, payload) do
    case L2CAP.decode_signalling(payload) do
      {:connection_parameter_update_response, _id, :accepted} ->
        Logger.info("[peripheral] connection parameter update accepted")
        state

      {:connection_parameter_update_response, _id, :rejected} ->
        request_apple_parameters(state)

      {:unhandled, code, id} ->
        Logger.debug("[peripheral] signalling 0x#{Integer.to_string(code, 16)} rejected")
        send_pdu(state, L2CAP.cid_signalling(), L2CAP.command_reject(id))

      {:error, reason} ->
        Logger.warning("[peripheral] signalling: #{inspect(reason)}")
        state
    end
  end

  # Apple publishes rules a connection parameter request must satisfy or be
  # refused outright, and the first request this device sends breaks two of
  # them: it asks for a 7.5 ms floor where the minimum allowed is 15 ms, and
  # for a 15 ms ceiling where the ceiling must be at least the floor plus
  # 15 ms. A Mac therefore says no and the connection stays on whatever
  # interval it picked when it connected, which is the slowest thing in the
  # chain and is felt as buttons that need holding.
  #
  # So the refusal is answered rather than logged and forgotten: ask again
  # for 15 ms to 30 ms, which satisfies the rules. Hosts that accepted the
  # first request never reach this, and keep the shorter interval -- there is
  # no reason to give up 7.5 ms on a machine that was happy to grant it.
  #
  # Once, and only once. A host that refuses both has decided, and a request
  # per refusal is a loop.
  defp request_apple_parameters(%{connection: %{parameters_retried: true}} = state) do
    Logger.info("[peripheral] connection parameter update rejected twice; leaving it alone")
    state
  end

  defp request_apple_parameters(state) do
    Logger.info("[peripheral] parameter update rejected; asking again for 15-30 ms")

    request =
      L2CAP.connection_parameter_update_request(state.signalling_id,
        min_interval: 12,
        max_interval: 24
      )

    state = send_pdu(state, L2CAP.cid_signalling(), request)
    state = put_in(state.connection.parameters_retried, true)
    %{state | signalling_id: state.signalling_id + 1}
  end

  defp log_unknown_channel(state, cid, payload) do
    Logger.debug("[peripheral] #{byte_size(payload)} bytes on unhandled cid #{cid}")
    state
  end

  # -- sending ----------------------------------------------------------------

  defp send_smp(state, pdu), do: send_pdu(state, L2CAP.cid_smp(), pdu)

  # Everything that answers a question goes through the queued send:
  # `Host.queue_acl/1` holds what the controller cannot take yet and sends
  # it as buffers come back. A dropped response is not a smaller failure
  # than a dropped connection -- a host waits thirty seconds for the report
  # map it asked for, gives up, and the device is paired, encrypted and
  # invisible. The 283-byte descriptor reads as ten fragments against eight
  # buffers, so an all-or-nothing send throws exactly that answer away. Only
  # notifications may be dropped, and they go through `notify/6` below.
  defp send_pdu(%{connection: nil} = state, _cid, _payload), do: state

  defp send_pdu(state, cid, payload) do
    :ok = Host.queue_acl(fragments(state, cid, payload))
    state
  end

  defp fragments(state, cid, payload) do
    cid
    |> L2CAP.encode(payload)
    |> then(&L2CAP.fragments(state.connection.handle, &1, state.packet_length))
  end

  defp notify(state, handle, cccd, key, value, count_drops \\ true)

  defp notify(%{connection: nil} = state, _handle, _cccd, _key, _value, count) do
    if count, do: drop(state, :disconnected), else: state
  end

  defp notify(state, handle, cccd, key, value, count) do
    db = GATT.put_value(state.db, key, value)
    state = %{state | db: db}

    cond do
      not state.db.encrypted ->
        if count, do: drop(state, :unencrypted), else: state

      not GATT.subscribed?(state.db, cccd) ->
        if count, do: drop(state, :unsubscribed), else: state

      true ->
        # The droppable send, and the only caller of it. A notification is
        # the current state of something; when the credits are not there,
        # the next one supersedes it, and the counter says how often.
        case Host.send_acl(fragments(state, L2CAP.cid_att(), ATT.notification(handle, value))) do
          :ok -> %{state | sent: state.sent + 1}
          {:error, reason} -> if count, do: drop(state, reason), else: state
        end
    end
  end

  defp drop(state, reason) do
    %{state | dropped: Map.update(state.dropped, reason, 1, &(&1 + 1))}
  end

  # -- the bond store, which may not be running -------------------------------
  #
  # The peripheral is useful without it: a session that pairs and never bonds
  # still works until the host goes away. So a missing bond store degrades to
  # "no bonds" rather than taking the connection down with it.

  defp safe_bonds do
    if Process.whereis(Bonds), do: Bonds.list(), else: []
  end

  defp find_bond(ediv, rand) do
    if Process.whereis(Bonds), do: Bonds.find(ediv, rand), else: nil
  end

  defp safe_put_bond(bond) do
    if Process.whereis(Bonds), do: Bonds.put(bond)
  end
end
