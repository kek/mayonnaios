defmodule MayonnaiOS.WiFi.App do
  @moduledoc """
  The System menu's **WiFi** row: what is on the air, what this device is
  configured to join, and the buttons that change either.

  An app rather than a program, on the same terms as `MayonnaiOS.Update.App`:
  a module in this firmware, started in this VM, with a scene of its own and
  no external process handed the screen. It takes no hardware away from
  anything -- reading the radio is a property lookup and configuring it is a
  message to `vintage_net` -- so unlike the two Bluetooth apps nothing stops
  this one running whenever the row is picked.

  ## The state machine

      :listing   the list is up. The cursor moves, A picks
      :editing   the passphrase wheel is up for the selected network
      :joining   the configuration is written; waiting for the radio
      :joined    associated, with an address
      :failed    it did not work, and `:error` says what is known

  ## The buttons

      D-pad up/down   move the cursor
      A               join the selected network -- straight away if it is
                      open or already saved, through the passphrase wheel if
                      it is secured and is not
      X               change the passphrase of a saved network, which is the
                      one repair a list of saved networks otherwise cannot
                      make
      Y               forget a saved network. Twice: the first press arms the
                      row and the second does it
      B               cancel the wheel, or the arming. Otherwise the
                      launcher's, and it leaves
      Menu            the launcher's, always

  B is claimed dynamically -- see `claims_back?/0`. `MayonnaiOS.Launcher`
  asks on every report, so the same button cancels an overlay while one is up
  and leaves the app when none is.

  ## Scanning is on a timer, and the list is read on another

  `VintageNet.scan/1` is a request, not an answer: results appear on a
  property a second or two later, and adapters vary enough that the advice in
  `vintage_net`'s own docs is to ask again every ten seconds while somebody is
  picking a network. So this process asks on one timer and re-reads the list
  on a faster one, and neither waits for the other.

  ## Waiting for a join, and the two ways it ends badly

  Writing the configuration is where this app's work stops and
  `wpa_supplicant`'s begins, so `:joining` is a wait on two subscriptions --
  the connection state, and the supplicant's own events.

  A rejected passphrase arrives as an event, and `MayonnaiOS.WiFi` explains
  why that is worth waiting for rather than inferring from a clock: the
  screen can say *the passphrase was refused* instead of *something did not
  work*. That case also withdraws the network again, because a network known
  to be wrong is one the supplicant keeps retrying over the top of the one
  that works.

  Everything else is the deadline, and a deadline expiring leaves the network
  configured. DHCP on a tired router takes longer than any number worth
  putting on a panel, and a join that completes thirty seconds after the
  screen gave up is a join -- the status bar will say so.
  """

  use GenServer

  require Logger

  alias MayonnaiOS.WiFi
  alias MayonnaiOS.WiFi.Editor

  @sessions MayonnaiOS.WiFi.App.Sessions

  # The buttons as printed on the shell. These atoms name the opposite
  # button -- :btn_b is physical A -- and `MayonnaiOS.Launcher`'s moduledoc
  # has the device tree that says so.
  @a :btn_b
  @b :btn_a
  @x :btn_y
  @y :btn_x
  @l1 :btn_tl
  @r1 :btn_tr
  @up :btn_dpad_up
  @down :btn_dpad_down
  @left :btn_dpad_left
  @right :btn_dpad_right
  @menu :btn_mode

  # How often the list is re-read. Fast enough that a network appearing feels
  # immediate, slow enough that it is not a scene rebuild per frame.
  @refresh_ms 1_000

  # How often a fresh scan is asked for. vintage_net's own guidance for a
  # screen somebody is picking a network on.
  @scan_ms 8_000

  # How long `:joining` waits before calling it. Association takes a second
  # or two and DHCP is the rest; thirty seconds is long enough that reaching
  # it means something is wrong rather than slow.
  @join_timeout_ms 30_000

  # -- the app protocol the Launcher uses --------------------------------------

  @doc """
  Start the app. Idempotent: picking the row again while it is running shows
  the same process rather than starting a second one.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    case DynamicSupervisor.start_child(@sessions, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop the app."
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@sessions, pid)
    end
  end

  @doc """
  Forward an evdev report from the Launcher.

  A call rather than a cast, so that a test which has just synthesised a
  press can read the snapshot it produced -- the same reason
  `MayonnaiOS.Pairing.Cursor.input/1` is one. Nothing here does I/O on the
  radio that a person is waiting on: `join/3` and `forget/2` are a message to
  `vintage_net` and a return.
  """
  @spec input([tuple()]) :: :ok
  def input(events) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:input, events}), else: :ok
  end

  @doc "The scene the launcher shows while this app has the buttons."
  @spec scene() :: module()
  def scene, do: MayonnaiOS.Scene.WiFi

  @doc """
  Whether B belongs to this app right now.

  True while an overlay is up -- the passphrase wheel, or a row armed for
  forgetting -- and false otherwise, so the one button cancels what is up and
  then leaves. `MayonnaiOS.Launcher` asks on every report, which is what makes
  a per-state answer work at all.
  """
  @spec claims_back?() :: boolean()
  def claims_back? do
    case snapshot() do
      %{status: :editing} -> true
      %{armed?: true} -> true
      _otherwise -> false
    end
  end

  @doc """
  Be told when the state changes, as `{:wifi_app, snapshot}`.

  Same arrangement as `MayonnaiOS.Update.App.watch/1`: the scene calls this
  instead of polling, and the watcher is monitored so a scene torn down by
  `set_root/3` drops itself.
  """
  @spec watch(pid()) :: map() | :stopped
  def watch(pid) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:watch, pid}), else: :stopped
  end

  @doc "Everything the panel needs, as one map. `:stopped` if not running."
  @spec snapshot() :: map() | :stopped
  def snapshot do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :snapshot), else: :stopped
  end

  @doc "The DynamicSupervisor the app runs under, for the application tree."
  @spec sessions() :: Supervisor.child_spec()
  def sessions do
    %{
      id: @sessions,
      start: {DynamicSupervisor, :start_link, [[name: @sessions, strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Temporary, like the other app sessions: whatever went wrong is in the
      # log, and a restart would land on a screen the user already left.
      restart: :temporary
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -- state ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    wifi_opts = Keyword.get(opts, :wifi_opts, [])

    state = %{
      status: :listing,
      networks: [],
      connection: %{state: nil, ssid: nil, address: nil, error: nil},
      cursor: 0,
      editor: nil,
      target: nil,
      error: nil,
      armed?: false,
      available?: WiFi.available?(wifi_opts),
      scan_error: nil,
      deadline: nil,
      wifi_opts: wifi_opts,
      refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms),
      scan_ms: Keyword.get(opts, :scan_ms, @scan_ms),
      join_timeout_ms: Keyword.get(opts, :join_timeout_ms, @join_timeout_ms),
      watchers: []
    }

    WiFi.subscribe(wifi_opts)

    state = state |> request_scan() |> reread()

    schedule(:refresh, state.refresh_ms)
    schedule(:rescan, state.scan_ms)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  def handle_call({:watch, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, snapshot_of(state), %{state | watchers: [pid | state.watchers]}}
  end

  def handle_call({:input, events}, _from, state) do
    {:reply, :ok, state |> apply_events(events) |> notify(state)}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    schedule(:refresh, state.refresh_ms)
    {:noreply, state |> reread() |> notify(state)}
  end

  def handle_info(:rescan, state) do
    schedule(:rescan, state.scan_ms)
    {:noreply, state |> request_scan() |> notify(state)}
  end

  # The join deadline. Only bites while still joining the network it was set
  # for: a later join has its own, and one that already landed has none.
  def handle_info({:join_deadline, ssid}, %{status: :joining, target: %{ssid: ssid}} = state) do
    Logger.info("[wifi] gave up waiting for #{inspect(ssid)}")
    state = %{state | status: :failed, error: :timed_out, deadline: nil}
    {:noreply, notify(state, nil)}
  end

  def handle_info({:join_deadline, _ssid}, state), do: {:noreply, state}

  # The connection state changed. Read as a fresh reading of the whole
  # connection, because the SSID and the address move with it and reading one
  # property out of three would put the screen half a step behind itself.
  def handle_info({VintageNet, [_, _ifname, "connection"], _old, _new, _meta}, state) do
    {:noreply, state |> reread() |> settle() |> notify(state)}
  end

  # A supplicant control event. The one this app acts on is a passphrase the
  # access point refused; see `MayonnaiOS.WiFi.wrong_key?/2`.
  def handle_info({VintageNet, [_, _ifname, "wifi", "event"], _old, event, _meta}, state) do
    {:noreply, state |> event(event) |> notify(state)}
  end

  def handle_info({VintageNet, _property, _old, _new, _meta}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | watchers: List.delete(state.watchers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- reading the radio ------------------------------------------------------

  defp reread(state) do
    %{
      state
      | networks: WiFi.list(state.wifi_opts),
        connection: WiFi.connection(state.wifi_opts)
    }
    |> settle()
  end

  defp request_scan(state) do
    case WiFi.scan(state.wifi_opts) do
      :ok -> %{state | scan_error: nil}
      {:error, reason} -> %{state | scan_error: reason}
    end
  end

  # A join is over when the radio says it is on the network. Checked wherever
  # a fresh reading arrives rather than only on the subscription, because the
  # connection property can settle between two messages and a screen that
  # only believed the message would sit on "joining" next to a working
  # network.
  defp settle(%{status: :joining, target: %{ssid: ssid}} = state) do
    if WiFi.joined?(state.connection, ssid) do
      Logger.info("[wifi] joined #{inspect(ssid)}")
      %{state | status: :joined, error: nil, deadline: nil}
    else
      state
    end
  end

  defp settle(state), do: state

  defp event(%{status: :joining, target: %{ssid: ssid}} = state, event) do
    if WiFi.wrong_key?(event, ssid) do
      Logger.info("[wifi] #{inspect(ssid)} refused the passphrase; withdrawing it")
      WiFi.forget(ssid, state.wifi_opts)
      %{state | status: :failed, error: :wrong_key, deadline: nil}
    else
      state
    end
  end

  defp event(state, _event), do: state

  # -- input ------------------------------------------------------------------

  defp apply_events(state, events) do
    Enum.reduce(events, state, fn
      # Value 1 is a press. 2 is autorepeat and is dropped, as it is in the
      # launcher and in `MayonnaiOS.Pairing.Cursor`: every press here is a
      # scene rebuild, and holding a direction would queue one per repeat.
      {:ev_key, key, 1}, acc -> press(acc, key)
      _event, acc -> acc
    end)
  end

  # Menu is the launcher's way out and never means anything here.
  defp press(state, @menu), do: state

  defp press(%{status: :editing} = state, key) do
    case semantic(key) do
      nil -> state
      button -> edit(state, button)
    end
  end

  # The two screens that are just a sentence and a way back. A returns to the
  # list; B is claimed by nobody here, so it leaves the app.
  defp press(%{status: status} = state, @a) when status in [:joined, :failed] do
    %{state | status: :listing, error: nil, target: nil, armed?: false}
  end

  defp press(%{status: status} = state, _key) when status in [:joined, :failed, :joining] do
    state
  end

  defp press(state, @up), do: move(state, -1)
  defp press(state, @down), do: move(state, +1)
  defp press(state, @a), do: activate(state)
  defp press(state, @x), do: repass(state)
  defp press(state, @y), do: forget(state)

  # B while a row is armed takes the question down, and is swallowed rather
  # than also leaving -- the browser's rule for its delete confirmation. With
  # nothing armed `claims_back?/0` is false and this is never reached.
  defp press(%{armed?: true} = state, @b), do: %{state | armed?: false}

  defp press(state, _key), do: state

  # Moving disarms. Anything else leaves the arming alone, because a
  # confirmation cancelled by a button that does nothing else is a
  # confirmation someone loses to a twitch.
  defp move(state, delta) do
    case length(state.networks) do
      0 -> %{state | cursor: 0, armed?: false}
      count -> %{state | cursor: Integer.mod(state.cursor + delta, count), armed?: false}
    end
  end

  # A: join the selected network.
  defp activate(state) do
    case selected(state) do
      nil ->
        state

      # Already on it. There is nothing for A to do and nothing for it to
      # say; the footer offers Y.
      %{connected?: true} ->
        %{state | armed?: false}

      # Saved already, so the passphrase is in the configuration and this is
      # a switch rather than a join: move it to the head of the list and let
      # the supplicant re-associate.
      %{saved?: true} = network ->
        start_join(state, network, fn -> WiFi.prefer(network.ssid, state.wifi_opts) end)

      network ->
        cond do
          not WiFi.joinable?(network) ->
            %{state | status: :failed, error: refusal(network), target: network}

          WiFi.needs_passphrase?(network) ->
            %{
              state
              | status: :editing,
                editor: Editor.new(network.ssid),
                target: network,
                armed?: false
            }

          true ->
            start_join(state, network, fn -> WiFi.join(network, "", state.wifi_opts) end)
        end
    end
  end

  # X: retype the passphrase of a saved network. The one repair the list
  # cannot otherwise make -- a network saved with the wrong passphrase is
  # otherwise a row that can only be forgotten and re-added.
  defp repass(state) do
    case selected(state) do
      %{saved?: true, ssid: ssid} = network ->
        if WiFi.needs_passphrase?(network) or network.security == :unknown do
          # A saved network that is not on the air has no flags to classify,
          # so it is treated as secured: retyping a passphrase for one that
          # turns out to be open is refused by `WiFi.join/3` with a reason
          # the screen prints, which is better than no way in at all.
          %{
            state
            | status: :editing,
              editor: Editor.new(ssid),
              target: secured(network),
              armed?: false
          }
        else
          state
        end

      _otherwise ->
        state
    end
  end

  # Y, twice: the first press arms the row and the second forgets it.
  defp forget(%{armed?: true} = state) do
    case selected(state) do
      %{saved?: true, ssid: ssid} ->
        case WiFi.forget(ssid, state.wifi_opts) do
          :ok ->
            # The cursor stays where it is rather than following the row that
            # has just gone: the list is one shorter, so what is under the
            # cursor is what was below it, which is what a shrinking list
            # does everywhere else in this UI.
            %{state | armed?: false} |> reread()

          {:error, reason} ->
            %{state | armed?: false, status: :failed, error: {:forget_failed, reason}}
        end

      _otherwise ->
        %{state | armed?: false}
    end
  end

  defp forget(state) do
    case selected(state) do
      %{saved?: true} -> %{state | armed?: true}
      _otherwise -> state
    end
  end

  defp edit(state, button) do
    case Editor.input(state.editor, button) do
      {:editing, editor} ->
        %{state | editor: editor}

      :cancelled ->
        %{state | status: :listing, editor: nil, target: nil}

      {:done, passphrase} ->
        target = state.target

        start_join(%{state | editor: nil}, target, fn ->
          WiFi.join(target, passphrase, state.wifi_opts)
        end)
    end
  end

  # Write the configuration and start waiting. A refusal is immediate and
  # never enters `:joining`, so the screen never waits thirty seconds for
  # something that was rejected before the radio was touched.
  defp start_join(state, network, write) do
    case write.() do
      :ok ->
        deadline =
          Process.send_after(self(), {:join_deadline, network.ssid}, state.join_timeout_ms)

        %{
          state
          | status: :joining,
            target: network,
            error: nil,
            armed?: false,
            deadline: deadline
        }
        # The radio may already be on this network -- re-preferring the one
        # that is connected is a no-op to the supplicant -- so the state is
        # settled once here rather than only when a property changes.
        |> reread()

      {:error, reason} ->
        %{state | status: :failed, target: network, error: reason, armed?: false}
    end
  end

  defp selected(%{networks: []}), do: nil

  defp selected(%{networks: networks, cursor: cursor}) do
    Enum.at(networks, Integer.mod(cursor, length(networks)))
  end

  # A saved network off the air carries no flags, so nothing can say which of
  # the two secured schemes it wants. WPA-PSK is the one every home router
  # this device will meet uses, and the wrong guess is a join that fails with
  # a reason on the panel rather than a screen with no button.
  defp secured(%{security: :unknown} = network), do: %{network | security: :wpa_psk}
  defp secured(network), do: network

  defp refusal(%{security: :eap}), do: :eap_unsupported
  defp refusal(%{security: :wep}), do: :wep_unsupported
  defp refusal(_network), do: :unknown_security

  defp semantic(@up), do: :up
  defp semantic(@down), do: :down
  defp semantic(@left), do: :left
  defp semantic(@right), do: :right
  defp semantic(@l1), do: :l1
  defp semantic(@r1), do: :r1
  defp semantic(@a), do: :a
  defp semantic(@b), do: :b
  defp semantic(@x), do: :x
  defp semantic(@y), do: :y
  defp semantic(_key), do: nil

  # -- the snapshot the scene draws -------------------------------------------

  defp snapshot_of(state) do
    %{
      status: state.status,
      networks: state.networks,
      connection: state.connection,
      # Bounded here rather than trusted: the list is re-read every second
      # and a network that has gone off the air would otherwise leave the
      # cursor pointing past the end.
      cursor: bounded(state.cursor, length(state.networks)),
      selected: selected(state),
      editor: state.editor,
      target: state.target,
      error: state.error,
      armed?: state.armed?,
      available?: state.available?,
      scan_error: state.scan_error,
      passphrase_bounds: WiFi.passphrase_bounds()
    }
  end

  defp bounded(_cursor, 0), do: 0
  defp bounded(cursor, count), do: Integer.mod(cursor, count)

  defp notify(state, previous) do
    if previous != nil and snapshot_of(state) == snapshot_of(previous) do
      state
    else
      snapshot = snapshot_of(state)
      Enum.each(state.watchers, &send(&1, {:wifi_app, snapshot}))
      state
    end
  end

  defp schedule(message, after_ms), do: Process.send_after(self(), message, after_ms)
end
