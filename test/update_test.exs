defmodule MayonnaiOS.UpdateTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Update

  # Everything here is the part that decides what the panel says without
  # touching the network -- `check/1`'s `:fetch` and `download/2`'s `:get`
  # are the seams, the same way `MayonnaiOS.Files.space/1`'s `:run` and
  # `MayonnaiOS.Launcher.Signals` are elsewhere in this codebase. `apply/2`'s
  # `:cmd` is the same idea for `fwup` itself.

  defp ok_json(term), do: {:ok, %{status: 200, body: :json.encode(term) |> IO.iodata_to_binary()}}

  defp release(overrides \\ %{}) do
    Map.merge(
      %{
        "tag_name" => "v0.2.0",
        "body" => "Notes.",
        "published_at" => "2026-01-01T00:00:00Z",
        "assets" => [
          %{
            "name" => "mayonnaios_rg40xxv.fw",
            "browser_download_url" => "https://example.test/mayonnaios_rg40xxv.fw",
            "size" => 12_345
          }
        ]
      },
      overrides
    )
  end

  describe "check/1" do
    test "a newer tag with a matching asset is available" do
      fetch = fn _url -> ok_json(release()) end

      assert {:ok, result} =
               Update.check(fetch: fetch, target: :rg40xxv, current_version: "0.1.0")

      assert result.available?
      assert result.comparable?
      assert result.current == "0.1.0"
      assert result.latest == "0.2.0"
      assert result.tag == "v0.2.0"
      assert result.notes == "Notes."

      assert result.asset == %{
               name: "mayonnaios_rg40xxv.fw",
               url: "https://example.test/mayonnaios_rg40xxv.fw",
               size: 12_345
             }
    end

    test "the same version is not an update" do
      fetch = fn _url -> ok_json(release(%{"tag_name" => "v0.1.0"})) end

      assert {:ok, result} =
               Update.check(fetch: fetch, target: :rg40xxv, current_version: "0.1.0")

      refute result.available?
      assert result.comparable?
    end

    test "a tag older than what is running is not an update" do
      fetch = fn _url -> ok_json(release(%{"tag_name" => "v0.1.0"})) end

      assert {:ok, result} =
               Update.check(fetch: fetch, target: :rg40xxv, current_version: "0.2.0")

      refute result.available?
    end

    test "a release with no matching asset still reports the version" do
      fetch = fn _url ->
        ok_json(release(%{"assets" => [%{"name" => "mayonnaios_rpi0.fw", "size" => 1}]}))
      end

      assert {:ok, result} =
               Update.check(fetch: fetch, target: :rg40xxv, current_version: "0.1.0")

      assert result.available?
      assert result.asset == nil
    end

    test "a release with no assets at all" do
      fetch = fn _url -> ok_json(release(%{"assets" => []})) end

      assert {:ok, result} =
               Update.check(fetch: fetch, target: :rg40xxv, current_version: "0.1.0")

      assert result.asset == nil
    end

    test "an unparseable tag is reported without crashing" do
      fetch = fn _url -> ok_json(release(%{"tag_name" => "not-a-version"})) end

      assert {:ok, result} =
               Update.check(fetch: fetch, target: :rg40xxv, current_version: "0.1.0")

      refute result.comparable?
      refute result.available?
      assert result.latest == "not-a-version"
    end

    test "a repository with no releases at all is a 404" do
      fetch = fn _url -> {:ok, %{status: 404, body: ""}} end
      assert {:error, :no_releases} = Update.check(fetch: fetch)
    end

    test "an unexpected HTTP status is reported" do
      fetch = fn _url -> {:ok, %{status: 500, body: ""}} end
      assert {:error, {:http_status, 500}} = Update.check(fetch: fetch)
    end

    test "no network is reported rather than raising" do
      fetch = fn _url -> {:error, :timeout} end
      assert {:error, {:http, :timeout}} = Update.check(fetch: fetch)
    end

    test "a body that is not JSON is reported rather than raising" do
      fetch = fn _url -> {:ok, %{status: 200, body: "not json"}} end
      assert {:error, :invalid_response} = Update.check(fetch: fetch)
    end
  end

  describe "compare_versions/2" do
    test "lt, eq and gt" do
      assert Update.compare_versions("0.1.0", "0.2.0") == {:ok, :lt}
      assert Update.compare_versions("0.2.0", "0.2.0") == {:ok, :eq}
      assert Update.compare_versions("0.2.0", "0.1.0") == {:ok, :gt}
    end

    test "an unparseable version on either side" do
      assert Update.compare_versions("garbage", "0.2.0") == {:error, :unparseable}
      assert Update.compare_versions("0.1.0", "garbage") == {:error, :unparseable}
    end
  end

  describe "normalize_tag/1" do
    test "strips a leading v or V" do
      assert Update.normalize_tag("v1.2.3") == "1.2.3"
      assert Update.normalize_tag("V1.2.3") == "1.2.3"
    end

    test "leaves an already-bare version alone" do
      assert Update.normalize_tag("1.2.3") == "1.2.3"
    end

    test "leaves anything else in place for compare_versions/2 to reject" do
      assert Update.normalize_tag("release-42") == "release-42"
    end
  end

  describe "running_version/0" do
    test "reads the running OTP release's own version" do
      assert Update.running_version() == "0.1.0"
    end
  end

  describe "enough_space?/2" do
    test "nil needed bytes always passes" do
      assert Update.enough_space?(System.tmp_dir!(), nil)
    end

    test "an absurd requirement does not fit" do
      refute Update.enough_space?(System.tmp_dir!(), 1_000_000_000_000_000)
    end

    test "a small requirement fits" do
      assert Update.enough_space?(System.tmp_dir!(), 1)
    end

    test "a location with no filesystem to measure fails closed" do
      refute Update.enough_space?("/definitely/not/a/real/path/at/all", 1)
    end
  end

  describe "download/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "update-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dest: Path.join(dir, "firmware.fw")}
    end

    test "writes what the injected getter is given", %{dest: dest} do
      asset = %{name: "x.fw", url: "https://example.test/x.fw", size: 4}
      get = fn _url, path -> File.write!(path, "data") end

      assert :ok = Update.download(asset, dest, get: get)
      assert File.read!(dest) == "data"
    end

    test "a getter's error is returned", %{dest: dest} do
      asset = %{name: "x.fw", url: "https://example.test/x.fw", size: 4}
      get = fn _url, _path -> {:error, {:http_status, 404}} end

      assert {:error, {:http_status, 404}} = Update.download(asset, dest, get: get)
    end

    test "refuses before starting when there is not enough space", %{dest: dest} do
      asset = %{name: "x.fw", url: "https://example.test/x.fw", size: 1_000_000_000_000_000}
      get = fn _url, _path -> flunk("must not be called when there is no room") end

      assert {:error, {:insufficient_space, _needed, _dir}} =
               Update.download(asset, dest, get: get)

      refute File.exists?(dest)
    end

    test "an asset with no reported size is not blocked by the space check", %{dest: dest} do
      asset = %{name: "x.fw", url: "https://example.test/x.fw", size: nil}

      get = fn _url, path ->
        File.write!(path, "ok")
        :ok
      end

      assert :ok = Update.download(asset, dest, get: get)
    end
  end

  describe "apply/2" do
    test "runs fwup's upgrade task against the given device" do
      cmd = fn path, args, _opts ->
        send(self(), {:cmd, path, args})
        {"Success", 0}
      end

      assert {:ok, "Success"} =
               Update.apply("/tmp/x.fw",
                 devpath: "/dev/mmcblk0",
                 fwup_path: "/usr/bin/fwup",
                 cmd: cmd
               )

      assert_received {:cmd, "/usr/bin/fwup", args}
      assert "--apply" in args
      assert "--no-unmount" in args
      assert Enum.at(args, Enum.find_index(args, &(&1 == "-i")) + 1) == "/tmp/x.fw"
      assert Enum.at(args, Enum.find_index(args, &(&1 == "-t")) + 1) == "upgrade"
      assert Enum.at(args, Enum.find_index(args, &(&1 == "-d")) + 1) == "/dev/mmcblk0"
    end

    test "a nonzero exit is reported with fwup's own output" do
      cmd = fn _path, _args, _opts -> {"Error: bad archive", 1} end

      assert {:error, {:fwup_failed, 1, "Error: bad archive"}} =
               Update.apply("/tmp/x.fw",
                 devpath: "/dev/mmcblk0",
                 fwup_path: "/usr/bin/fwup",
                 cmd: cmd
               )
    end

    test "a missing device path is reported without shelling out" do
      cmd = fn _path, _args, _opts -> flunk("must not run fwup with no devpath") end

      assert {:error, :no_devpath} =
               Update.apply("/tmp/x.fw", devpath: nil, fwup_path: "/usr/bin/fwup", cmd: cmd)
    end

    test "a missing fwup binary is reported without shelling out" do
      cmd = fn _path, _args, _opts -> flunk("must not run a nil executable") end

      assert {:error, :fwup_not_found} =
               Update.apply("/tmp/x.fw", devpath: "/dev/mmcblk0", fwup_path: nil, cmd: cmd)
    end
  end
end
