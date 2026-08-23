defmodule MayonnaiOS.Pickles.SandboxTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Pickles.Sandbox

  # The sandbox is the security boundary, so these tests are about what a
  # script cannot do as much as what it can. Each builds a state the way the
  # Runner does and drives it through load/call, the only two doors.

  defp manifest(fields) do
    Map.merge(
      %{
        name: "test",
        version: "1",
        description: "",
        main: "main.lua",
        capabilities: [],
        hosts: nil,
        autostart: false
      },
      fields
    )
  end

  defp sandbox(fields \\ %{}, opts \\ []) do
    Sandbox.new(manifest(fields), self(), opts)
  end

  defp run(lua, chunk, fname, args \\ []) do
    {:ok, lua} = Sandbox.load(lua, chunk)
    Sandbox.call(lua, fname, args)
  end

  describe "what is stripped" do
    test "os.execute, io and require are gone" do
      lua = sandbox()

      chunk = """
      function probe()
        return type(io), type(os.execute), type(require), type(load)
      end
      """

      # :luerl_sandbox replaces them with the atom `sandboxed`, which Lua
      # sees as a string -- the point is that none of them is callable.
      assert {:ok, types, _} = run(lua, chunk, "probe")
      refute "function" in types
      refute "table" in types
    end

    test "capabilities not granted are absent" do
      lua = sandbox()

      chunk = """
      function probe()
        return type(mayo.http), type(mayo.lan), type(mayo.storage), type(mayo.timer)
      end
      """

      assert {:ok, ["nil", "nil", "nil", "nil"], _} = run(lua, chunk, "probe")
    end

    test "granted capabilities are present" do
      lua = sandbox(%{capabilities: ["http", "lan", "storage", "timers"]})

      chunk = """
      function probe()
        return type(mayo.http.get), type(mayo.lan.tcp), type(mayo.storage.set), type(mayo.timer.every)
      end
      """

      assert {:ok, ["function", "function", "function", "function"], _} = run(lua, chunk, "probe")
    end
  end

  describe "the always-on API" do
    test "mayo.log sends to the owner and mayo.name is the pickle's" do
      lua = sandbox()

      chunk = """
      function hello()
        mayo.log("hello from " .. mayo.name)
        return true
      end
      """

      assert {:ok, [true], _} = run(lua, chunk, "hello")
      assert_receive {:pickle_log, "hello from test"}
    end

    test "mayo.json round-trips" do
      lua = sandbox()

      chunk = """
      function roundtrip(s)
        local v = mayo.json.decode(s)
        v.count = v.count + 1
        return mayo.json.encode(v)
      end
      """

      assert {:ok, [json], _} = run(lua, chunk, "roundtrip", [~s({"count": 1})])
      assert :json.decode(json) == %{"count" => 2}
    end

    test "bad json is nil and a reason, not a dead call" do
      lua = sandbox()

      chunk = """
      function bad()
        local v, err = mayo.json.decode("{nope")
        return v, err
      end
      """

      assert {:ok, [nil, "not valid json"], _} = run(lua, chunk, "bad")
    end
  end

  describe "values crossing the boundary" do
    test "array tables become lists, keyed tables become maps" do
      lua = sandbox()

      chunk = """
      function shapes()
        return {1, 2, 3}, {name = "lamp", on = true}
      end
      """

      assert {:ok, [[1, 2, 3], %{"name" => "lamp", "on" => true}], _} = run(lua, chunk, "shapes")
    end

    test "maps and lists pass in as tables" do
      lua = sandbox()

      chunk = """
      function pick(t, xs)
        return t.device, xs[2]
      end
      """

      assert {:ok, ["lamp-1", "b"], _} =
               run(lua, chunk, "pick", [%{"device" => "lamp-1"}, ["a", "b"]])
    end

    test "a lua error comes back as an error, not an exit" do
      lua = sandbox()
      assert {:error, "lua error:" <> _} = run(lua, "function boom() error('no') end", "boom")
    end

    test "calling an undefined function is an error" do
      lua = sandbox()
      {:ok, lua} = Sandbox.load(lua, "x = 1")
      refute Sandbox.function?(lua, "nothing")
      assert {:error, _} = Sandbox.call(lua, "nothing", [])
    end
  end

  describe "http" do
    test "the manifest's hosts list gates requests before the transport" do
      test_pid = self()

      impl = fn method, url, _headers, _body ->
        send(test_pid, {:http, method, url})
        {:ok, 200, "ok"}
      end

      lua =
        sandbox(%{capabilities: ["http"], hosts: ["allowed.example"]}, http_impl: impl)

      chunk = """
      function fetch(url)
        return mayo.http.get(url)
      end
      """

      assert {:ok, ["ok", 200], lua2} = run(lua, chunk, "fetch", ["https://allowed.example/x"])
      assert_receive {:http, :get, "https://allowed.example/x"}

      assert {:ok, [nil, "http: host not in this pickle's allowlist"], _} =
               Sandbox.call(lua2, "fetch", ["https://evil.example/x"])

      refute_receive {:http, _, _}
    end

    test "no hosts list means the capability is the only gate" do
      impl = fn :post, url, headers, body ->
        {:ok, 201, url <> "|" <> headers["x-h"] <> "|" <> body}
      end

      lua = sandbox(%{capabilities: ["http"]}, http_impl: impl)

      chunk = """
      function send()
        return mayo.http.post("http://anywhere.example/", "payload", {["x-h"] = "v"})
      end
      """

      assert {:ok, ["http://anywhere.example/|v|payload", 201], _} = run(lua, chunk, "send")
    end
  end

  describe "storage" do
    test "set, get and delete persist through the state file" do
      path =
        Path.join(System.tmp_dir!(), "pickle-state-#{System.unique_integer([:positive])}.json")

      on_exit(fn -> File.rm(path) end)

      lua = sandbox(%{capabilities: ["storage"]}, state_path: path)

      chunk = """
      function remember(k, v) return mayo.storage.set(k, v) end
      function recall(k) return mayo.storage.get(k) end
      function forget(k) return mayo.storage.delete(k) end
      """

      {:ok, lua} = Sandbox.load(lua, chunk)

      assert {:ok, [true], lua} = Sandbox.call(lua, "remember", ["ip", "192.168.1.40"])
      assert {:ok, ["192.168.1.40"], lua} = Sandbox.call(lua, "recall", ["ip"])

      # A fresh state -- a reinstall, a reboot -- still sees it.
      fresh = sandbox(%{capabilities: ["storage"]}, state_path: path)
      {:ok, fresh} = Sandbox.load(fresh, chunk)
      assert {:ok, ["192.168.1.40"], _} = Sandbox.call(fresh, "recall", ["ip"])

      assert {:ok, [true], lua} = Sandbox.call(lua, "forget", ["ip"])
      assert {:ok, [nil], _} = Sandbox.call(lua, "recall", ["ip"])
    end
  end

  describe "timers" do
    test "registration is a message to the owner" do
      lua = sandbox(%{capabilities: ["timers"]})

      chunk = """
      function arm()
        mayo.timer.every(5000, "tick")
        mayo.timer.once(100, "later")
        return true
      end
      """

      assert {:ok, [true], _} = run(lua, chunk, "arm")
      assert_receive {:pickle_timer_req, :every, 5000, "tick"}
      assert_receive {:pickle_timer_req, :once, 100, "later"}
    end
  end

  describe "exec/2" do
    test "an infinite loop is killed by the clock, not by anyone's patience" do
      lua = sandbox()
      {:ok, lua} = Sandbox.load(lua, "function spin() while true do end end")

      assert {:error, :timeout} = Sandbox.exec(fn -> Sandbox.call(lua, "spin", []) end, 250)
    end

    test "a normal result passes through" do
      assert {:ok, 42} = Sandbox.exec(fn -> {:ok, 42} end, 1_000)
    end
  end
end
