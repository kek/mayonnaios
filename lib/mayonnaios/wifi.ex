defmodule MayonnaiOS.WiFi do
  @moduledoc """
  The WiFi mechanism behind the settings screen: what is on the air, what
  this device is configured to join, and the two verbs that change it.

      iex> MayonnaiOS.WiFi.scan()
      iex> MayonnaiOS.WiFi.list()
      iex> MayonnaiOS.WiFi.join(%{ssid: "kitchen", security: :wpa_psk}, "a passphrase")
      iex> MayonnaiOS.WiFi.forget("kitchen")

  `MayonnaiOS.WiFi.App` drives all of it from the panel;
  `MayonnaiOS.Scene.WiFi` draws it. This module is the only thing here that
  talks to `VintageNet`.

  ## Joining never replaces the network that already works

  This device's only reliable way in is WiFi -- the USB-C gadget has not been
  seen enumerating and UART0 is on internal test pads -- so a settings screen
  that can leave the radio pointed at one wrong network is a settings screen
  that can cost a card reflash. `config/target.exs` says the same thing about
  build-time credentials, and this module is the one place a *person holding
  the device* can point the radio somewhere new.

  So `join/3` appends rather than overwrites. `wpa_supplicant` holds a list of
  networks and associates with whichever of them is in range, so the network
  that got the device onto the workbench survives every join made here, and a
  passphrase picked wrong on a 95-character wheel costs one walk back into
  range rather than the card.

  What a join does change is *preference*: the newly joined network is put at
  the head of the list and the whole list is renumbered by position, so
  `:priority` descends the way the screen reads. The most recently chosen
  network wins wherever two are in range, which is the only ordering anyone
  would guess from having just chosen one.

  ## A wrong passphrase is a thing wpa_supplicant says out loud

  `vintage_net_wifi` republishes the supplicant's own control events on
  `["interface", "wlan0", "wifi", "event"]`, and a passphrase the AP rejects
  arrives there as `CTRL-EVENT-SSID-TEMP-DISABLED` with
  `reason: "WRONG_KEY"`. That is a fact rather than an inference from a
  timeout, which is why `MayonnaiOS.WiFi.App` waits for it: "could not
  connect" and "you typed it wrong" are different sentences and only one of
  them tells anyone what to do next.

  It is also why a rejected passphrase is withdrawn from the configuration
  again. A network known to be wrong is one `wpa_supplicant` keeps retrying
  and temporarily disabling, and the retries are association attempts that
  interrupt the network that does work. Not-knowing is treated differently: a
  join that simply never completes stays configured, because DHCP on a slow
  router outlasts any deadline worth putting on a panel.

  ## Enterprise and WEP are refused rather than half-offered

  `security/1` classifies what an access point advertises, and `joinable?/1`
  answers for two of the five with a no:

    * **802.1X / enterprise** needs an identity, a CA certificate and an
      inner method. None of that is a passphrase, and none of it can be
      picked from a character wheel.
    * **WEP** needs a hex or ASCII key in one of four slots, and nothing on
      this device has ever associated with a WEP AP to say the plumbing
      works.

  Both appear on the screen with what they need written on the row, on the
  same reasoning as the Bluetooth screen's headphone notice -- see
  `MayonnaiOS.Pairing`. A row that accepts a passphrase and then fails is
  worse than a row that says it cannot.

  ## Every read and write is injectable

  The same seam as `MayonnaiOS.SystemInfo` and for a stronger reason:
  `VintageNet` is a target-only dependency, so on a development laptop the
  module is not loaded at all. Every function here takes an options keyword
  whose defaults are the real calls, so the merging, sorting, classifying and
  configuration-rewriting are all testable on a machine with no radio -- and
  on that machine the defaults answer `{:error, :unavailable}` rather than
  raising, which is a state the panel draws.
  """

  require Logger

  @interface "wlan0"

  # WPA-PSK's own bounds, from IEEE 802.11i: a passphrase is 8 to 63
  # printable ASCII characters. Checked here rather than left to
  # wpa_supplicant, because on a character wheel a rejection that arrives
  # after the configuration round-trip is a rejection that arrives two
  # minutes after the mistake.
  @psk_min 8
  @psk_max 63

  @typedoc "What an access point's flags say it wants."
  @type security :: :open | :wpa_psk | :sae | :wep | :eap

  @typedoc """
  One row of the settings screen.

  `signal` is nil for a saved network that is not currently on the air --
  which is a row worth drawing, because forgetting a network is something
  people do from somewhere else in the house.
  """
  @type network :: %{
          ssid: String.t(),
          security: security(),
          signal: 0..100 | nil,
          saved?: boolean(),
          connected?: boolean(),
          in_range?: boolean()
        }

  @typedoc "Where the radio has got to."
  @type connection :: %{
          state: :internet | :lan | :disconnected | nil,
          ssid: String.t() | nil,
          address: String.t() | nil,
          error: term() | nil
        }

  @doc "The interface this device's radio is on."
  @spec interface() :: String.t()
  def interface, do: @interface

  # -- reading ----------------------------------------------------------------

  @doc """
  Whether there is a radio to talk to at all.

  False on a development laptop, where `VintageNet` is not in the release.
  The screen draws that as a state rather than an error: the UI is worth
  looking at on a host, and "no radio here" is the honest thing for it to
  say.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    Keyword.get(opts, :available?, &vintage_net_loaded?/0).()
  end

  @doc """
  Ask the radio for a fresh scan.

  Asynchronous: results land on the access-points property a second or two
  later, which is why `MayonnaiOS.WiFi.App` calls this on a timer and reads
  `list/1` on its own clock rather than waiting for anything.
  """
  @spec scan(keyword()) :: :ok | {:error, term()}
  def scan(opts \\ []) do
    case Keyword.get(opts, :scan, &do_scan/0).() do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc """
  Where the radio has got to: the connection state, the SSID it is on, and
  the address it was given.

  The address comes from the kernel's own interface list rather than from a
  `VintageNet` property, because that read works on a laptop too and this is
  the one line of the screen worth having there.
  """
  @spec connection(keyword()) :: connection()
  def connection(opts \\ []) do
    %{
      state: Keyword.get(opts, :connection_state, &read_connection_state/0).(),
      ssid: Keyword.get(opts, :current_ssid, &read_current_ssid/0).(),
      address: Keyword.get(opts, :address, &read_address/0).(),
      error: nil
    }
  end

  @doc """
  Every network worth a row: what is on the air, plus what is saved and is
  not.

  Ordered by signal, strongest first, with the saved-but-absent networks
  after them. Not by "connected first" or "saved first": the list is being
  read by someone looking for a name they can see on a router in front of
  them, and a list that reorders itself as the radio wanders between two
  access points is a list whose rows move under the cursor.
  """
  @spec list(keyword()) :: [network()]
  def list(opts \\ []) do
    access_points = Keyword.get(opts, :access_points, &read_access_points/0).()
    saved = Keyword.get(opts, :saved, fn -> saved_ssids(opts) end).()
    current = Keyword.get(opts, :current_ssid, &read_current_ssid/0).()

    merge(access_points, saved, current)
  end

  @doc """
  The SSIDs this device is configured to join, in preference order.

  Read out of the live configuration rather than remembered, so a network
  added over SSH shows up here the same as one added from the panel.
  """
  @spec saved_ssids(keyword()) :: [String.t()]
  def saved_ssids(opts \\ []) do
    opts
    |> configuration()
    |> networks_of()
    |> Enum.map(&Map.get(&1, :ssid))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  @doc """
  Subscribe to the two properties the app watches: the connection state, and
  the supplicant's own events.

  Messages arrive as `VintageNet`'s own
  `{VintageNet, property, old, new, meta}`, which is the shape
  `MayonnaiOS.Status` already handles -- see that module for why a
  subscription is not enough on its own and this app polls as well.
  """
  @spec subscribe(keyword()) :: :ok
  def subscribe(opts \\ []) do
    Keyword.get(opts, :subscribe, &do_subscribe/0).()
  end

  # -- writing ----------------------------------------------------------------

  @doc """
  Join a network, keeping every network already configured.

  Takes the row the cursor is on rather than an SSID and a security atom
  separately, because the row is what the screen has and splitting it would
  let the two drift apart. The passphrase is ignored for an open network.

  Errors, all of them before the radio is touched except the last:

    * `{:error, :eap_unsupported}` and `{:error, :wep_unsupported}` -- see
      the moduledoc
    * `{:error, :passphrase_too_short}` / `{:error, :passphrase_too_long}`
    * `{:error, :unavailable}` -- no radio on this machine
    * whatever `VintageNet.configure/3` refuses with
  """
  @spec join(network() | map(), String.t(), keyword()) :: :ok | {:error, term()}
  def join(network, passphrase, opts \\ []) do
    with {:ok, entry} <- network_config(network, passphrase),
         config when is_map(config) <- configuration(opts) do
      Logger.info("[wifi] joining #{inspect(entry.ssid)} as #{entry.key_mgmt}")
      configure(with_network(config, entry), opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :unavailable}
    end
  end

  @doc """
  Make a network already in the configuration the preferred one.

  What A does on a saved row: the passphrase is already there, so this is a
  switch between two known networks rather than a join, and it must not
  require retyping anything. The entry is carried across untouched -- whatever
  it holds, including a PSK entered over SSH -- and only its position, and so
  its priority, changes.
  """
  @spec prefer(String.t(), keyword()) :: :ok | {:error, term()}
  def prefer(ssid, opts \\ []) do
    case configuration(opts) do
      config when is_map(config) ->
        case Enum.find(networks_of(config), &(Map.get(&1, :ssid) == ssid)) do
          nil ->
            {:error, :not_saved}

          entry ->
            Logger.info("[wifi] preferring #{inspect(ssid)}")
            configure(with_network(config, entry), opts)
        end

      _absent ->
        {:error, :unavailable}
    end
  end

  @doc """
  Drop a network from the configuration.

  Persisted, so it stays dropped across the power cut this device is switched
  off by. Forgetting the network currently associated is allowed and
  disconnects it -- that is what forgetting means, and refusing would leave
  the one network nobody can remove being the one they are standing next to.
  """
  @spec forget(String.t(), keyword()) :: :ok | {:error, term()}
  def forget(ssid, opts \\ []) do
    case configuration(opts) do
      config when is_map(config) ->
        Logger.info("[wifi] forgetting #{inspect(ssid)}")
        configure(without_network(config, ssid), opts)

      _absent ->
        {:error, :unavailable}
    end
  end

  # -- the pure half, which is where the tests are ----------------------------

  @doc """
  Build the screen's rows from an access-point reading, the saved SSIDs, and
  whatever is currently associated.

  Access points arrive keyed by BSSID, so one network behind two radios --
  a mesh, a repeater, a router doing 2.4 and 5 GHz under one name -- is two
  entries. They collapse to one row on the strongest, because two rows with
  the same name and different signal is a list nobody can act on.
  """
  @spec merge(map() | [map()], [String.t()], String.t() | nil) :: [network()]
  def merge(access_points, saved, current) do
    on_air =
      access_points
      |> points()
      # A hidden network beacons an empty SSID. There is nothing to select
      # and no way to type the real name in, so it is not a row.
      |> Enum.reject(&(Map.get(&1, :ssid) in [nil, ""]))
      |> Enum.group_by(&Map.get(&1, :ssid))
      |> Enum.map(fn {ssid, points} -> strongest(ssid, points, saved, current) end)
      |> Enum.sort_by(&{-(&1.signal || 0), &1.ssid})

    absent =
      saved
      |> Enum.reject(fn ssid -> Enum.any?(on_air, &(&1.ssid == ssid)) end)
      |> Enum.map(fn ssid ->
        %{
          ssid: ssid,
          # Nothing is on the air to read flags from. The security a saved
          # network was joined with is in the configuration, but it is the
          # one field on this row nobody can act on -- the row exists to be
          # forgotten -- so it is not guessed at.
          security: :unknown,
          signal: nil,
          saved?: true,
          connected?: ssid == current,
          in_range?: false
        }
      end)
      |> Enum.sort_by(& &1.ssid)

    on_air ++ absent
  end

  @doc """
  What an access point's flags say it wants.

  Read in the order that decides it: enterprise before PSK, because an
  enterprise AP also advertises the ciphers a PSK one does; SAE only when
  PSK is absent, because a WPA2/WPA3 transitional AP advertises both and the
  WPA2 path is the one this radio has actually associated over.
  """
  @spec security([atom()]) :: security()
  def security(flags) do
    flags = List.wrap(flags)

    cond do
      :eap in flags -> :eap
      Enum.any?(flags, &eap_flag?/1) -> :eap
      :sae in flags and not Enum.any?(flags, &psk_flag?/1) -> :sae
      Enum.any?(flags, &psk_flag?/1) -> :wpa_psk
      :wep in flags -> :wep
      true -> :open
    end
  end

  @doc "Whether A on this row can lead anywhere. See the moduledoc."
  @spec joinable?(network() | map()) :: boolean()
  def joinable?(%{security: security}), do: security not in [:eap, :wep, :unknown]
  def joinable?(_network), do: false

  @doc "Whether joining this row needs a passphrase picked first."
  @spec needs_passphrase?(network() | map()) :: boolean()
  def needs_passphrase?(%{security: security}), do: security in [:wpa_psk, :sae]
  def needs_passphrase?(_network), do: false

  @doc """
  The `vintage_net_wifi` network entry for a row and a passphrase, or why
  there is not one.

  SAE takes the passphrase under `:psk` too -- `vintage_net_wifi` moves it to
  `:sae_password` itself -- so the two secured paths differ only in
  `:key_mgmt` and this function has one shape for both.
  """
  @spec network_config(network() | map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def network_config(network, passphrase)

  def network_config(%{security: :eap}, _passphrase), do: {:error, :eap_unsupported}
  def network_config(%{security: :wep}, _passphrase), do: {:error, :wep_unsupported}
  def network_config(%{security: :unknown}, _passphrase), do: {:error, :unknown_security}

  def network_config(%{ssid: ssid, security: :open}, _passphrase) when is_binary(ssid) do
    {:ok, %{ssid: ssid, key_mgmt: :none}}
  end

  def network_config(%{ssid: ssid, security: security}, passphrase)
      when is_binary(ssid) and security in [:wpa_psk, :sae] and is_binary(passphrase) do
    case String.length(passphrase) do
      length when length < @psk_min -> {:error, :passphrase_too_short}
      length when length > @psk_max -> {:error, :passphrase_too_long}
      _ok -> {:ok, %{ssid: ssid, key_mgmt: security, psk: passphrase}}
    end
  end

  def network_config(_network, _passphrase), do: {:error, :not_a_network}

  @doc """
  Put a network at the head of a configuration's list, renumbering
  priorities so the list order is the preference order.

  Everything else in the configuration -- the type, the IPv4 method, any
  root-level supplicant options -- is carried through untouched. This
  function edits one list inside a map it does not otherwise understand,
  which is what keeps a join from silently dropping a setting made over SSH.
  """
  @spec with_network(map(), map()) :: map()
  def with_network(config, entry) do
    kept = Enum.reject(networks_of(config), &(Map.get(&1, :ssid) == entry.ssid))
    put_networks(config, prioritise([entry | kept]))
  end

  @doc "Take a network out of a configuration, renumbering what is left."
  @spec without_network(map(), String.t()) :: map()
  def without_network(config, ssid) do
    kept = Enum.reject(networks_of(config), &(Map.get(&1, :ssid) == ssid))
    put_networks(config, prioritise(kept))
  end

  @doc """
  The networks in a configuration, whatever shape it is in.

  A configuration with no WiFi section at all -- an interface configured as
  something else, or a host's empty answer -- has no networks rather than
  being an error, because both callers here go on to write a list into it
  either way.
  """
  @spec networks_of(map() | nil) :: [map()]
  def networks_of(%{vintage_net_wifi: %{networks: networks}}) when is_list(networks), do: networks
  def networks_of(_config), do: []

  @doc """
  Whether a supplicant event says a passphrase was rejected for this SSID.

  Two events mean it. `CTRL-EVENT-SSID-TEMP-DISABLED` carries
  `reason: "WRONG_KEY"`, which is the supplicant saying so in as many words.
  `CTRL-EVENT-ASSOC-REJECT` is broader -- a full AP and a MAC filter reject
  too -- so it counts only against the SSID being joined, where it is the
  overwhelmingly likely reading and the alternative is a screen that says
  "connecting" until someone gives up.
  """
  @spec wrong_key?(map() | nil, String.t()) :: boolean()
  def wrong_key?(event, ssid)

  def wrong_key?(%{name: "CTRL-EVENT-SSID-TEMP-DISABLED"} = event, ssid) do
    reason = to_string(Map.get(event, :reason) || "")
    event_ssid = Map.get(event, :ssid)

    String.upcase(reason) == "WRONG_KEY" and (event_ssid in [nil, ""] or event_ssid == ssid)
  end

  def wrong_key?(%{name: "CTRL-EVENT-ASSOC-REJECT"} = event, ssid) do
    Map.get(event, :ssid) == ssid
  end

  def wrong_key?(_event, _ssid), do: false

  @doc """
  Whether a connection reading counts as being on the network just joined.

  `:lan` rather than `:internet`, because association and a DHCP lease are
  what a join is responsible for -- a router with no uplink is a successful
  join and a separate problem, and a screen that called it a failure would
  send someone to re-pick a passphrase that was right.
  """
  @spec joined?(connection(), String.t()) :: boolean()
  def joined?(%{state: state, ssid: ssid}, target) do
    state in [:lan, :internet] and (ssid == target or is_nil(ssid))
  end

  def joined?(_connection, _target), do: false

  @doc "The passphrase length WPA-PSK accepts, as `{min, max}`."
  @spec passphrase_bounds() :: {pos_integer(), pos_integer()}
  def passphrase_bounds, do: {@psk_min, @psk_max}

  # -- putting the two halves together ----------------------------------------

  defp strongest(ssid, points, saved, current) do
    point = Enum.max_by(points, &(Map.get(&1, :signal_percent) || 0))

    %{
      ssid: ssid,
      security: security(Map.get(point, :flags)),
      signal: Map.get(point, :signal_percent),
      saved?: ssid in saved,
      connected?: ssid == current,
      in_range?: true
    }
  end

  # The access-points property is a map keyed by BSSID. A list is accepted
  # too, because that is the shape a test writes and neither this module nor
  # the screen cares which it got.
  defp points(access_points) when is_map(access_points), do: Map.values(access_points)
  defp points(access_points) when is_list(access_points), do: access_points
  defp points(_access_points), do: []

  # Highest number wins in wpa_supplicant, so the head of the list gets the
  # count and the tail gets 1.
  defp prioritise(networks) do
    count = length(networks)

    networks
    |> Enum.with_index()
    |> Enum.map(fn {network, index} -> Map.put(network, :priority, count - index) end)
  end

  defp put_networks(config, networks) do
    wifi = config |> Map.get(:vintage_net_wifi, %{}) |> Map.put(:networks, networks)
    Map.put(config, :vintage_net_wifi, wifi)
  end

  defp psk_flag?(flag) do
    flag == :psk or (is_atom(flag) and String.contains?(Atom.to_string(flag), "psk"))
  end

  defp eap_flag?(flag) do
    flag == :eap or (is_atom(flag) and String.contains?(Atom.to_string(flag), "eap"))
  end

  defp configuration(opts) do
    Keyword.get(opts, :configuration, &read_configuration/0).()
  end

  defp configure(config, opts) do
    Keyword.get(opts, :configure, &write_configuration/1).(config)
  end

  # -- the VintageNet calls, and the one guard in front of all of them --------

  # VintageNet is a target-only dependency, so on a development laptop the
  # module is not there to call. The same test `MayonnaiOS.Status` makes, for
  # the same reason: the screen renders "no radio" rather than the VM
  # crashing on an undefined function.
  defp vintage_net_loaded?, do: Code.ensure_loaded?(VintageNet)

  defp do_scan do
    if vintage_net_loaded?() do
      apply(VintageNet, :scan, [@interface])
    else
      {:error, :unavailable}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp do_subscribe do
    if vintage_net_loaded?() do
      apply(VintageNet, :subscribe, [["interface", @interface, "connection"]])
      apply(VintageNet, :subscribe, [["interface", @interface, "wifi", "event"]])
    end

    :ok
  rescue
    error ->
      Logger.warning("[wifi] subscribe failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[wifi] subscribe failed: #{inspect(reason)}")
      :ok
  end

  defp read_connection_state, do: property(["interface", @interface, "connection"])

  defp read_access_points, do: property(["interface", @interface, "wifi", "access_points"]) || %{}

  defp read_current_ssid do
    case property(["interface", @interface, "wifi", "current_ap"]) do
      %{ssid: ssid} when is_binary(ssid) and ssid != "" -> ssid
      _absent -> nil
    end
  end

  defp read_configuration do
    if vintage_net_loaded?() do
      apply(VintageNet, :get_configuration, [@interface])
    end
  rescue
    # get_configuration/1 raises when the interface has no configuration at
    # all, which on this device means vintage_net is up and wlan0 is not
    # something it manages. Nothing to merge into, and nil is what the
    # callers read as "no radio to configure".
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp write_configuration(config) do
    if vintage_net_loaded?() do
      # Persisted, which is the default and is the whole point: a network
      # chosen on the panel has to survive the power being pulled.
      apply(VintageNet, :configure, [@interface, config])
    else
      {:error, :unavailable}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  # An ETS read of a table the vintage_net application owns, so it answers
  # without a message -- but it is not there to read on a host, and it is
  # gone for a moment if that application restarts.
  defp property(path) do
    if vintage_net_loaded?() do
      apply(VintageNet, :get, [path])
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # The kernel's own interface list, which works on a host too. The first
  # non-loopback IPv4 on the WiFi interface; anything else on the machine is
  # not what this screen is about.
  defp read_address do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        Enum.find_value(interfaces, fn {name, props} ->
          if List.to_string(name) == @interface, do: first_inet4(props)
        end)

      {:error, _reason} ->
        nil
    end
  end

  defp first_inet4(props) do
    Enum.find_value(props, fn
      {:addr, {a, _b, _c, _d} = addr} when a != 127 ->
        addr |> :inet.ntoa() |> List.to_string()

      _other ->
        nil
    end)
  end
end
