defmodule MayonnaiOS.Pickles.Sandbox do
  @moduledoc """
  The Lua sandbox a pickle runs in, and the `mayo.*` API injected into it.

  ## Why Luerl

  Luerl is Lua implemented in Erlang, which makes the sandbox story short: a
  script is data in a BEAM process, it has no pointer to anything, and the
  only way it can touch the world is through functions this module chooses to
  put into its globals. There is no FFI to forget to close, no C stack to
  smash. The base state comes from `:luerl_sandbox.init/0`, which additionally
  removes what stock Lua ships that would be a hole here: `io`, `file`,
  `os.execute`, `load`, `require`, `package` and friends.

  ## Capabilities

  Everything a pickle can do arrives as a table under `mayo`, and each table
  is only present if the manifest asked for the capability:

      always      mayo.log, mayo.sleep, mayo.now_ms, mayo.json.*,
                  mayo.name, mayo.version
      "http"      mayo.http.get/post/request -- the internet, optionally
                  narrowed to the manifest's `hosts`
      "lan"       mayo.lan.tcp/udp/udp_request -- local addresses only,
                  see MayonnaiOS.Pickles.Lan
      "storage"   mayo.storage.get/set/delete -- a small KV store that
                  survives reinstalls
      "timers"    mayo.timer.every/once -- named callbacks on a clock

  A capability the manifest did not request is simply absent, so calling it
  is an ordinary Lua error naming the nil field -- which is the report the
  script author needs, and it costs no checking machinery.

  The API functions follow the Lua convention: `result` on success,
  `nil, "reason"` on failure. They do not raise, because an Erlang exception
  inside an injected function would kill the whole call rather than give the
  script a chance to handle a lamp being off.

  ## Bounded execution

  Lua cannot be trusted to return. `exec/2` runs any Luerl operation in a
  separate process with a wall-clock budget and a heap cap: an infinite loop
  is killed by the clock, a memory bomb by `max_heap_size`, and either way
  the runner keeps its previous Lua state and a readable reason. This is why
  the Lua state being immutable Erlang data matters -- a killed call simply
  never happened.
  """

  alias MayonnaiOS.Pickles.Lan

  @call_timeout 30_000
  # In words, so ~128 MB on a 64-bit BEAM. Far above what a lamp controller
  # needs, far below what would trouble a device with 1 GB.
  @max_heap_words 16_000_000
  @max_http_body 1_000_000
  @max_sleep 10_000
  @max_storage_bytes 64 * 1024

  @type lua :: tuple()

  # -- state construction ------------------------------------------------------

  @doc """
  A sandboxed Lua state for `manifest`, with `mayo.*` wired to `owner`.

  `owner` is the runner process: logs and timer registrations are messages to
  it (`{:pickle_log, msg}`, `{:pickle_timer_req, kind, ms, fname}`), because
  the API functions execute inside `exec/2`'s throwaway process and anything
  that must outlive the call has to leave it.
  """
  @spec new(map(), pid(), keyword()) :: lua()
  def new(manifest, owner, opts \\ []) do
    state_path = Keyword.get(opts, :state_path)
    http_impl = Keyword.get(opts, :http_impl, &http_request/4)

    base = %{
      "name" => manifest.name,
      "version" => manifest.version,
      "log" => api(fn args -> mayo_log(owner, args) end),
      "sleep" => api(fn args -> mayo_sleep(args) end),
      "now_ms" => api(fn _ -> [System.system_time(:millisecond)] end),
      "json" => %{
        "encode" => api(fn args -> mayo_json_encode(args) end),
        "decode" => api(fn args -> mayo_json_decode(args) end)
      }
    }

    mayo =
      base
      |> grant(manifest, "http", fn ->
        %{
          "get" => api(fn args -> mayo_http(http_impl, manifest.hosts, :get, args) end),
          "post" => api(fn args -> mayo_http(http_impl, manifest.hosts, :post, args) end),
          "request" => api(fn args -> mayo_http_request(http_impl, manifest.hosts, args) end)
        }
      end)
      |> grant(manifest, "lan", fn ->
        %{
          "tcp" => api(fn args -> mayo_tcp(args) end),
          "udp" => api(fn args -> mayo_udp(args) end),
          "udp_request" => api(fn args -> mayo_udp_request(args) end)
        }
      end)
      |> grant(manifest, "storage", fn ->
        %{
          "get" => api(fn args -> mayo_storage_get(state_path, args) end),
          "set" => api(fn args -> mayo_storage_set(state_path, args) end),
          "delete" => api(fn args -> mayo_storage_delete(state_path, args) end)
        }
      end)
      |> grant(manifest, "timers", fn ->
        %{
          "every" => api(fn args -> mayo_timer(owner, :every, args) end),
          "once" => api(fn args -> mayo_timer(owner, :once, args) end)
        }
      end)

    st = :luerl_sandbox.init()
    {:ok, st} = :luerl.set_table_keys_dec([<<"mayo">>], mayo, st)
    st
  end

  defp grant(mayo, manifest, capability, table) do
    if capability in manifest.capabilities do
      Map.put(mayo, key_for(capability), table.())
    else
      mayo
    end
  end

  defp key_for("timers"), do: "timer"
  defp key_for(capability), do: capability

  # -- running Lua -------------------------------------------------------------

  @doc """
  Compile and run a chunk, returning the new state.
  """
  @spec load(lua(), binary()) :: {:ok, lua()} | {:error, String.t()}
  def load(lua, chunk) do
    case :luerl.do_dec(chunk, lua) do
      {:ok, _result, lua} -> {:ok, lua}
      other -> {:error, describe_error(other)}
    end
  end

  @doc """
  Call the global function `fname` with `args` (plain Elixir terms).
  Results come back as plain Elixir terms.
  """
  @spec call(lua(), String.t(), [term()]) :: {:ok, [term()], lua()} | {:error, String.t()}
  def call(lua, fname, args) do
    encodable = Enum.map(args, &term_to_lua/1)

    case :luerl.call_function_dec([fname], encodable, lua) do
      {:ok, results, lua} -> {:ok, Enum.map(results, &lua_to_term/1), lua}
      other -> {:error, describe_error(other)}
    end
  end

  @doc """
  Whether the chunk defined a global named `fname`.
  """
  @spec function?(lua(), String.t()) :: boolean()
  def function?(lua, fname) do
    case :luerl.get_table_keys([fname], lua) do
      {:ok, nil, _} -> false
      {:ok, _, _} -> true
      _ -> false
    end
  end

  @doc """
  Run `fun` in a throwaway process with a wall-clock budget and a heap cap.

  Returns whatever `fun` returns, or `{:error, :timeout}` /
  `{:error, {:crashed, reason}}`. The caller's own state is untouched either
  way -- that is the point.
  """
  @spec exec((-> result), non_neg_integer()) :: result | {:error, term()} when result: term()
  def exec(fun, timeout \\ @call_timeout) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: @max_heap_words,
          kill: true,
          error_logger: false
        })

        send(parent, {ref, fun.()})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:crashed, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end

        # The result may have raced the kill; prefer it to the timeout.
        receive do
          {^ref, result} -> result
        after
          0 -> {:error, :timeout}
        end
    end
  end

  defp describe_error({:lua_error, reason, _lua}), do: "lua error: #{inspect(reason)}"

  defp describe_error({:error, errors, _warnings}),
    do: "compile error: #{inspect(errors)}"

  defp describe_error(other), do: inspect(other)

  # -- Lua <-> Elixir ----------------------------------------------------------

  @doc """
  A decoded Luerl value as a plain Elixir term. Tables whose keys are exactly
  1..n become lists; every other table becomes a map. An empty table becomes
  an empty list, because there is nothing in it to say otherwise.
  """
  def lua_to_term(pairs) when is_list(pairs) do
    if Enum.all?(pairs, &match?({_, _}, &1)) do
      converted = for {k, v} <- pairs, do: {lua_to_term(k), lua_to_term(v)}
      keys = Enum.map(converted, &elem(&1, 0))

      if keys != [] and Enum.all?(keys, &is_integer/1) and
           Enum.sort(keys) == Enum.to_list(1..length(keys)) do
        converted |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
      else
        Map.new(converted)
      end
    else
      Enum.map(pairs, &lua_to_term/1)
    end
  end

  def lua_to_term(other), do: other

  @doc """
  A plain Elixir term in the shape `:luerl.encode/2` accepts. Atoms become
  strings (except the ones Lua knows), maps become tables, and anything with
  no Lua shape becomes its `inspect/1` string rather than an exception.
  """
  def term_to_lua(nil), do: nil
  def term_to_lua(:null), do: nil
  def term_to_lua(term) when is_boolean(term) or is_number(term) or is_binary(term), do: term
  def term_to_lua(term) when is_atom(term), do: Atom.to_string(term)

  def term_to_lua(term) when is_map(term),
    do: for({k, v} <- term, do: {term_to_lua(k), term_to_lua(v)})

  def term_to_lua(term) when is_list(term), do: Enum.map(term, &term_to_lua/1)
  def term_to_lua(term), do: inspect(term)

  @doc """
  A term `:json.encode/1` accepts: `nil` becomes `:null`, map keys become
  strings, tuples become lists. Used for everything a pickle hands back that
  ends up in an HTTP response.
  """
  def jsonable(nil), do: :null
  def jsonable(term) when is_boolean(term) or is_number(term) or is_binary(term), do: term
  def jsonable(term) when is_atom(term), do: Atom.to_string(term)
  def jsonable(%DateTime{} = term), do: DateTime.to_iso8601(term)
  def jsonable(%_{} = term), do: inspect(term)

  def jsonable(term) when is_map(term),
    do: Map.new(term, fn {k, v} -> {jsonable_key(k), jsonable(v)} end)

  def jsonable(term) when is_list(term), do: Enum.map(term, &jsonable/1)
  def jsonable(term) when is_tuple(term), do: term |> Tuple.to_list() |> jsonable()
  def jsonable(term), do: inspect(term)

  defp jsonable_key(k) when is_binary(k), do: k
  defp jsonable_key(k), do: to_string(jsonable(k))

  # -- the mayo API ------------------------------------------------------------

  # Wrap a plain ([term] -> [term]) function as a Luerl-callable: decode the
  # arguments, run, encode the results, and turn any exception into the Lua
  # convention of nil-and-a-reason instead of a dead process.
  defp api(fun) do
    fn eargs, st ->
      args = Enum.map(eargs, fn earg -> lua_to_term(:luerl.decode(earg, st)) end)

      results =
        try do
          fun.(args)
        rescue
          e -> [nil, "error: #{Exception.message(e)}"]
        catch
          kind, reason -> [nil, "error: #{inspect({kind, reason})}"]
        end

      :luerl.encode_list(Enum.map(results, &term_to_lua/1), st)
    end
  end

  defp mayo_log(owner, [msg | _]) do
    send(owner, {:pickle_log, display(msg)})
    [true]
  end

  defp mayo_log(_owner, []), do: [nil, "log needs a message"]

  defp display(msg) when is_binary(msg), do: msg
  defp display(msg), do: inspect(msg)

  defp mayo_sleep([ms | _]) when is_number(ms) and ms >= 0 do
    ms |> trunc() |> min(@max_sleep) |> Process.sleep()
    [true]
  end

  defp mayo_sleep(_), do: [nil, "sleep needs milliseconds"]

  defp mayo_json_encode([term | _]) do
    [:json.encode(jsonable(term)) |> IO.iodata_to_binary()]
  end

  defp mayo_json_encode([]), do: [nil, "encode needs a value"]

  defp mayo_json_decode([json | _]) when is_binary(json) do
    [json |> :json.decode() |> nulls_to_nil()]
  rescue
    _ -> [nil, "not valid json"]
  end

  defp mayo_json_decode(_), do: [nil, "decode needs a string"]

  defp nulls_to_nil(:null), do: nil
  defp nulls_to_nil(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, nulls_to_nil(v)} end)
  defp nulls_to_nil(list) when is_list(list), do: Enum.map(list, &nulls_to_nil/1)
  defp nulls_to_nil(other), do: other

  # -- http --

  defp mayo_http(impl, hosts, :get, [url | rest]) when is_binary(url),
    do: gated_http(impl, hosts, :get, url, headers_arg(rest), nil)

  defp mayo_http(impl, hosts, :post, [url, body | rest]) when is_binary(url) and is_binary(body),
    do: gated_http(impl, hosts, :post, url, headers_arg(rest), body)

  defp mayo_http(_impl, _hosts, _method, _args), do: [nil, "bad arguments"]

  defp mayo_http_request(impl, hosts, [method, url | rest])
       when is_binary(method) and is_binary(url) do
    body =
      case rest do
        [b | _] when is_binary(b) -> b
        _ -> nil
      end

    headers =
      case rest do
        [_, h | _] when is_map(h) -> h
        _ -> %{}
      end

    case parse_method(method) do
      {:ok, m} -> gated_http(impl, hosts, m, url, headers, body)
      :error -> [nil, "unknown method"]
    end
  end

  defp mayo_http_request(_impl, _hosts, _args), do: [nil, "bad arguments"]

  defp parse_method(m) do
    case String.downcase(m) do
      "get" -> {:ok, :get}
      "post" -> {:ok, :post}
      "put" -> {:ok, :put}
      "delete" -> {:ok, :delete}
      "patch" -> {:ok, :patch}
      _ -> :error
    end
  end

  defp headers_arg([h | _]) when is_map(h), do: h
  defp headers_arg(_), do: %{}

  # The allowlist gate wraps the transport rather than living inside it, so a
  # test that injects a fake transport still exercises the real gate. A
  # manifest with no `hosts` list means the http capability is unrestricted;
  # one with a list means exactly those hosts.
  defp gated_http(impl, hosts, method, url, headers, body) do
    if host_allowed?(url, hosts) do
      case impl.(method, url, headers, body) do
        {:ok, status, resp_body} -> [resp_body, status]
        {:error, reason} -> [nil, "http: #{inspect(reason)}"]
      end
    else
      [nil, "http: host not in this pickle's allowlist"]
    end
  end

  defp host_allowed?(_url, nil), do: true

  defp host_allowed?(url, hosts) when is_list(hosts) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host in hosts
      _ -> false
    end
  end

  @doc false
  # The real transport. Everything from OTP, like MayonnaiOS.Bundle: :httpc
  # to fetch, :ssl verified against the OS trust store. The body lands in
  # memory, so it is capped -- a pickle parses weather JSON, it does not
  # download disc images.
  def http_request(method, url, headers, body) do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         :ok <- check_scheme(url) do
      header_list = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}

      content_type =
        headers
        |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "content-type", do: v end)
        |> Kernel.||("application/json")

      request =
        if body do
          {String.to_charlist(url), header_list, String.to_charlist(content_type), body}
        else
          {String.to_charlist(url), header_list}
        end

      http_opts = [timeout: 10_000, connect_timeout: 5_000, ssl: ssl_opts()]

      case :httpc.request(method, request, http_opts, body_format: :binary) do
        {:ok, {{_, status, _}, _headers, resp_body}}
        when byte_size(resp_body) <= @max_http_body ->
          {:ok, status, resp_body}

        {:ok, {{_, _status, _}, _headers, _resp_body}} ->
          {:error, :response_too_large}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_scheme(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _ ->
        {:error, :bad_url}
    end
  end

  # The same shape as MayonnaiOS.Bundle.ssl_opts/0, duplicated on purpose:
  # the two modules trust different things (Bundle a checksum, this a CA
  # store) and a shared helper would suggest a shared policy.
  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  rescue
    _ -> [verify: :verify_peer, cacerts: []]
  end

  # -- lan --

  defp mayo_tcp([host, port, data | rest])
       when is_binary(host) and is_number(port) and is_binary(data) do
    timeout = optional_timeout(rest, 2_000)
    lan_reply(Lan.tcp_request(host, trunc(port), data, timeout))
  end

  defp mayo_tcp(_), do: [nil, "bad arguments"]

  defp mayo_udp([host, port, data | _])
       when is_binary(host) and is_number(port) and is_binary(data) do
    case Lan.udp_send(host, trunc(port), data) do
      :ok -> [true]
      {:error, reason} -> [nil, "lan: #{inspect(reason)}"]
    end
  end

  defp mayo_udp(_), do: [nil, "bad arguments"]

  defp mayo_udp_request([host, port, data | rest])
       when is_binary(host) and is_number(port) and is_binary(data) do
    timeout = optional_timeout(rest, 2_000)
    lan_reply(Lan.udp_request(host, trunc(port), data, timeout))
  end

  defp mayo_udp_request(_), do: [nil, "bad arguments"]

  defp optional_timeout([t | _], _default) when is_number(t) and t > 0, do: trunc(t)
  defp optional_timeout(_, default), do: default

  defp lan_reply({:ok, reply}), do: [reply]
  defp lan_reply({:error, reason}), do: [nil, "lan: #{inspect(reason)}"]

  # -- storage --

  defp mayo_storage_get(path, [key | _]) when is_binary(key) do
    [Map.get(read_storage(path), key)]
  end

  defp mayo_storage_get(_, _), do: [nil, "bad arguments"]

  defp mayo_storage_set(path, [key, value | _]) when is_binary(key) do
    data = read_storage(path) |> Map.put(key, jsonable(value))
    encoded = :json.encode(data) |> IO.iodata_to_binary()

    cond do
      byte_size(encoded) > @max_storage_bytes ->
        [nil, "storage full"]

      true ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, encoded)
        [true]
    end
  end

  defp mayo_storage_set(_, _), do: [nil, "bad arguments"]

  defp mayo_storage_delete(path, [key | _]) when is_binary(key) do
    data = read_storage(path) |> Map.delete(key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :json.encode(data) |> IO.iodata_to_binary())
    [true]
  end

  defp mayo_storage_delete(_, _), do: [nil, "bad arguments"]

  defp read_storage(path) do
    with {:ok, body} <- File.read(path),
         data when is_map(data) <- safe_decode(body) do
      nulls_to_nil(data)
    else
      _ -> %{}
    end
  end

  defp safe_decode(body) do
    :json.decode(body)
  rescue
    _ -> :error
  end

  # -- timers --

  # Registration is a message rather than a return value because the timer
  # must live in the runner, not in the throwaway process this function runs
  # in. Validation the runner does (clamping, the cap on count) is logged
  # there, where the log is.
  defp mayo_timer(owner, kind, [ms, fname | _]) when is_number(ms) and is_binary(fname) do
    send(owner, {:pickle_timer_req, kind, trunc(ms), fname})
    [true]
  end

  defp mayo_timer(_owner, _kind, _), do: [nil, "timer needs (ms, function_name)"]
end
