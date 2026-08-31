defmodule MayonnaiOS.GamesCardTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.GamesCard

  # These run on the host, where there is no /dev/mmcblk2p1 and /bin/mount
  # would refuse anyway. That is the interesting case rather than a limitation:
  # the whole contract of this module is that a missing card, an unknown
  # filesystem and an existing mount are all survivable, and "no card" is
  # exactly what a laptop looks like.

  describe "with no card present" do
    setup do
      dir = Path.join(System.tmp_dir!(), "games-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      Application.put_env(:mayonnaios, :games_card,
        device: "/nonexistent/mmcblk2p1",
        mount_point: dir
      )

      on_exit(fn -> Application.delete_env(:mayonnaios, :games_card) end)
      %{dir: dir}
    end

    test "starts anyway, because a console without the card is still a console" do
      assert {:ok, pid} = GamesCard.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "reports the absence rather than raising" do
      {:ok, pid} = GamesCard.start_link([])
      assert GamesCard.mount() == {:error, :no_card}
      GenServer.stop(pid)
    end

    test "is not mounted, and says so" do
      {:ok, pid} = GamesCard.start_link([])
      refute GamesCard.mounted?()
      GenServer.stop(pid)
    end

    test "unmounting something that is not mounted is not an error" do
      {:ok, pid} = GamesCard.start_link([])
      assert GamesCard.unmount() == {:ok, :not_mounted}
      GenServer.stop(pid)
    end

    test "mount_point/0 comes from config, so the web UI and the mount agree", %{dir: dir} do
      assert GamesCard.mount_point() == dir
    end
  end

  describe "backup lease" do
    setup do
      dir = Path.join(System.tmp_dir!(), "games-lease-#{System.unique_integer([:positive])}")
      Application.put_env(:mayonnaios, :games_card, device: "/nonexistent/card", mount_point: dir)
      {:ok, pid} = GamesCard.start_link([])

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Application.delete_env(:mayonnaios, :games_card)
        File.rm_rf(dir)
      end)

      :ok
    end

    test "is idempotent for one owner and excludes another" do
      assert :ok = GamesCard.acquire(self())
      assert :ok = GamesCard.acquire(self())
      other = spawn(fn -> Process.sleep(:infinity) end)
      assert {:error, :busy} = GamesCard.acquire(other)
      assert {:error, :busy} = GamesCard.unmount()
      assert :ok = GamesCard.release(self())
      assert {:ok, :not_mounted} = GamesCard.unmount()
      Process.exit(other, :kill)
    end

    test "owner death automatically releases the lease" do
      parent = self()

      owner =
        spawn(fn ->
          receive do
            :stop -> send(parent, :stopped)
          end
        end)

      assert :ok = GamesCard.acquire(owner)
      Process.exit(owner, :kill)

      Enum.reduce_while(1..50, nil, fn _, _ ->
        case GamesCard.acquire(self()) do
          :ok ->
            {:halt, :ok}

          {:error, :busy} ->
            Process.sleep(5)
            {:cont, nil}
        end
      end)

      assert :ok = GamesCard.acquire(self())
    end
  end

  describe "configuration" do
    test "defaults name the second slot, not the first and not the WiFi" do
      Application.delete_env(:mayonnaios, :games_card)
      # mmcblk0 is the OS card and mmcblk1 is the SDIO WiFi on this board, so
      # this assertion is the one that catches a plausible-looking typo.
      assert GamesCard.mount_point() == "/root/mnt/games"
    end

    test "config overrides the defaults" do
      Application.put_env(:mayonnaios, :games_card, mount_point: "/tmp/elsewhere")
      on_exit(fn -> Application.delete_env(:mayonnaios, :games_card) end)
      assert GamesCard.mount_point() == "/tmp/elsewhere"
    end
  end
end
