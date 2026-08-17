defmodule MayonnaiOS.BundleTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Bundle

  # The download is the thin part and needs a network; everything that decides
  # whether a bundle is safe to run happens after it, so that is what is
  # tested here.

  setup do
    root = Path.join(System.tmp_dir!(), "bundle-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp tarball(root, files) do
    dir = Path.join(root, "src")
    File.mkdir_p!(Path.join(dir, "bin"))

    Enum.each(files, fn {name, contents} ->
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    path = Path.join(root, "payload.tar.gz")

    entries =
      Enum.map(files, fn {name, _} ->
        {String.to_charlist(name), String.to_charlist(Path.join(dir, name))}
      end)

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    path
  end

  defp sha256(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp spec(path, root, overrides \\ %{}) do
    Map.merge(
      %{
        name: "retroarch",
        version: "1.22.2",
        url: "file://#{path}",
        sha256: sha256(path)
      },
      overrides
    )
    |> Map.put(:__root__, root)
  end

  describe "checksum gate" do
    test "a tarball whose hash does not match is refused", %{root: root} do
      path = tarball(root, [{"bin/retroarch", "#!/bin/sh\n"}])
      bad = spec(path, root, %{sha256: String.duplicate("00", 32)})

      assert {:error, {:checksum_mismatch, actual, expected}} =
               Bundle.install_tarball(path, bad, root)

      assert actual == sha256(path)
      assert expected == String.duplicate("00", 32)
    end

    test "nothing is unpacked when the hash is wrong", %{root: root} do
      # The point of hashing before extracting: a bad archive must not get to
      # write any path at all, let alone one of its own choosing.
      path = tarball(root, [{"bin/retroarch", "#!/bin/sh\n"}])
      bad = spec(path, root, %{sha256: String.duplicate("11", 32)})

      assert {:error, _} = Bundle.install_tarball(path, bad, root)
      refute File.exists?(Path.join([root, "retroarch", "1.22.2"]))
      refute File.exists?(Path.join([root, "retroarch", "current"]))
    end

    test "case does not matter in the configured checksum", %{root: root} do
      path = tarball(root, [{"bin/retroarch", "x"}])
      upper = spec(path, root, %{sha256: String.upcase(sha256(path))})

      assert {:ok, _} = Bundle.install_tarball(path, upper, root)
    end
  end

  describe "installing" do
    test "unpacks, publishes current, and writes a manifest", %{root: root} do
      path = tarball(root, [{"bin/retroarch", "#!/bin/sh\necho hi\n"}])
      s = spec(path, root)

      assert {:ok, final} = Bundle.install_tarball(path, s, root)
      assert final == Path.join([root, "retroarch", "1.22.2"])
      assert File.read!(Path.join(final, "bin/retroarch")) == "#!/bin/sh\necho hi\n"

      # current is a relative symlink to the version directory
      assert {:ok, "1.22.2"} = File.read_link(Path.join([root, "retroarch", "current"]))
      assert File.read!(Path.join([root, "retroarch", "current", "bin/retroarch"])) =~ "echo hi"

      assert %{"version" => "1.22.2", "name" => "retroarch"} = Bundle.installed("retroarch", root)
    end

    test "is idempotent for the same version and checksum", %{root: root} do
      path = tarball(root, [{"bin/retroarch", "x"}])
      s = spec(path, root)

      assert {:ok, _} = Bundle.install_tarball(path, s, root)
      assert Bundle.installed?(s, root)
      assert {:ok, :already_installed} = Bundle.install(s, root: root)
    end

    test "a manifest without its directory does not count as installed", %{root: root} do
      # Intent is not fact. A wiped data partition leaves the menu offering a
      # program that is not there.
      path = tarball(root, [{"bin/retroarch", "x"}])
      s = spec(path, root)

      assert {:ok, _} = Bundle.install_tarball(path, s, root)
      File.rm_rf!(Path.join([root, "retroarch", "1.22.2"]))

      refute Bundle.installed?(s, root)
    end

    test "a new version does not disturb the old one until it is ready", %{root: root} do
      old = tarball(root, [{"bin/retroarch", "old"}])
      s1 = spec(old, root)
      assert {:ok, _} = Bundle.install_tarball(old, s1, root)

      new = tarball(root, [{"bin/retroarch", "new"}])
      s2 = spec(new, root, %{version: "1.23.0", sha256: sha256(new)})
      assert {:ok, _} = Bundle.install_tarball(new, s2, root)

      # Both versions on disk, current moved to the new one.
      assert File.dir?(Path.join([root, "retroarch", "1.22.2"]))
      assert File.dir?(Path.join([root, "retroarch", "1.23.0"]))
      assert {:ok, "1.23.0"} = File.read_link(Path.join([root, "retroarch", "current"]))
      assert File.read!(Path.join([root, "retroarch", "current", "bin/retroarch"])) == "new"

      # And the old version is still intact, so a rollback is a symlink move.
      assert File.read!(Path.join([root, "retroarch", "1.22.2", "bin/retroarch"])) == "old"
    end

    test "a corrupt archive with a valid checksum fails without publishing", %{root: root} do
      path = Path.join(root, "notatarball.tar.gz")
      File.write!(path, "this is not a gzip stream")
      s = spec(path, root)

      assert {:error, {:extract, _}} = Bundle.install_tarball(path, s, root)
      refute File.exists?(Path.join([root, "retroarch", "current"]))
    end
  end

  describe "current/2" do
    test "is nil before anything is installed", %{root: root} do
      assert Bundle.current("retroarch", root) == nil
    end

    test "points at something runnable afterwards", %{root: root} do
      path = tarball(root, [{"bin/retroarch", "#!/bin/sh\n"}])
      assert {:ok, _} = Bundle.install_tarball(path, spec(path, root), root)

      current = Bundle.current("retroarch", root)
      assert current != nil
      assert File.exists?(Path.join(current, "bin/retroarch"))
    end
  end
end
