defmodule MayonnaiOS.WebTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias MayonnaiOS.Web

  # There is no authentication on this endpoint, so what stops it from being a
  # remote write primitive is entirely the filename check underneath. These
  # tests exercise it through the router, because that is the path a request
  # actually takes -- URL-decoding happens here and a check that only ever
  # sees already-decoded names would miss `%2e%2e%2f`.

  @systems [%{key: "snes", name: "Super Nintendo", extensions: [".sfc", ".zip"]}]

  @opts Web.init([])

  setup do
    base = Path.join(System.tmp_dir!(), "web-test-#{System.unique_integer([:positive])}")
    roms = Path.join(base, "roms")
    File.mkdir_p!(roms)

    prev = %{
      rom_root: Application.get_env(:mayonnaios, :rom_root),
      systems: Application.get_env(:mayonnaios, :systems),
      cores: Application.get_env(:mayonnaios, :cores),
      core_dir: Application.get_env(:mayonnaios, :core_dir),
      core_root: Application.get_env(:mayonnaios, :core_root),
      bundle_root: Application.get_env(:mayonnaios, :bundle_root)
    }

    Application.put_env(:mayonnaios, :rom_root, roms)
    Application.put_env(:mayonnaios, :systems, @systems)
    Application.put_env(:mayonnaios, :cores, %{})
    Application.put_env(:mayonnaios, :core_dir, Path.join(base, "active"))
    Application.put_env(:mayonnaios, :core_root, Path.join(base, "cores"))
    Application.put_env(:mayonnaios, :bundle_root, Path.join(base, "bundles"))

    on_exit(fn ->
      File.rm_rf(base)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:mayonnaios, k)
        {k, v} -> Application.put_env(:mayonnaios, k, v)
      end)
    end)

    %{roms: roms}
  end

  defp call(conn), do: Web.call(conn, @opts)
  defp json(conn), do: :json.decode(conn.resp_body)

  describe "the page" do
    test "is served, and is self-contained" do
      conn = call(conn(:get, "/"))

      assert conn.status == 200
      assert conn.resp_body =~ "<!doctype html>"
      # Inline everything. This device serves no static files and has no
      # route that would; a <link> or <script src> would 404 and leave a
      # blank page with no clue why.
      refute conn.resp_body =~ "<script src"
      refute conn.resp_body =~ "<link rel=\"stylesheet\""
    end
  end

  describe "GET /api/library" do
    test "lists configured systems and their contents", %{roms: roms} do
      File.mkdir_p!(Path.join(roms, "snes"))
      File.write!(Path.join([roms, "snes", "game.sfc"]), "12345")

      body = call(conn(:get, "/api/library")) |> json()

      assert [%{"key" => "snes", "entries" => [entry]}] = body["systems"]
      assert entry == %{"name" => "game.sfc", "size" => 5}
    end
  end

  describe "PUT /api/roms/:system/:filename" do
    test "stores the raw body", %{roms: roms} do
      conn =
        conn(:put, "/api/roms/snes/game.sfc", "cartridge")
        |> call()

      assert conn.status == 201
      assert json(conn) == %{"name" => "game.sfc", "size" => 9}
      assert File.read!(Path.join([roms, "snes", "game.sfc"])) == "cartridge"
    end

    test "decodes a percent-encoded filename", %{roms: roms} do
      conn = conn(:put, "/api/roms/snes/Super%20Mario%20World.sfc", "x") |> call()

      assert conn.status == 201
      assert File.exists?(Path.join([roms, "snes", "Super Mario World.sfc"]))
    end

    test "refuses a traversal that is percent-encoded", %{roms: roms} do
      # %2e%2e%2f is ../ -- the form that gets past a check done before
      # decoding. Plug decodes path segments itself, so this arrives as a
      # single segment, and the name check is what has to reject it.
      conn = conn(:put, "/api/roms/snes/%2e%2e%2fescaped.sfc", "x") |> call()

      assert conn.status == 400
      assert json(conn)["error"] == "bad_name"
      assert File.ls!(roms) == []
    end

    test "refuses an unknown system" do
      conn = conn(:put, "/api/roms/dreamcast/game.cdi", "x") |> call()

      assert conn.status == 404
      assert json(conn)["error"] == "unknown_system"
    end

    test "refuses an extension the system does not claim" do
      conn = conn(:put, "/api/roms/snes/notes.txt", "x") |> call()

      assert conn.status == 415
      assert json(conn)["error"] == "bad_extension"
    end

    test "refuses a body over the ceiling" do
      prev = Application.get_env(:mayonnaios, :max_upload_bytes)
      Application.put_env(:mayonnaios, :max_upload_bytes, 4)
      on_exit(fn -> restore(:max_upload_bytes, prev) end)

      conn = conn(:put, "/api/roms/snes/game.sfc", "far too much") |> call()

      assert conn.status == 413
    end
  end

  describe "DELETE /api/roms/:system/:filename" do
    test "deletes a file", %{roms: roms} do
      File.mkdir_p!(Path.join(roms, "snes"))
      File.write!(Path.join([roms, "snes", "game.sfc"]), "x")

      conn = call(conn(:delete, "/api/roms/snes/game.sfc"))

      assert conn.status == 200
      refute File.exists?(Path.join([roms, "snes", "game.sfc"]))
    end

    test "refuses a traversal rather than following it" do
      conn = call(conn(:delete, "/api/roms/snes/%2e%2e%2fx.sfc"))
      assert conn.status == 400
    end

    test "reports a missing file as missing" do
      conn = call(conn(:delete, "/api/roms/snes/absent.sfc"))
      assert conn.status == 404
    end
  end

  describe "POST /api/cores/:name/install" do
    test "refuses a core that is not in the catalogue" do
      conn = call(conn(:post, "/api/cores/nonesuch/install"))
      assert conn.status == 404
    end
  end

  test "an unknown route is a 404, not a crash" do
    conn = call(conn(:get, "/../etc/passwd"))
    assert conn.status == 404
  end

  defp restore(key, nil), do: Application.delete_env(:mayonnaios, key)
  defp restore(key, value), do: Application.put_env(:mayonnaios, key, value)
end
