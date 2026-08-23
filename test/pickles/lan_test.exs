defmodule MayonnaiOS.Pickles.LanTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Pickles.Lan

  describe "the boundary" do
    test "local addresses are local" do
      assert Lan.private?({127, 0, 0, 1})
      assert Lan.private?({10, 1, 2, 3})
      assert Lan.private?({172, 16, 0, 1})
      assert Lan.private?({172, 31, 255, 255})
      assert Lan.private?({192, 168, 1, 40})
      assert Lan.private?({169, 254, 0, 5})
    end

    test "the internet is not" do
      refute Lan.private?({8, 8, 8, 8})
      refute Lan.private?({93, 184, 216, 34})
      refute Lan.private?({172, 15, 0, 1})
      refute Lan.private?({172, 32, 0, 1})
    end

    test "resolve_local rejects public destinations by their address" do
      assert {:error, :not_local} = Lan.resolve_local("8.8.8.8")
      assert {:ok, {127, 0, 0, 1}} = Lan.resolve_local("127.0.0.1")
    end
  end

  describe "tcp_request/4" do
    test "sends, collects the reply, and tolerates the peer closing" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      Task.start_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, "ping"} = :gen_tcp.recv(socket, 0)
        :ok = :gen_tcp.send(socket, "pong")
        :gen_tcp.close(socket)
      end)

      assert {:ok, "pong"} = Lan.tcp_request("127.0.0.1", port, "ping", 2_000)
    end

    test "a silent peer is an empty reply, not an error" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      Task.start_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        # Read the command, say nothing -- what most lamps do.
        :gen_tcp.recv(socket, 0)
        Process.sleep(500)
        :gen_tcp.close(socket)
      end)

      assert {:ok, ""} = Lan.tcp_request("127.0.0.1", port, "off", 200)
    end

    test "oversized payloads are refused before any socket opens" do
      big = :binary.copy("x", 64 * 1024 + 1)
      assert {:error, :too_large} = Lan.tcp_request("127.0.0.1", 1, big, 100)
    end
  end

  describe "udp" do
    test "udp_request gets one datagram back" do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
      {:ok, port} = :inet.port(socket)

      Task.start_link(fn ->
        {:ok, {addr, from, "discover"}} = :gen_udp.recv(socket, 0, 2_000)
        :ok = :gen_udp.send(socket, addr, from, "here")
      end)

      assert {:ok, "here"} = Lan.udp_request("127.0.0.1", port, "discover", 2_000)
    end

    test "udp_send is fire and forget" do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
      {:ok, port} = :inet.port(socket)

      assert :ok = Lan.udp_send("127.0.0.1", port, "fire")
      assert {:ok, {_, _, "fire"}} = :gen_udp.recv(socket, 0, 2_000)
    end
  end
end
