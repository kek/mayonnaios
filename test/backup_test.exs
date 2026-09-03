defmodule MayonnaiOS.BackupTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Backup

  setup do
    root = Path.join(System.tmp_dir!(), "backup-test-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    destination = Path.join(root, "card")
    File.mkdir_p!(Path.join(source, "empty"))
    File.mkdir_p!(destination)
    File.write!(Path.join(source, ".hidden"), "secret")
    File.write!(Path.join(source, "save.srm"), String.duplicate("save", 20_000))
    on_exit(fn -> File.rm_rf(root) end)

    opts = [
      sources: [%{key: "retroarch", path: source, exclude: [["cores"], ["mayonnaios.cfg"]]}],
      destination: destination,
      space: fn _ -> {:ok, 1_000_000_000} end,
      acquire: fn _ -> :ok end,
      release: fn _ -> :ok end,
      firmware: "test",
      device: "host"
    ]

    %{root: root, source: source, destination: destination, opts: opts}
  end

  test "preflight is deterministic and includes hidden files and empty directories", %{opts: opts} do
    assert {:ok, plan} = Backup.preflight(opts)
    assert plan.files == 2
    assert plan.bytes == 80_006
    assert Enum.map(plan.entries, & &1.components) == [[], [".hidden"], ["empty"], ["save.srm"]]
    assert plan.required_bytes == plan.bytes + 65_536
  end

  test "missing roots are recorded absent", %{opts: opts, root: root} do
    opts = Keyword.put(opts, :sources, [%{key: "missing", path: Path.join(root, "gone")}])
    assert {:ok, %{absent: ["missing"], files: 0, bytes: 0}} = Backup.preflight(opts)
  end

  test "symlinks and unknown space are rejected", %{opts: opts, source: source} do
    File.ln_s!("save.srm", Path.join(source, "link"))
    assert {:error, {:unsupported, :symlink, ["link"]}} = Backup.preflight(opts)
    File.rm!(Path.join(source, "link"))

    assert {:error, :space_unknown} =
             Backup.preflight(Keyword.put(opts, :space, fn _ -> {:error, :space_unknown} end))
  end

  test "run streams, verifies and publishes a portable backup", %{
    opts: opts,
    destination: destination
  } do
    assert {:ok, %{files: 2, bytes: 80_006, destination: current}} = Backup.run(opts)
    assert File.read!(Path.join([current, "data", "retroarch", ".hidden"])) == "secret"
    assert File.dir?(Path.join([current, "data", "retroarch", "empty"]))
    assert :ok = Backup.validate(current)
    assert File.read!(Path.join(current, "SHA256SUMS")) =~ "data/retroarch/save.srm"
    refute File.exists?(Path.join([destination, "MayonnaiOS", "backup-v1", ".staging"]))
  end

  test "cancellation never publishes current", %{opts: opts, destination: destination} do
    assert {:error, :cancelled} = Backup.run(Keyword.put(opts, :cancelled?, fn -> true end))
    refute File.exists?(Path.join([destination, "MayonnaiOS", "backup-v1", "current"]))
  end

  test "validator detects corruption", %{opts: opts} do
    assert {:ok, %{destination: current}} = Backup.run(opts)
    File.write!(Path.join([current, "data", "retroarch", ".hidden"]), "changed")
    assert {:error, _} = Backup.validate(current)
  end
end
