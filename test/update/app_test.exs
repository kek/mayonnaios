defmodule MayonnaiOS.Update.AppTest do
  # Not async: the app is a named process.
  use ExUnit.Case, async: false

  alias MayonnaiOS.Update.App
  alias MayonnaiOS.Scene.Update, as: Scene

  @advance :btn_b
  @menu :btn_mode

  defp release(overrides \\ %{}) do
    Map.merge(
      %{
        "tag_name" => "v0.2.0",
        "assets" => [
          %{
            "name" => "mayonnaios_rg40xxv.fw",
            "browser_download_url" => "https://example.test/x.fw",
            "size" => 8
          }
        ]
      },
      overrides
    )
  end

  defp ok_json(term), do: {:ok, %{status: 200, body: :json.encode(term) |> IO.iodata_to_binary()}}

  defp press(key, value \\ 1), do: App.input([{:ev_key, key, value}])

  defp tmp_path do
    Path.join(System.tmp_dir!(), "update-app-test-#{System.unique_integer([:positive])}.fw")
  end

  # The check that runs on init is asynchronous, so it may already have
  # finished by the time a test could register a watcher for it -- the
  # tests below poll the snapshot for that first transition instead of
  # asserting on a pushed message, and only start watching once the app is
  # already sitting in a known state, which removes the race for every
  # transition after that.
  defp await_status(statuses, tries \\ 200) do
    snapshot = App.snapshot()

    cond do
      snapshot.status in statuses ->
        snapshot

      tries > 0 ->
        Process.sleep(2)
        await_status(statuses, tries - 1)

      true ->
        flunk("timed out waiting for status in #{inspect(statuses)}, got #{inspect(snapshot)}")
    end
  end

  describe "checking on start" do
    test "an available update is reported" do
      fetch = fn _url -> ok_json(release()) end

      start_supervised!(
        {App, check_opts: [fetch: fetch, target: :rg40xxv, current_version: "0.1.0"]}
      )

      snapshot = await_status([:available])
      assert snapshot.result.latest == "0.2.0"
      assert snapshot.result.asset.name == "mayonnaios_rg40xxv.fw"
    end

    test "no newer release is up to date" do
      fetch = fn _url -> ok_json(release(%{"tag_name" => "v0.1.0"})) end

      start_supervised!(
        {App, check_opts: [fetch: fetch, target: :rg40xxv, current_version: "0.1.0"]}
      )

      assert await_status([:up_to_date])
    end

    test "a check failure is shown rather than raised" do
      fetch = fn _url -> {:error, :timeout} end
      start_supervised!({App, check_opts: [fetch: fetch]})

      snapshot = await_status([:error])
      assert snapshot.error == {:http, :timeout}
    end

    test "a release with no matching firmware asset is still available" do
      fetch = fn _url -> ok_json(release(%{"assets" => []})) end

      start_supervised!(
        {App, check_opts: [fetch: fetch, target: :rg40xxv, current_version: "0.1.0"]}
      )

      snapshot = await_status([:available])
      assert snapshot.result.asset == nil
    end
  end

  describe "the buttons" do
    setup do
      fetch = fn _url -> ok_json(release()) end

      start_supervised!(
        {App, check_opts: [fetch: fetch, target: :rg40xxv, current_version: "0.1.0"]}
      )

      await_status([:available])
      :ok
    end

    test "Menu changes nothing" do
      before = App.snapshot()
      press(@menu)
      assert App.snapshot() == before
    end
  end

  describe "downloading and applying" do
    test "A on :available runs download and apply, and lands on :done" do
      fetch = fn _url -> ok_json(release()) end
      path = tmp_path()
      get = fn _url, dest -> File.write!(dest, "firmware-bytes") end
      cmd = fn _path, _args, _opts -> {"Success", 0} end

      start_supervised!(
        {App,
         check_opts: [fetch: fetch, target: :rg40xxv, current_version: "0.1.0"],
         download_opts: [get: get],
         apply_opts: [devpath: "/dev/mmcblk0", fwup_path: "/usr/bin/true", cmd: cmd],
         tmp_path: path}
      )

      await_status([:available])

      App.watch(self())
      press(@advance)

      assert_receive {:update_app, %{status: :downloading}}, 1_000
      assert_receive {:update_app, %{status: :done}}, 1_000

      # Tmpfs is freed once the transfer is over, either way.
      refute File.exists?(path)
    end

    test "a download failure becomes :error, and A retries the check" do
      fetch = fn _url -> ok_json(release()) end
      path = tmp_path()
      get = fn _url, _dest -> {:error, {:http_status, 500}} end

      start_supervised!(
        {App,
         check_opts: [fetch: fetch, target: :rg40xxv, current_version: "0.1.0"],
         download_opts: [get: get],
         tmp_path: path}
      )

      await_status([:available])

      App.watch(self())
      press(@advance)
      assert_receive {:update_app, %{status: :error, error: {:http_status, 500}}}, 1_000

      press(@advance)
      assert_receive {:update_app, %{status: :available}}, 1_000
    end

    test "an available update with no firmware asset is an immediate, local error" do
      fetch = fn _url -> ok_json(release(%{"assets" => []})) end

      start_supervised!(
        {App, check_opts: [fetch: fetch, target: :rg40xxv, current_version: "0.1.0"]}
      )

      await_status([:available])

      App.watch(self())
      press(@advance)
      assert_receive {:update_app, %{status: :error, error: :no_asset}}, 1_000
    end
  end

  describe "reboot" do
    test "A on :done calls the injected reboot function" do
      fetch = fn _url -> ok_json(release()) end
      path = tmp_path()
      get = fn _url, dest -> File.write!(dest, "firmware-bytes") end
      cmd = fn _path, _args, _opts -> {"Success", 0} end
      test_pid = self()

      start_supervised!(
        {App,
         check_opts: [fetch: fetch, target: :rg40xxv, current_version: "0.1.0"],
         download_opts: [get: get],
         apply_opts: [devpath: "/dev/mmcblk0", fwup_path: "/usr/bin/true", cmd: cmd],
         tmp_path: path,
         reboot: fn -> send(test_pid, :rebooted) end}
      )

      await_status([:available])

      App.watch(self())
      press(@advance)
      assert_receive {:update_app, %{status: :downloading}}, 1_000
      assert_receive {:update_app, %{status: :done}}, 1_000

      press(@advance)
      assert_receive :rebooted, 1_000
    end
  end

  describe "the scene" do
    # graph/1 is the tested surface: no viewport, no driver, no framebuffer.
    # Same helper the other scene tests use.
    defp texts(graph) do
      Scenic.Graph.reduce(graph, [], fn
        %Scenic.Primitive{module: Scenic.Primitive.Text, data: data}, acc -> [data | acc]
        _primitive, acc -> acc
      end)
    end

    test "not running" do
      assert Enum.member?(texts(Scene.graph(:stopped)), "Not running")
    end

    test "checking" do
      assert Enum.any?(
               texts(Scene.graph(%{status: :checking})),
               &String.contains?(&1, "Checking")
             )
    end

    test "idle invites a check" do
      assert Enum.any?(texts(Scene.graph(%{status: :idle})), &String.contains?(&1, "Press A"))
    end

    test "up to date names both versions" do
      result = %{current: "0.1.0", latest: "0.1.0", comparable?: true, tag: "v0.1.0"}
      texts = texts(Scene.graph(%{status: :up_to_date, result: result}))

      assert Enum.member?(texts, "Up to date")
      assert Enum.any?(texts, &(&1 =~ "0.1.0"))
    end

    test "available with an asset invites installing it" do
      result = %{
        current: "0.1.0",
        latest: "0.2.0",
        comparable?: true,
        tag: "v0.2.0",
        asset: %{name: "mayonnaios_rg40xxv.fw", url: "https://x/y.fw", size: 10}
      }

      texts = texts(Scene.graph(%{status: :available, result: result}))

      assert Enum.any?(texts, &(&1 =~ "0.2.0"))
      assert Enum.any?(texts, &String.contains?(&1, "downloads and installs"))
    end

    test "available with no asset says so instead of offering to install" do
      result = %{current: "0.1.0", latest: "0.2.0", tag: "v0.2.0", asset: nil}
      texts = texts(Scene.graph(%{status: :available, result: result}))

      assert Enum.any?(texts, &String.contains?(&1, "No firmware file"))
      refute Enum.any?(texts, &String.contains?(&1, "downloads and installs"))
    end

    test "downloading with a known size shows a percentage" do
      texts = texts(Scene.graph(%{status: :downloading, downloaded: 50, total: 100}))
      assert Enum.any?(texts, &String.contains?(&1, "50%"))
    end

    test "downloading with an unknown size does not divide by it" do
      texts = texts(Scene.graph(%{status: :downloading, downloaded: 50, total: nil}))
      assert Enum.member?(texts, "Size unknown")
    end

    test "done offers a reboot" do
      texts = texts(Scene.graph(%{status: :done}))
      assert Enum.member?(texts, "Installed")
      assert Enum.any?(texts, &String.contains?(&1, "reboots"))
    end

    test "an error names what went wrong" do
      texts = texts(Scene.graph(%{status: :error, error: :no_releases}))
      assert Enum.any?(texts, &String.contains?(&1, "no published releases"))
    end

    test "nothing is drawn above the shared status bar" do
      assert Scene.status_bar() > 0
    end
  end
end
