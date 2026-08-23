defmodule MayonnaiOS.Pickles.WebTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias MayonnaiOS.Web
  import MayonnaiOS.PickleFixtures

  # The whole deploy loop, through the router: upload, list, call, log,
  # delete. This is the path the Claude skill and a phone both take, so the
  # tests speak HTTP rather than calling MayonnaiOS.Pickles directly.

  @opts Web.init([])

  setup do
    root = Path.join(System.tmp_dir!(), "pickles-web-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:mayonnaios, :pickles_root)
    Application.put_env(:mayonnaios, :pickles_root, root)

    on_exit(fn ->
      # Stop anything these tests started before the root goes away.
      for %{name: name, running: true} <- MayonnaiOS.Pickles.list() do
        MayonnaiOS.Pickles.stop(name)
      end

      case prev do
        nil -> Application.delete_env(:mayonnaios, :pickles_root)
        val -> Application.put_env(:mayonnaios, :pickles_root, val)
      end

      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp request(conn), do: Web.call(conn, @opts)

  defp body(conn), do: :json.decode(conn.resp_body)

  defp upload(name, lua, fields \\ %{}) do
    tar = pickle_tarball(System.tmp_dir!(), name, lua, fields)
    bytes = File.read!(tar)
    File.rm!(tar)
    request(conn(:put, "/api/pickles/#{name}", bytes))
  end

  test "the deploy loop: upload, start, call, log, delete" do
    lua = """
    function on_start()
      mayo.log("greeter up")
    end

    function greet(who)
      return "hello " .. who
    end
    """

    conn = upload("greeter", lua)
    assert conn.status == 201
    assert %{"name" => "greeter"} = body(conn)

    conn = request(conn(:post, "/api/pickles/greeter/start"))
    assert conn.status == 200

    conn = request(conn(:get, "/api/pickles"))
    assert conn.status == 200
    assert %{"pickles" => [%{"name" => "greeter", "running" => true}]} = body(conn)

    conn = request(conn(:post, "/api/pickles/greeter/call/greet", ~s(["world"])))
    assert conn.status == 200
    assert %{"results" => ["hello world"]} = body(conn)

    conn = request(conn(:get, "/api/pickles/greeter/log"))
    assert conn.status == 200
    assert %{"status" => "running", "log" => log} = body(conn)
    assert Enum.any?(log, &(&1["msg"] == "greeter up"))

    conn = request(conn(:delete, "/api/pickles/greeter"))
    assert conn.status == 200

    conn = request(conn(:get, "/api/pickles"))
    assert body(conn) == %{"pickles" => []}
  end

  test "an autostart pickle is running as soon as it lands" do
    conn = upload("auto", "function ping() return true end", %{"autostart" => true})
    assert conn.status == 201

    conn = request(conn(:post, "/api/pickles/auto/call/ping"))
    assert conn.status == 200
    assert %{"results" => [true]} = body(conn)
  end

  test "re-uploading a running pickle swaps the code under the same name" do
    assert upload("swap", "function v() return 1 end", %{"autostart" => true}).status == 201
    assert upload("swap", "function v() return 2 end", %{"autostart" => true}).status == 201

    conn = request(conn(:post, "/api/pickles/swap/call/v"))
    assert %{"results" => [2]} = body(conn)
  end

  test "calling a pickle that is not running is 409" do
    assert upload("idle", "function x() return 1 end").status == 201

    conn = request(conn(:post, "/api/pickles/idle/call/x"))
    assert conn.status == 409
  end

  test "calling a function the script does not define is 404" do
    assert upload("small", "function x() return 1 end", %{"autostart" => true}).status == 201

    conn = request(conn(:post, "/api/pickles/small/call/y"))
    assert conn.status == 404
  end

  test "bad names and bad bodies are the client's fault" do
    conn = request(conn(:put, "/api/pickles/Bad%20Name", "whatever"))
    assert conn.status == 400

    conn = request(conn(:put, "/api/pickles/junk", "not a tarball"))
    assert conn.status == 400
  end

  test "arguments must be a JSON array" do
    assert upload("argsy", "function x() return 1 end", %{"autostart" => true}).status == 201

    conn = request(conn(:post, "/api/pickles/argsy/call/x", ~s({"not": "an array"})))
    assert conn.status == 400
  end

  test "unknown capabilities fail the upload with the reason" do
    conn = upload("wants-root", "x = 1", %{"capabilities" => ["spawn_processes"]})
    assert conn.status == 400
    assert %{"error" => error} = body(conn)
    assert error =~ "unknown_capability"
  end
end
