defmodule MayonnaiOS.Pickles.Lan do
  @moduledoc """
  The `lan` capability: raw TCP and UDP, but only to the local network.

  This is the capability for talking to things like Zigbee hubs, smart lamps
  and TVs -- devices that speak some binary or JSON protocol on a local port.
  It is deliberately split from `http`: a pickle that controls a lamp needs to
  reach 192.168.x.x and nothing else, and granting it that should not also
  grant the internet.

  ## The boundary

  A destination is allowed if it resolves to a loopback, link-local or RFC 1918
  private address. The check happens on the *resolved* address and the socket
  is opened to that same address, not to the hostname -- resolving twice would
  let a name answer with a private address for the check and a public one for
  the connection.

  Loopback is allowed on purpose: it is the device itself, and a pickle
  talking to a local service is within the spirit of "local network".

  ## Limits

  Payloads are capped at 64 KB each way and reply timeouts at 10 seconds.
  These are lamp-command sizes, not file-transfer sizes; a pickle that needs
  more is not a lightweight app any more.
  """

  @max_payload 64 * 1024
  @max_timeout 10_000
  @connect_timeout 3_000

  @doc """
  Resolve `host` and return its address if it is local, in the sense above.
  """
  @spec resolve_local(String.t()) :: {:ok, :inet.ip4_address()} | {:error, term()}
  def resolve_local(host) when is_binary(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, addr} ->
        if private?(addr), do: {:ok, addr}, else: {:error, :not_local}

      {:error, reason} ->
        {:error, {:resolve, reason}}
    end
  end

  @doc """
  Whether an IPv4 address is on the local side of the boundary.
  """
  def private?({127, _, _, _}), do: true
  def private?({10, _, _, _}), do: true
  def private?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  def private?({192, 168, _, _}), do: true
  def private?({169, 254, _, _}), do: true
  def private?(_), do: false

  @doc """
  Connect, send `payload`, and collect whatever comes back within
  `timeout_ms`. Returns the reply, which may be empty -- many devices ack a
  command with silence, and silence is not an error.

  The reply is whatever arrived before the peer closed or the clock ran out.
  Framing is the script's problem: this layer cannot know whether the
  protocol on this port terminates messages with a newline, a length prefix
  or a closed connection.
  """
  @spec tcp_request(String.t(), :inet.port_number(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def tcp_request(host, port, payload, timeout_ms)
      when is_binary(payload) and byte_size(payload) <= @max_payload do
    timeout = min(timeout_ms, @max_timeout)

    with {:ok, addr} <- resolve_local(host),
         {:ok, socket} <-
           :gen_tcp.connect(addr, port, [:binary, active: false], @connect_timeout) do
      result =
        with :ok <- :gen_tcp.send(socket, payload) do
          {:ok, collect(socket, timeout, [])}
        end

      :gen_tcp.close(socket)
      result
    end
  end

  def tcp_request(_host, _port, _payload, _timeout), do: {:error, :too_large}

  @doc """
  Send one UDP datagram. Fire and forget.
  """
  @spec udp_send(String.t(), :inet.port_number(), binary()) :: :ok | {:error, term()}
  def udp_send(host, port, payload)
      when is_binary(payload) and byte_size(payload) <= @max_payload do
    with {:ok, addr} <- resolve_local(host),
         {:ok, socket} <- :gen_udp.open(0, [:binary]) do
      result = :gen_udp.send(socket, addr, port, payload)
      :gen_udp.close(socket)
      result
    end
  end

  def udp_send(_host, _port, _payload), do: {:error, :too_large}

  @doc """
  Send one UDP datagram and wait up to `timeout_ms` for one reply.
  """
  @spec udp_request(String.t(), :inet.port_number(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def udp_request(host, port, payload, timeout_ms)
      when is_binary(payload) and byte_size(payload) <= @max_payload do
    timeout = min(timeout_ms, @max_timeout)

    with {:ok, addr} <- resolve_local(host),
         {:ok, socket} <- :gen_udp.open(0, [:binary, active: false]) do
      result =
        with :ok <- :gen_udp.send(socket, addr, port, payload),
             {:ok, {_addr, _port, reply}} <- :gen_udp.recv(socket, 0, timeout) do
          {:ok, reply}
        end

      :gen_udp.close(socket)
      result
    end
  end

  def udp_request(_host, _port, _payload, _timeout), do: {:error, :too_large}

  # Read until the peer closes, the clock runs out, or the cap is reached.
  # The deadline is overall rather than per-recv, so a peer trickling bytes
  # cannot hold the call open indefinitely.
  defp collect(socket, timeout, acc) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_until(socket, deadline, acc)
  end

  defp collect_until(socket, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 or IO.iodata_length(acc) >= @max_payload do
      IO.iodata_to_binary(acc)
    else
      case :gen_tcp.recv(socket, 0, remaining) do
        {:ok, data} -> collect_until(socket, deadline, [acc, data])
        {:error, _closed_or_timeout} -> IO.iodata_to_binary(acc)
      end
    end
  end
end
