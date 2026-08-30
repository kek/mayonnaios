defmodule MayonnaiOS.SystemInfoTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.{Browser, SystemInfo, Theme}
  alias MayonnaiOS.Scene.Home

  # Every source injected, so nothing here reads the machine the tests run
  # on: a host has no U-Boot environment and no games card, and a panel
  # asserted against real readings would be a test of the laptop.

  @kv %{
    "nerves_fw_version" => "0.1.0",
    "nerves_fw_uuid" => "3f8a2b1c-4d5e-6f70-8192-a3b4c5d6e7f8",
    "nerves_fw_active" => "a"
  }

  defp panel(overrides \\ []) do
    defaults = [
      version: fn -> "0.1.0" end,
      kv: fn -> @kv end,
      uptime_ms: fn -> (3 * 86_400 + 4 * 3600 + 12 * 60) * 1000 end,
      address: fn -> {"wlan0", "192.168.4.17"} end,
      memory_bytes: fn -> 191_000_000 end,
      space: fn
        "/root" ->
          %{device: "/dev/mmcblk0p4", free: 10_100_000_000, total: 13_900_000_000}

        "/root/mnt/games" ->
          %{device: "/dev/mmcblk2p1", free: 25_800_000_000, total: 62_200_000_000}
      end,
      games_mount: fn -> "/root/mnt/games" end,
      games_mounted?: fn -> true end
    ]

    SystemInfo.panel(Keyword.merge(defaults, overrides))
  end

  describe "panel/1" do
    test "says every fact when every source answers" do
      assert %{kind: :info, title: "This device", lines: lines} = panel()

      assert lines == [
               "MayonnaiOS 0.1.0",
               "firmware 0.1.0, slot a",
               "build 3f8a2b1c",
               "up 3d 4h",
               "wlan0 192.168.4.17",
               "beam memory 182.2M",
               "internal: 9.4G free",
               "games card: 24.0G free"
             ]
    end

    test "an empty KV loses the firmware lines, nothing else" do
      lines = panel(kv: fn -> %{} end).lines

      assert "MayonnaiOS 0.1.0" in lines
      refute Enum.any?(lines, &(&1 =~ "firmware"))
      refute Enum.any?(lines, &(&1 =~ "build"))
    end

    test "a version without a slot is still said" do
      lines = panel(kv: fn -> %{"nerves_fw_version" => "0.2.0"} end).lines
      assert "firmware 0.2.0" in lines
    end

    test "no address is a statement, not a missing line" do
      assert "no network address" in panel(address: fn -> nil end).lines
    end

    test "a mount that cannot be measured says nothing about itself" do
      lines = panel(space: fn _path -> nil end).lines
      refute Enum.any?(lines, &(&1 =~ "internal"))
      refute Enum.any?(lines, &(&1 =~ "games card"))
    end

    test "an unmounted games card is reported as out, not measured" do
      seen = :ets.new(:seen, [:public])

      lines =
        panel(
          games_mounted?: fn -> false end,
          space: fn path ->
            :ets.insert(seen, {path})
            %{device: "/dev/mmcblk0p4", free: 1024, total: 2048}
          end
        ).lines

      assert "games card: not in" in lines
      # The unmounted point is never measured: df on an empty directory
      # answers for the filesystem underneath it, which is the wrong number
      # under this name.
      assert :ets.lookup(seen, "/root/mnt/games") == []
    end

    test "uptime takes the two largest units that apply" do
      up = fn ms -> panel(uptime_ms: fn -> ms end).lines |> Enum.find(&(&1 =~ "up ")) end

      assert up.(45 * 1000) == "up 45s"
      assert up.((12 * 60 + 3) * 1000) == "up 12m 3s"
      assert up.((5 * 3600 + 4 * 60) * 1000) == "up 5h 4m"
      assert up.(2 * 86_400 * 1000 + 3600 * 1000) == "up 2d 1h"
    end

    test "accepts cached disk lines without reading either mount" do
      lines =
        panel(
          disk_lines: ["internal: cached", "games card: cached"],
          space: fn _path -> flunk("cached disk lines should avoid a filesystem read") end
        ).lines

      assert "internal: cached" in lines
      assert "games card: cached" in lines
    end

    test "the defaults survive a host with no device behind them" do
      # No injection at all: the real KV, df, ifaddrs. The point is only that
      # none of them crash and the always-answerable facts are there.
      assert %{kind: :info, lines: lines} = SystemInfo.panel()
      assert Enum.any?(lines, &(&1 =~ "MayonnaiOS"))
      assert Enum.any?(lines, &(&1 =~ "up "))
      assert Enum.any?(lines, &(&1 =~ "beam memory"))
    end

    test "every line fits the column it is drawn in" do
      # The slot is 200 px wide (home.ex: (640 - 24 - 2 * 8) / 3) and the
      # lines are set at 15 px in the theme's body font. Measured, not
      # counted: a character budget guessed against one font is wrong in the
      # next one.
      for line <- panel().lines do
        assert Theme.width(line, 15) <= 200, "#{inspect(line)} overflows the slot"
      end
    end
  end

  describe "the root column's left slot" do
    test "carries the system panel" do
      says = texts(Home.graph(Browser.new()))
      assert "This device" in says
      assert Enum.any?(says, &(&1 =~ "MayonnaiOS"))
    end

    test "draws a supplied system panel, so a refresh need not rebuild browser state" do
      refreshed = %{kind: :info, title: "This device", lines: ["up 12m 30s"]}
      says = texts(Home.graph(Browser.new(), nil, refreshed))

      assert "up 12m 30s" in says
    end

    test "gives the slot back to the parent below the root" do
      says = texts(Home.graph(Browser.descend(Browser.new())))
      refute "This device" in says
    end
  end

  test "the home scene refreshes cheap facts more often than disk space" do
    start_supervised!({Scenic, []})
    test = self()

    disk_reader = fn ->
      send(test, :disk_read)
      ["internal: cached"]
    end

    panel_builder = fn disk_lines ->
      send(test, {:panel_built, disk_lines})
      %{kind: :info, title: "This device", lines: ["up now" | disk_lines]}
    end

    {:ok, viewport} =
      Scenic.ViewPort.start(%{
        name: :system_info_refresh_test,
        size: {640, 480},
        default_scene:
          {Home,
           %{
             refresh_ms: 20,
             disk_refresh_ticks: 2,
             disk_reader: disk_reader,
             panel_builder: panel_builder
           }},
        drivers: []
      })

    on_exit(fn ->
      MayonnaiOS.Panel.release()

      try do
        Scenic.ViewPort.stop(viewport)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert_receive :disk_read
    assert_receive {:panel_built, ["internal: cached"]}

    # The first refresh rebuilds the cheap facts from cached disk lines.
    assert_receive {:panel_built, ["internal: cached"]}, 200
    refute_receive :disk_read, 5

    # The second refresh reaches the slower disk reader.
    assert_receive :disk_read, 200
    assert_receive {:panel_built, ["internal: cached"]}

    MayonnaiOS.Panel.hold("test program")
    refute_receive {:panel_built, _lines}, 60
  end

  defp texts(graph) do
    Scenic.Graph.reduce(graph, [], fn
      %Scenic.Primitive{module: Scenic.Primitive.Text, data: data}, acc -> [data | acc]
      _primitive, acc -> acc
    end)
  end
end
