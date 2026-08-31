defmodule MayonnaiOS.Files.WorkerTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Files
  alias MayonnaiOS.Files.Worker

  setup do
    id = System.unique_integer([:positive])
    source_root = Path.join(System.tmp_dir!(), "files-worker-source-#{id}")
    dest_root = Path.join(System.tmp_dir!(), "files-worker-dest-#{id}")
    File.mkdir_p!(Path.join(source_root, "tree"))
    File.mkdir_p!(dest_root)
    File.write!(Path.join(source_root, "tree/data"), "payload")

    Application.put_env(:mayonnaios, :file_roots, [
      %{key: "source", path: source_root, note: ""},
      %{key: "dest", path: dest_root, note: ""}
    ])

    unless Process.whereis(MayonnaiOS.Files.Worker.Sessions),
      do: start_supervised!(Worker.sessions())

    on_exit(fn ->
      Application.delete_env(:mayonnaios, :file_roots)
      File.rm_rf(source_root)
      File.rm_rf(dest_root)
    end)

    {:ok, source} = Files.at("source", ["tree"])
    {:ok, destination} = Files.at("dest")
    %{source: source, destination: destination, dest_root: dest_root}
  end

  test "tags phase, progress, and one terminal result", context do
    opts = [space: fn _ -> {:ok, %{free: 1_000_000_000, device: "test"}} end]

    assert {:ok, pid, ref} =
             Worker.start({:copy, context.source, context.destination}, self(), opts)

    assert_receive {:files_job, ^pid, ^ref, %{phase: :scanning}}
    assert_receive {:files_job, ^pid, ^ref, {:result, :ok}}, 1_000
    assert File.read!(Path.join(context.dest_root, "tree/data")) == "payload"
    refute_receive {:files_job, ^pid, ^ref, {:result, _}}
  end

  test "owner loss cancels a temporary worker", context do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid, ref} =
          Worker.start({:copy, context.source, context.destination}, self(),
            space: fn _ -> {:ok, %{free: 1_000_000_000, device: "test"}} end,
            cancelled?: fn -> true end
          )

        send(parent, {:worker, pid, ref})
        Process.sleep(:infinity)
      end)

    assert_receive {:worker, pid, _ref}
    monitor = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
  end
end
