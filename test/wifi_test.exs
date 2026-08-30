defmodule MayonnaiOS.WiFiTest do
  # Async: every read and write is an injected function, so nothing here
  # touches a radio, a property table or the application environment.
  use ExUnit.Case, async: true

  alias MayonnaiOS.WiFi

  # An access point in the shape the property table publishes, minus the
  # fields nothing here reads. A plain map rather than a
  # `VintageNetWiFi.AccessPoint` struct on purpose: that module is a
  # target-only dependency and does not exist on the machine this test runs
  # on, which is exactly the constraint `MayonnaiOS.WiFi` is built around.
  defp ap(ssid, opts \\ []) do
    %{
      bssid: Keyword.get(opts, :bssid, "aa:bb:cc:dd:ee:#{:rand.uniform(99)}"),
      ssid: ssid,
      signal_percent: Keyword.get(opts, :signal, 50),
      flags: Keyword.get(opts, :flags, [:psk, :ccmp, :wpa2])
    }
  end

  # A configuration in the shape `VintageNet.get_configuration/1` answers
  # with, carrying a network and an unrelated setting that must survive
  # every edit.
  defp config(networks) do
    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{networks: networks},
      ipv4: %{method: :dhcp}
    }
  end

  # Captures whatever a write is handed, so a test can assert on the
  # configuration that would have gone to the radio.
  defp recorder do
    parent = self()

    fn written ->
      send(parent, {:configured, written})
      :ok
    end
  end

  describe "security/1" do
    test "classifies what an access point advertises" do
      assert WiFi.security([]) == :open
      assert WiFi.security([:ess]) == :open
      assert WiFi.security([:psk, :ccmp, :wpa2]) == :wpa_psk
      assert WiFi.security([:sae, :ccmp, :rsn_ccmp]) == :sae
      assert WiFi.security([:wep]) == :wep
      assert WiFi.security([:eap, :ccmp, :wpa2]) == :eap
    end

    test "the old-style combined flags are classified too" do
      # vintage_net_wifi still reports these for compatibility, so a screen
      # that only knew the split flags would call an enterprise network open.
      assert WiFi.security([:wpa2_psk_ccmp]) == :wpa_psk
      assert WiFi.security([:wpa_psk_ccmp_tkip]) == :wpa_psk
      assert WiFi.security([:wpa2_eap_ccmp]) == :eap
      assert WiFi.security([:wpa_eap_ccmp_tkip]) == :eap
    end

    test "a transitional WPA2/WPA3 access point is joined over WPA2" do
      # Both flags are advertised, and the PSK path is the one this radio has
      # actually associated over. See the function's own comment.
      assert WiFi.security([:psk, :sae, :ccmp]) == :wpa_psk
    end

    test "enterprise wins over the ciphers it shares with a PSK network" do
      assert WiFi.security([:eap, :psk]) == :eap
    end
  end

  describe "merge/3" do
    test "orders by signal, strongest first" do
      points = [ap("weak", signal: 20), ap("strong", signal: 90), ap("middling", signal: 55)]

      assert Enum.map(WiFi.merge(points, [], nil), & &1.ssid) == ["strong", "middling", "weak"]
    end

    test "one network behind two radios is one row, on the stronger" do
      points = [
        ap("mesh", bssid: "a", signal: 30),
        ap("mesh", bssid: "b", signal: 80)
      ]

      assert [%{ssid: "mesh", signal: 80}] = WiFi.merge(points, [], nil)
    end

    test "a hidden network is not a row" do
      # There is nothing to select and no way to type the real name in.
      assert WiFi.merge([ap(""), ap(nil), ap("named")], [], nil) |> Enum.map(& &1.ssid) ==
               ["named"]
    end

    test "the property table's map is accepted as readily as a list" do
      points = %{"aa" => ap("kitchen", signal: 70), "bb" => ap("shed", signal: 10)}

      assert Enum.map(WiFi.merge(points, [], nil), & &1.ssid) == ["kitchen", "shed"]
    end

    test "saved and connected are marked on the rows they belong to" do
      points = [ap("home", signal: 80), ap("guest", signal: 40)]

      assert [home, guest] = WiFi.merge(points, ["home"], "home")

      assert home.saved? and home.connected? and home.in_range?
      refute guest.saved?
      refute guest.connected?
    end

    test "a saved network that is not on the air is still a row" do
      # Forgetting a network is something people do from somewhere else in
      # the house, so the row has to exist out of range.
      assert [on_air, absent] = WiFi.merge([ap("here", signal: 60)], ["here", "away"], nil)

      assert on_air.ssid == "here"
      assert absent.ssid == "away"
      assert absent.signal == nil
      refute absent.in_range?
      assert absent.saved?
      # Nothing is on the air to read flags from, and the security of a row
      # that exists to be forgotten is not guessed at.
      assert absent.security == :unknown
    end

    test "the absent rows come after everything on the air, alphabetically" do
      points = [ap("b", signal: 10)]

      assert Enum.map(WiFi.merge(points, ["z", "a"], nil), & &1.ssid) == ["b", "a", "z"]
    end
  end

  describe "joinable?/1 and needs_passphrase?/1" do
    test "the two kinds this screen refuses" do
      refute WiFi.joinable?(%{ssid: "corp", security: :eap})
      refute WiFi.joinable?(%{ssid: "old", security: :wep})
      refute WiFi.joinable?(%{ssid: "gone", security: :unknown})
    end

    test "the three it accepts" do
      assert WiFi.joinable?(%{ssid: "a", security: :open})
      assert WiFi.joinable?(%{ssid: "b", security: :wpa_psk})
      assert WiFi.joinable?(%{ssid: "c", security: :sae})
    end

    test "only the secured ones want a passphrase" do
      refute WiFi.needs_passphrase?(%{security: :open})
      assert WiFi.needs_passphrase?(%{security: :wpa_psk})
      assert WiFi.needs_passphrase?(%{security: :sae})
    end
  end

  describe "network_config/2" do
    test "an open network needs no passphrase" do
      assert {:ok, %{ssid: "cafe", key_mgmt: :none}} =
               WiFi.network_config(%{ssid: "cafe", security: :open}, "")
    end

    test "WPA-PSK carries the passphrase" do
      assert {:ok, entry} = WiFi.network_config(%{ssid: "home", security: :wpa_psk}, "hunter2!!")

      assert entry == %{ssid: "home", key_mgmt: :wpa_psk, psk: "hunter2!!"}
    end

    test "WPA3 differs only in key_mgmt" do
      # vintage_net_wifi moves :psk to :sae_password itself, so this module
      # has one shape for both secured schemes.
      assert {:ok, %{key_mgmt: :sae, psk: "hunter2!!"}} =
               WiFi.network_config(%{ssid: "new", security: :sae}, "hunter2!!")
    end

    test "the length bounds are checked here, not by wpa_supplicant" do
      network = %{ssid: "home", security: :wpa_psk}

      assert WiFi.network_config(network, "short") == {:error, :passphrase_too_short}

      assert WiFi.network_config(network, String.duplicate("x", 7)) ==
               {:error, :passphrase_too_short}

      assert WiFi.network_config(network, String.duplicate("x", 8)) |> elem(0) == :ok
      assert WiFi.network_config(network, String.duplicate("x", 63)) |> elem(0) == :ok

      assert WiFi.network_config(network, String.duplicate("x", 64)) ==
               {:error, :passphrase_too_long}
    end

    test "the refused kinds say which they are" do
      assert WiFi.network_config(%{ssid: "corp", security: :eap}, "x") ==
               {:error, :eap_unsupported}

      assert WiFi.network_config(%{ssid: "old", security: :wep}, "x") ==
               {:error, :wep_unsupported}

      assert WiFi.network_config(%{ssid: "gone", security: :unknown}, "x") ==
               {:error, :unknown_security}
    end
  end

  describe "with_network/2" do
    test "the new network goes to the head and the old ones stay" do
      # The property this device's only way in depends on: joining never
      # drops the network that already works.
      existing = %{ssid: "workbench", key_mgmt: :wpa_psk, psk: "buildtime"}
      entry = %{ssid: "kitchen", key_mgmt: :wpa_psk, psk: "new"}

      written = WiFi.with_network(config([existing]), entry)

      assert Enum.map(WiFi.networks_of(written), & &1.ssid) == ["kitchen", "workbench"]
      assert Enum.find(WiFi.networks_of(written), &(&1.ssid == "workbench")).psk == "buildtime"
    end

    test "priorities descend with the list, so the newest wins" do
      written =
        config([%{ssid: "a"}, %{ssid: "b"}])
        |> WiFi.with_network(%{ssid: "c"})

      assert Enum.map(WiFi.networks_of(written), &{&1.ssid, &1.priority}) ==
               [{"c", 3}, {"a", 2}, {"b", 1}]
    end

    test "rejoining a network replaces its entry rather than duplicating it" do
      written =
        config([%{ssid: "home", key_mgmt: :wpa_psk, psk: "old"}])
        |> WiFi.with_network(%{ssid: "home", key_mgmt: :wpa_psk, psk: "new"})

      assert [%{ssid: "home", psk: "new"}] = WiFi.networks_of(written)
    end

    test "everything else in the configuration is carried through untouched" do
      written = WiFi.with_network(config([]), %{ssid: "x"})

      assert written.type == VintageNetWiFi
      assert written.ipv4 == %{method: :dhcp}
    end

    test "a configuration with no WiFi section gets one" do
      written = WiFi.with_network(%{type: VintageNetWiFi}, %{ssid: "x"})

      assert Enum.map(WiFi.networks_of(written), & &1.ssid) == ["x"]
    end
  end

  describe "without_network/2" do
    test "removes one and renumbers what is left" do
      written = WiFi.without_network(config([%{ssid: "a"}, %{ssid: "b"}, %{ssid: "c"}]), "b")

      assert Enum.map(WiFi.networks_of(written), &{&1.ssid, &1.priority}) ==
               [{"a", 2}, {"c", 1}]
    end

    test "removing what is not there changes nothing but the priorities" do
      written = WiFi.without_network(config([%{ssid: "a"}]), "absent")

      assert Enum.map(WiFi.networks_of(written), & &1.ssid) == ["a"]
    end
  end

  describe "join/3" do
    test "writes a configuration that keeps the network already there" do
      existing = %{ssid: "workbench", key_mgmt: :wpa_psk, psk: "buildtime"}

      assert :ok =
               WiFi.join(%{ssid: "kitchen", security: :wpa_psk}, "hunter2!!",
                 configuration: fn -> config([existing]) end,
                 configure: recorder()
               )

      assert_received {:configured, written}
      assert Enum.map(WiFi.networks_of(written), & &1.ssid) == ["kitchen", "workbench"]
    end

    test "a refusal never reaches the radio" do
      never = fn _config -> flunk("the radio was configured for a refused join") end

      assert WiFi.join(%{ssid: "home", security: :wpa_psk}, "sixchr",
               configuration: fn -> config([]) end,
               configure: never
             ) == {:error, :passphrase_too_short}

      assert WiFi.join(%{ssid: "corp", security: :eap}, "whatever",
               configuration: fn -> config([]) end,
               configure: never
             ) == {:error, :eap_unsupported}
    end

    test "no radio to configure is an error rather than an exception" do
      assert WiFi.join(%{ssid: "home", security: :open}, "",
               configuration: fn -> nil end,
               configure: recorder()
             ) == {:error, :unavailable}

      refute_received {:configured, _written}
    end
  end

  describe "prefer/2" do
    test "moves a saved network to the head with its passphrase intact" do
      saved = [
        %{ssid: "workbench", key_mgmt: :wpa_psk, psk: "one"},
        %{ssid: "kitchen", key_mgmt: :wpa_psk, psk: "two"}
      ]

      assert :ok =
               WiFi.prefer("kitchen",
                 configuration: fn -> config(saved) end,
                 configure: recorder()
               )

      assert_received {:configured, written}
      networks = WiFi.networks_of(written)

      assert Enum.map(networks, & &1.ssid) == ["kitchen", "workbench"]
      # Switching networks must never mean retyping one.
      assert hd(networks).psk == "two"
    end

    test "a network that is not saved cannot be preferred" do
      assert WiFi.prefer("absent",
               configuration: fn -> config([%{ssid: "home"}]) end,
               configure: recorder()
             ) == {:error, :not_saved}

      refute_received {:configured, _written}
    end
  end

  describe "forget/2" do
    test "drops the network and leaves the rest" do
      assert :ok =
               WiFi.forget("kitchen",
                 configuration: fn -> config([%{ssid: "kitchen"}, %{ssid: "workbench"}]) end,
                 configure: recorder()
               )

      assert_received {:configured, written}
      assert Enum.map(WiFi.networks_of(written), & &1.ssid) == ["workbench"]
    end

    test "forgetting the last network leaves an empty list rather than no list" do
      assert :ok =
               WiFi.forget("only",
                 configuration: fn -> config([%{ssid: "only"}]) end,
                 configure: recorder()
               )

      assert_received {:configured, written}
      assert WiFi.networks_of(written) == []
      assert written.ipv4 == %{method: :dhcp}
    end
  end

  describe "wrong_key?/2" do
    test "the supplicant saying so in as many words" do
      event = %{
        name: "CTRL-EVENT-SSID-TEMP-DISABLED",
        ssid: "kitchen",
        reason: "WRONG_KEY",
        auth_failures: 1
      }

      assert WiFi.wrong_key?(event, "kitchen")
    end

    test "a temporary disable for another reason is not a wrong passphrase" do
      event = %{name: "CTRL-EVENT-SSID-TEMP-DISABLED", ssid: "kitchen", reason: "CONN_FAILED"}

      refute WiFi.wrong_key?(event, "kitchen")
    end

    test "an association reject counts only against the network being joined" do
      event = %{name: "CTRL-EVENT-ASSOC-REJECT", ssid: "kitchen", status_code: "1"}

      assert WiFi.wrong_key?(event, "kitchen")
      refute WiFi.wrong_key?(event, "shed")
    end

    test "anything else, and nothing at all, is not a verdict" do
      refute WiFi.wrong_key?(%{name: "CTRL-EVENT-CONNECTED"}, "kitchen")
      refute WiFi.wrong_key?(nil, "kitchen")
      refute WiFi.wrong_key?(%{}, "kitchen")
    end
  end

  describe "joined?/2" do
    test "a lease from the router is enough" do
      # :lan rather than :internet, because a router with no uplink is a
      # successful join and a separate problem.
      assert WiFi.joined?(%{state: :lan, ssid: "kitchen"}, "kitchen")
      assert WiFi.joined?(%{state: :internet, ssid: "kitchen"}, "kitchen")
    end

    test "being on a different network is not being on this one" do
      refute WiFi.joined?(%{state: :internet, ssid: "workbench"}, "kitchen")
    end

    test "disconnected is never joined" do
      refute WiFi.joined?(%{state: :disconnected, ssid: nil}, "kitchen")
      refute WiFi.joined?(%{state: nil, ssid: nil}, "kitchen")
    end

    test "an unreported SSID with a lease counts, because the alternative is waiting forever" do
      assert WiFi.joined?(%{state: :lan, ssid: nil}, "kitchen")
    end
  end

  describe "reading through the injected seam" do
    test "list/1 merges what it is handed" do
      networks =
        WiFi.list(
          access_points: fn -> [ap("kitchen", signal: 70)] end,
          saved: fn -> ["kitchen"] end,
          current_ssid: fn -> "kitchen" end
        )

      assert [%{ssid: "kitchen", saved?: true, connected?: true}] = networks
    end

    test "saved_ssids/1 reads the live configuration and skips the nameless" do
      assert WiFi.saved_ssids(
               configuration: fn -> config([%{ssid: "a"}, %{ssid: ""}, %{other: 1}]) end
             ) == ["a"]
    end

    test "connection/1 assembles the three readings" do
      assert WiFi.connection(
               connection_state: fn -> :internet end,
               current_ssid: fn -> "kitchen" end,
               address: fn -> "192.168.1.42" end
             ) == %{state: :internet, ssid: "kitchen", address: "192.168.1.42", error: nil}
    end

    test "scan/1 normalises the three shapes VintageNet.scan/1 can answer with" do
      assert WiFi.scan(scan: fn -> :ok end) == :ok
      assert WiFi.scan(scan: fn -> {:ok, :whatever} end) == :ok
      assert WiFi.scan(scan: fn -> {:error, :enodev} end) == {:error, :enodev}
    end

    test "on a machine with no radio the defaults answer rather than raise" do
      # The state a host build is in, and the one the screen has to draw.
      refute WiFi.available?()
      assert WiFi.scan() == {:error, :unavailable}
      assert WiFi.list() == []
      assert WiFi.saved_ssids() == []
      assert %{state: nil, ssid: nil} = WiFi.connection()
      assert WiFi.subscribe() == :ok
      assert WiFi.forget("anything") == {:error, :unavailable}
      assert WiFi.prefer("anything") == {:error, :unavailable}
    end
  end

  test "the interface is the one this board's radio is on" do
    assert WiFi.interface() == "wlan0"
  end

  test "the passphrase bounds are WPA's own" do
    assert WiFi.passphrase_bounds() == {8, 63}
  end
end
