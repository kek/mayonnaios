defmodule MayonnaiOS.AppPartitionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MayonnaiOS.AppPartition

  # A /proc/mounts of the shape the device actually has, trimmed to the two
  # lines that matter. The f2fs option list is copied from the real one.
  defp proc_mounts(root_options) do
    """
    /dev/root / squashfs ro,relatime 0 0
    /dev/mmcblk0p4 /root f2fs #{root_options} 0 0
    /dev/mmcblk2p1 /root/mnt/games exfat rw,nosuid,nodev,noexec,relatime 0 0
    """
  end

  defp write!(contents) do
    path = Path.join(System.tmp_dir!(), "mounts-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  @discarding "rw,lazytime,nodev,relatime,background_gc=on,discard,discard_unit=block,acl"
  @not_discarding "rw,lazytime,nodev,relatime,background_gc=on,nodiscard,acl"

  defp ok_runner(parent) do
    fn cmd, args, opts ->
      send(parent, {:ran, cmd, args, opts})
      {"", 0}
    end
  end

  test "remounts nodiscard and confirms it from /proc/mounts" do
    parent = self()

    assert :ok =
             AppPartition.disable_discard(
               mount_point: "/root",
               proc_mounts: write!(proc_mounts(@not_discarding)),
               run: ok_runner(parent)
             )

    assert_received {:ran, "mount", ["-o", "remount,nodiscard", "/root"], _opts}
  end

  # The one that matters. mount exiting 0 is not the claim being made -- the
  # claim is that this mount is no longer discarding. Trusting the exit status
  # is exactly how this project has been fooled before.
  test "reports failure when mount succeeds but the mount is still discarding" do
    log =
      capture_log(fn ->
        assert {:error, {:still_discarding, options}} =
                 AppPartition.disable_discard(
                   mount_point: "/root",
                   proc_mounts: write!(proc_mounts(@discarding)),
                   run: ok_runner(self())
                 )

        assert "discard" in options
      end)

    assert log =~ "still discarding"
  end

  test "reports the exit code and output when mount itself fails" do
    runner = fn _cmd, _args, _opts -> {"mount: /root: cannot remount", 32} end

    capture_log(fn ->
      assert {:error, {:mount_failed, 32, "mount: /root: cannot remount"}} =
               AppPartition.disable_discard(
                 mount_point: "/root",
                 proc_mounts: write!(proc_mounts(@not_discarding)),
                 run: runner
               )
    end)
  end

  test "survives there being no mount binary at all" do
    runner = fn _cmd, _args, _opts -> raise ErlangError, original: :enoent end

    capture_log(fn ->
      assert {:error, {:mount_unavailable, _}} =
               AppPartition.disable_discard(
                 mount_point: "/root",
                 proc_mounts: write!(proc_mounts(@not_discarding)),
                 run: runner
               )
    end)
  end

  test "reports when the mount point is not mounted at all" do
    capture_log(fn ->
      assert {:error, {:not_mounted, "/nowhere"}} =
               AppPartition.disable_discard(
                 mount_point: "/nowhere",
                 proc_mounts: write!(proc_mounts(@not_discarding)),
                 run: ok_runner(self())
               )
    end)
  end

  test "does not mistake /root/mnt/games for /root" do
    # The games card line contains "/root" as a prefix, and it is exFAT, which
    # has no discard option at all. Matching on the prefix would read the wrong
    # line and conclude the wrong thing about it.
    assert {:error, {:still_discarding, _}} =
             capture_and_return(fn ->
               AppPartition.disable_discard(
                 mount_point: "/root",
                 proc_mounts: write!(proc_mounts(@discarding)),
                 run: ok_runner(self())
               )
             end)
  end

  test "reports when /proc/mounts cannot be read" do
    capture_log(fn ->
      assert {:error, :enoent} =
               AppPartition.disable_discard(
                 mount_point: "/root",
                 proc_mounts: Path.join(System.tmp_dir!(), "definitely-not-here"),
                 run: ok_runner(self())
               )
    end)
  end

  test "mount point defaults to /root" do
    assert AppPartition.mount_point() == "/root"
  end

  defp capture_and_return(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:result, fun.()}) end)
    receive do: ({:result, result} -> result)
  end
end
