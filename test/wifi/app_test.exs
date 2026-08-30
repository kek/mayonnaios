defmodule MayonnaiOS.WiFi.AppTest do
  # Not async: the app is a named process.
  use ExUnit.Case, async: false

  alias MayonnaiOS.Scene.WiFi, as: Scene
  alias MayonnaiOS.WiFi.App
  alias MayonnaiOS.WiFi.Editor

  # The buttons as printed on the shell; see MayonnaiOS.Launcher for the
  # device tree that names them the other way round.
  @a :btn_b
  @b :btn_a
  @x :btn_y
  @y :btn_x
  @up :btn_dpad_up
  @down :btn_dpad_down
  @right :btn_dpad_right
  @menu :btn_mode

  # A fake radio: an Agent holding what the property table would say and the
  # configuration a write would land in. Everything `MayonnaiOS.WiFi` reads
  # or writes is one of its injected functions, so this is the whole world
  # the app can see -- and the saved networks come out of the same
  # configuration a write goes into, which is what makes forgetting a row
  # actually remove it here.
  defp world(overrides) do
    state =
      Map.merge(
        %{
          access_points: [],
          config: %{type: VintageNetWiFi, vintage_net_wifi: %{networks: []}, ipv4: %{}},
          connection_state: :disconnected,
          current_ssid: nil,
          address: nil,
          scan_result: :ok,
          scans: 0
        },
        overrides
      )

    {:ok, agent} = Agent.start_link(fn -> state end)
    agent
  end

  defp ap(ssid, opts \\ []) do
    %{
      bssid: "aa:bb:cc:dd:ee:0#{Keyword.get(opts, :n, 1)}",
      ssid: ssid,
      signal_percent: Keyword.get(opts, :signal, 60),
      flags: Keyword.get(opts, :flags, [:psk, :ccmp, :wpa2])
    }
  end

  defp network(ssid, extra \\ %{}), do: Map.merge(%{ssid: ssid, key_mgmt: :wpa_psk}, extra)

  defp wifi_opts(agent) do
    parent = self()

    [
      available?: fn -> true end,
      subscribe: fn -> :ok end,
      scan: fn ->
        Agent.get_and_update(agent, fn s -> {s.scan_result, %{s | scans: s.scans + 1}} end)
      end,
      access_points: fn -> Agent.get(agent, & &1.access_points) end,
      current_ssid: fn -> Agent.get(agent, & &1.current_ssid) end,
      connection_state: fn -> Agent.get(agent, & &1.connection_state) end,
      address: fn -> Agent.get(agent, & &1.address) end,
      configuration: fn -> Agent.get(agent, & &1.config) end,
      configure: fn config ->
        Agent.update(agent, &%{&1 | config: config})
        send(parent, {:configured, config})
        :ok
      end
    ]
  end

  # Timers off unless a test asks for them: every transition here is driven
  # by a press or a property message, and a refresh landing between the two
  # would be a race in the test rather than in the app.
  defp start(agent, opts \\ []) do
    opts =
      Keyword.merge(
        [
          wifi_opts: wifi_opts(agent),
          refresh_ms: 60_000,
          scan_ms: 60_000,
          join_timeout_ms: 60_000
        ],
        opts
      )

    {:ok, pid} = App.start(opts)
    on_exit(fn -> App.stop() end)
    pid
  end

  defp press(key), do: App.input([{:ev_key, key, 1}])

  defp ssids, do: Enum.map(App.snapshot().networks, & &1.ssid)

  defp saved(agent) do
    agent
    |> Agent.get(& &1.config)
    |> get_in([:vintage_net_wifi, :networks])
    |> Enum.map(& &1.ssid)
  end

  # The property message vintage_net sends. `VintageNet` is a target-only
  # module, but in a pattern and in a tuple it is just an atom, so a host
  # test can produce the real message.
  defp connection_changed(state, ssid \\ nil) do
    send(App, {VintageNet, ["interface", "wlan0", "connection"], :disconnected, state, %{}})
    _ = ssid
    :ok
  end

  defp supplicant_event(event) do
    send(App, {VintageNet, ["interface", "wlan0", "wifi", "event"], nil, event, %{}})
    :ok
  end

  describe "opening the screen" do
    test "lists what is on the air, strongest first, and asks for a scan" do
      agent =
        world(%{
          access_points: [ap("shed", signal: 20, n: 1), ap("kitchen", signal: 90, n: 2)]
        })

      start(agent)

      assert ssids() == ["kitchen", "shed"]
      assert Agent.get(agent, & &1.scans) == 1
    end

    test "reads where the radio already is" do
      agent =
        world(%{
          access_points: [ap("kitchen")],
          connection_state: :internet,
          current_ssid: "kitchen",
          address: "192.168.1.42"
        })

      start(agent)

      snapshot = App.snapshot()

      assert snapshot.connection == %{
               state: :internet,
               ssid: "kitchen",
               address: "192.168.1.42",
               error: nil
             }

      assert [%{ssid: "kitchen", connected?: true}] = snapshot.networks
    end

    test "a saved network out of range is a row that can still be forgotten" do
      agent =
        world(%{
          access_points: [ap("kitchen")],
          config: %{vintage_net_wifi: %{networks: [network("away")]}}
        })

      start(agent)

      assert ssids() == ["kitchen", "away"]
      assert %{in_range?: false, saved?: true} = Enum.at(App.snapshot().networks, 1)
    end

    test "a scan that will not start says so instead of looking empty" do
      agent = world(%{scan_result: {:error, :enodev}})
      start(agent)

      assert App.snapshot().scan_error == :enodev
      assert Enum.any?(texts(Scene.graph(App.snapshot())), &(&1 =~ "did not start"))
    end
  end

  describe "the cursor" do
    setup do
      agent =
        world(%{
          access_points: [
            ap("a", signal: 90, n: 1),
            ap("b", signal: 50, n: 2),
            ap("c", signal: 10, n: 3)
          ]
        })

      start(agent)
      %{agent: agent}
    end

    test "moves down and wraps" do
      assert App.snapshot().cursor == 0

      press(@down)
      assert App.snapshot().cursor == 1

      press(@down)
      press(@down)
      assert App.snapshot().cursor == 0
    end

    test "moves up from the top to the bottom" do
      press(@up)
      assert App.snapshot().cursor == 2
      assert App.snapshot().selected.ssid == "c"
    end

    test "Menu never means anything here -- it is the launcher's way out" do
      press(@menu)
      assert App.snapshot().cursor == 0
    end
  end

  describe "joining an open network" do
    test "A joins it with no passphrase asked for" do
      agent = world(%{access_points: [ap("cafe", flags: [:ess])]})
      start(agent)

      assert App.snapshot().selected.security == :open

      press(@a)

      assert_received {:configured, _config}
      assert saved(agent) == ["cafe"]
      assert App.snapshot().status == :joining
    end
  end

  describe "joining a secured network" do
    setup do
      agent = world(%{access_points: [ap("kitchen")]})
      start(agent)
      %{agent: agent}
    end

    test "A opens the passphrase wheel rather than joining" do
      press(@a)

      snapshot = App.snapshot()

      assert snapshot.status == :editing
      assert snapshot.editor.ssid == "kitchen"
      refute_received {:configured, _config}
    end

    test "the wheel types, and A joins with what was typed" do
      press(@a)

      # a, right, b -- the wheel adds a character when the caret moves, so
      # this is "ab" and then enough more to clear WPA's eight.
      for _n <- 1..1, do: press(@down)
      press(@right)
      for _n <- 1..2, do: press(@down)

      assert Editor.value(App.snapshot().editor) == "ab"

      # Still too short, so A comes back with a reason rather than a write.
      press(@a)
      assert App.snapshot().status == :failed
      assert App.snapshot().error == :passphrase_too_short
      refute_received {:configured, _config}
    end

    test "a passphrase long enough is written, and the wheel is gone" do
      press(@a)
      type("hunter2!!")
      press(@a)

      assert_received {:configured, config}

      assert [%{ssid: "kitchen", psk: "hunter2!!", key_mgmt: :wpa_psk}] =
               get_in(config, [:vintage_net_wifi, :networks])

      assert App.snapshot().status == :joining
      assert App.snapshot().editor == nil
    end

    test "B cancels the wheel and writes nothing" do
      press(@a)
      type("hunter2!!")
      press(@b)

      snapshot = App.snapshot()

      assert snapshot.status == :listing
      assert snapshot.editor == nil
      refute_received {:configured, _config}
    end

    test "while the wheel is up B belongs to this app, and otherwise it does not" do
      # `MayonnaiOS.Launcher` asks on every report, so the same button
      # cancels the overlay and then leaves.
      refute App.claims_back?()

      press(@a)
      assert App.claims_back?()

      press(@b)
      refute App.claims_back?()
    end
  end

  describe "a network already saved" do
    setup do
      agent =
        world(%{
          access_points: [ap("kitchen", signal: 80, n: 1), ap("shed", signal: 30, n: 2)],
          config: %{
            vintage_net_wifi: %{
              networks: [network("shed", %{psk: "shedpass"}), network("kitchen", %{psk: "kit"})]
            }
          }
        })

      start(agent)
      %{agent: agent}
    end

    test "A switches to it without asking for the passphrase again" do
      press(@down)
      assert App.snapshot().selected.ssid == "shed"

      press(@a)

      assert_received {:configured, config}
      networks = get_in(config, [:vintage_net_wifi, :networks])

      # Moved to the head, and its passphrase carried across untouched.
      assert Enum.map(networks, & &1.ssid) == ["shed", "kitchen"]
      assert hd(networks).psk == "shedpass"
      assert App.snapshot().status == :joining
    end

    test "X retypes the passphrase, which is the one repair the list cannot otherwise make" do
      press(@x)

      assert App.snapshot().status == :editing
      assert App.snapshot().editor.ssid == "kitchen"

      type("newpassphrase")
      press(@a)

      assert_received {:configured, config}
      networks = get_in(config, [:vintage_net_wifi, :networks])

      assert hd(networks) == %{
               ssid: "kitchen",
               key_mgmt: :wpa_psk,
               psk: "newpassphrase",
               priority: 2
             }
    end
  end

  describe "the connected network" do
    test "A does nothing, because there is nothing for it to do" do
      agent =
        world(%{
          access_points: [ap("kitchen")],
          config: %{vintage_net_wifi: %{networks: [network("kitchen")]}},
          connection_state: :internet,
          current_ssid: "kitchen"
        })

      start(agent)

      assert App.snapshot().selected.connected?

      press(@a)

      refute_received {:configured, _config}
      assert App.snapshot().status == :listing
    end
  end

  describe "forgetting a network" do
    setup do
      agent =
        world(%{
          access_points: [ap("kitchen")],
          config: %{vintage_net_wifi: %{networks: [network("kitchen")]}}
        })

      start(agent)
      %{agent: agent}
    end

    test "Y twice: the first arms the row and the second does it", %{agent: agent} do
      press(@y)
      assert App.snapshot().armed?

      press(@y)

      refute App.snapshot().armed?
      assert saved(agent) == []
      # The row is still on the air, so it stays -- it is just no longer
      # saved.
      assert [%{ssid: "kitchen", saved?: false}] = App.snapshot().networks
    end

    test "moving the cursor disarms" do
      press(@y)
      assert App.snapshot().armed?

      press(@down)
      refute App.snapshot().armed?
    end

    test "B while armed takes the question down and does not also leave" do
      press(@y)
      assert App.claims_back?()

      press(@b)

      refute App.snapshot().armed?
      refute App.claims_back?()
    end

    test "Y on a network that is not saved is not a question" do
      press(@y)
      press(@y)

      # Now unsaved: pressing Y again arms nothing.
      press(@y)
      refute App.snapshot().armed?
    end
  end

  describe "the kinds this screen refuses" do
    test "an enterprise network says what it would need instead of taking a passphrase" do
      agent = world(%{access_points: [ap("corp", flags: [:eap, :ccmp, :wpa2])]})
      start(agent)

      press(@a)

      assert App.snapshot().status == :failed
      assert App.snapshot().error == :eap_unsupported
      refute_received {:configured, _config}
    end

    test "a WEP network the same" do
      agent = world(%{access_points: [ap("old", flags: [:wep])]})
      start(agent)

      press(@a)

      assert App.snapshot().error == :wep_unsupported
      refute_received {:configured, _config}
    end
  end

  describe "waiting for the radio" do
    setup do
      agent = world(%{access_points: [ap("kitchen")]})
      start(agent)

      press(@a)
      type("hunter2!!")
      press(@a)

      assert_received {:configured, _config}
      assert App.snapshot().status == :joining

      %{agent: agent}
    end

    test "a lease on the network just joined finishes it", %{agent: agent} do
      Agent.update(agent, fn s ->
        %{s | connection_state: :lan, current_ssid: "kitchen", address: "192.168.1.42"}
      end)

      connection_changed(:lan)

      assert App.snapshot().status == :joined
      assert App.snapshot().connection.address == "192.168.1.42"
    end

    test "a lease on a different network does not", %{agent: agent} do
      # The old network coming back is not the new one working.
      Agent.update(agent, fn s -> %{s | connection_state: :lan, current_ssid: "workbench"} end)

      connection_changed(:lan)

      assert App.snapshot().status == :joining
    end

    test "the access point refusing the passphrase says so, and withdraws it", %{agent: agent} do
      supplicant_event(%{
        name: "CTRL-EVENT-SSID-TEMP-DISABLED",
        ssid: "kitchen",
        reason: "WRONG_KEY",
        auth_failures: 1
      })

      assert App.snapshot().status == :failed
      assert App.snapshot().error == :wrong_key

      # A network known to be wrong is one the supplicant keeps retrying over
      # the top of the one that works, so it does not stay configured.
      assert saved(agent) == []
    end

    test "an unrelated supplicant event is not a verdict" do
      supplicant_event(%{name: "CTRL-EVENT-CONNECTED"})

      assert App.snapshot().status == :joining
    end

    test "A on the page after a join goes back to the list", %{agent: agent} do
      Agent.update(agent, fn s -> %{s | connection_state: :lan, current_ssid: "kitchen"} end)
      connection_changed(:lan)

      assert App.snapshot().status == :joined

      press(@a)

      assert App.snapshot().status == :listing
      assert App.snapshot().error == nil
    end
  end

  describe "the join deadline" do
    test "gives up, and leaves the network configured" do
      agent = world(%{access_points: [ap("kitchen")]})
      start(agent, join_timeout_ms: 20)

      press(@a)
      type("hunter2!!")
      press(@a)

      assert App.snapshot().status == :joining

      # DHCP on a tired router outlasts any deadline worth putting on a
      # panel, so a deadline reached is not a reason to undo anything.
      assert eventually(fn -> App.snapshot().status == :failed end)
      assert App.snapshot().error == :timed_out
      assert saved(agent) == ["kitchen"]
    end
  end

  describe "watch/1" do
    test "pushes a snapshot when something changes" do
      agent = world(%{access_points: [ap("a", n: 1), ap("b", n: 2)]})
      start(agent)

      assert %{status: :listing} = App.watch(self())

      press(@down)

      assert_receive {:wifi_app, %{cursor: 1}}, 1_000
    end

    test "is :stopped when the app is not running" do
      assert App.watch(self()) == :stopped
      assert App.snapshot() == :stopped
      refute App.claims_back?()
    end
  end

  describe "the scene" do
    # graph/1 is the tested surface: no viewport, no driver, no framebuffer.
    # The same helper the other scene tests use.
    defp texts(graph) do
      Scenic.Graph.reduce(graph, [], fn
        %Scenic.Primitive{module: Scenic.Primitive.Text, data: data}, acc -> [data | acc]
        _primitive, acc -> acc
      end)
    end

    defp snapshot(overrides) do
      Map.merge(
        %{
          status: :listing,
          networks: [],
          connection: %{state: :disconnected, ssid: nil, address: nil, error: nil},
          cursor: 0,
          selected: nil,
          editor: nil,
          target: nil,
          error: nil,
          armed?: false,
          available?: true,
          scan_error: nil,
          passphrase_bounds: {8, 63}
        },
        overrides
      )
    end

    defp row(ssid, overrides \\ %{}) do
      Map.merge(
        %{
          ssid: ssid,
          security: :wpa_psk,
          signal: 70,
          saved?: false,
          connected?: false,
          in_range?: true
        },
        overrides
      )
    end

    test "not running" do
      assert Enum.member?(texts(Scene.graph(:stopped)), "Not running")
    end

    test "nothing draws above the shared top bar" do
      assert Scene.status_bar() > 0
    end

    test "an empty list says it is scanning rather than looking broken" do
      assert Enum.any?(texts(Scene.graph(snapshot(%{}))), &(&1 =~ "Scanning"))
    end

    test "a machine with no radio says so" do
      texts = texts(Scene.graph(snapshot(%{available?: false})))

      assert Enum.any?(texts, &(&1 =~ "No WiFi radio"))
      assert Enum.any?(texts, &(&1 =~ "target-only"))
    end

    test "the connection line names the network and the address" do
      texts =
        texts(
          Scene.graph(
            snapshot(%{
              connection: %{
                state: :internet,
                ssid: "kitchen",
                address: "192.168.1.42",
                error: nil
              }
            })
          )
        )

      assert Enum.any?(texts, &(&1 =~ "kitchen" and &1 =~ "192.168.1.42"))
    end

    test "a lan-only connection is not drawn as a failure" do
      texts =
        texts(
          Scene.graph(
            snapshot(%{
              connection: %{state: :lan, ssid: "kitchen", address: "10.0.0.5", error: nil}
            })
          )
        )

      assert Enum.any?(texts, &(&1 =~ "no route to the internet"))
    end

    test "a row carries its signal, its security and whether it is known" do
      networks = [row("kitchen", %{saved?: true, signal: 84})]
      texts = texts(Scene.graph(snapshot(%{networks: networks, selected: hd(networks)})))

      assert Enum.member?(texts, "kitchen")
      assert Enum.any?(texts, &(&1 =~ "84%" and &1 =~ "WPA2" and &1 =~ "saved"))
    end

    test "an enterprise row says what it would need where the others say how to join" do
      networks = [row("corp", %{security: :eap})]
      texts = texts(Scene.graph(snapshot(%{networks: networks, selected: hd(networks)})))

      assert Enum.any?(texts, &(&1 =~ "identity and a certificate"))
      assert Enum.any?(texts, &(&1 =~ "cannot be joined from here"))
    end

    test "an armed row shouts, because the next press is the one that does it" do
      networks = [row("kitchen", %{saved?: true})]

      texts =
        texts(Scene.graph(snapshot(%{networks: networks, selected: hd(networks), armed?: true})))

      assert Enum.any?(texts, &(&1 =~ "press Y again to forget"))
      assert Enum.any?(texts, &(&1 =~ "Y forgets this network"))
    end

    test "the footer offers what the selected row can actually do" do
      open = [row("cafe", %{security: :open})]
      saved = [row("kitchen", %{saved?: true})]

      assert Enum.any?(
               texts(Scene.graph(snapshot(%{networks: open, selected: hd(open)}))),
               &(&1 =~ "A joins this open network")
             )

      assert Enum.any?(
               texts(Scene.graph(snapshot(%{networks: saved, selected: hd(saved)}))),
               &(&1 =~ "X retypes the passphrase")
             )
    end

    test "the wheel shows the passphrase, the length rule and where the caret is" do
      editor = Editor.new("kitchen")
      editor = %{editor | chars: String.graphemes("hunter2"), caret: 3}

      texts = texts(Scene.graph(snapshot(%{status: :editing, editor: editor})))

      assert Enum.member?(texts, "hunter2")
      assert Enum.any?(texts, &(&1 =~ "Passphrase for" and &1 =~ "kitchen"))
      # Seven characters, so the rule is worth saying out loud.
      assert Enum.any?(texts, &(&1 =~ "7 characters" and &1 =~ "8 to 63"))
      assert Enum.any?(texts, &(&1 =~ "Under the caret"))
      assert Enum.any?(texts, &(&1 =~ "L1/R1 jump blocks"))
    end

    test "an empty wheel prompts rather than drawing a bare caret" do
      texts = texts(Scene.graph(snapshot(%{status: :editing, editor: Editor.new("kitchen")})))

      assert Enum.any?(texts, &(&1 =~ "press up or down to start"))
    end

    test "a full-length passphrase wraps onto a second line" do
      editor = %{Editor.new("k") | chars: String.graphemes(String.duplicate("a", 63)), caret: 63}

      texts = texts(Scene.graph(snapshot(%{status: :editing, editor: editor})))
      lines = Enum.filter(texts, &(&1 =~ ~r/^a+$/))

      assert length(lines) == 2
      assert Enum.map(lines, &String.length/1) |> Enum.sum() == 63
    end

    test "joining says what it is waiting for and that nothing was lost" do
      texts =
        texts(Scene.graph(snapshot(%{status: :joining, target: row("kitchen")})))

      assert Enum.any?(texts, &(&1 =~ "Joining" and &1 =~ "kitchen"))
      assert Enum.any?(texts, &(&1 =~ "untouched"))
    end

    test "joined names the network and the address it was given" do
      texts =
        texts(
          Scene.graph(
            snapshot(%{
              status: :joined,
              target: row("kitchen"),
              connection: %{state: :lan, ssid: "kitchen", address: "10.0.0.9", error: nil}
            })
          )
        )

      assert Enum.any?(texts, &(&1 =~ "Joined" and &1 =~ "kitchen"))
      assert Enum.any?(texts, &(&1 =~ "10.0.0.9"))
      assert Enum.any?(texts, &(&1 =~ "power cut"))
    end

    test "a refused passphrase says so, and says what was not changed" do
      texts =
        texts(
          Scene.graph(snapshot(%{status: :failed, error: :wrong_key, target: row("kitchen")}))
        )

      assert Enum.any?(texts, &(&1 =~ "passphrase was refused"))
      assert Enum.any?(texts, &(&1 =~ "removed again"))
      assert Enum.any?(texts, &(&1 =~ "Nothing else changed"))
    end

    test "a deadline reached is not the same sentence as a refusal" do
      texts =
        texts(
          Scene.graph(snapshot(%{status: :failed, error: :timed_out, target: row("kitchen")}))
        )

      assert Enum.any?(texts, &(&1 =~ "No answer"))
      assert Enum.any?(texts, &(&1 =~ "still configured"))
    end

    test "every error the app can produce has words rather than a term" do
      for error <- [
            :wrong_key,
            :timed_out,
            :passphrase_too_short,
            :passphrase_too_long,
            :eap_unsupported,
            :wep_unsupported,
            :unavailable,
            :not_saved,
            {:forget_failed, :eacces},
            :something_new
          ] do
        texts = texts(Scene.graph(snapshot(%{status: :failed, error: error})))

        assert length(texts) > 3, "no page for #{inspect(error)}"
      end
    end

    test "an SSID at its maximum length does not run off the panel" do
      long = String.duplicate("x", 60)
      networks = [row(long)]

      texts = texts(Scene.graph(snapshot(%{networks: networks, selected: hd(networks)})))

      assert Enum.any?(texts, &(String.length(&1) <= 46 and &1 =~ "xxx"))
    end

    test "more rows than fit says which of them are showing" do
      networks = for n <- 1..20, do: row("network-#{n}")

      texts =
        texts(Scene.graph(snapshot(%{networks: networks, cursor: 0, selected: hd(networks)})))

      assert Enum.any?(texts, &(&1 =~ "of 20"))
      assert Scene.visible() < 20
    end

    test "a cursor past the last visible row brings the window with it" do
      networks = for n <- 1..20, do: row("network-#{n}")
      last = List.last(networks)

      texts =
        texts(Scene.graph(snapshot(%{networks: networks, cursor: 19, selected: last})))

      assert Enum.member?(texts, "network-20")
      refute Enum.member?(texts, "network-1")
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Type a passphrase on the wheel through the app, the way somebody would:
  # cycle to a character, move the caret right, cycle to the next.
  defp type(string) do
    string
    |> String.graphemes()
    |> Enum.each(fn char ->
      wheel_to(char)
      press(@right)
    end)
  end

  defp wheel_to(char) do
    press(@down)

    Enum.reduce_while(1..95, nil, fn _n, _acc ->
      if Editor.current(App.snapshot().editor) == char do
        {:halt, :ok}
      else
        press(@down)
        {:cont, nil}
      end
    end)
  end

  defp eventually(check, tries \\ 200) do
    cond do
      check.() -> true
      tries > 0 -> Process.sleep(5) && eventually(check, tries - 1)
      true -> false
    end
  end
end
