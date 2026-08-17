defmodule MayonnaiOS.LibraryTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Library

  # These tests are about one thing: what a filename from an HTTP request is
  # allowed to become. Everything else here is bookkeeping. `/root` is the
  # only writable filesystem on the device and it holds the bundles, so an
  # escape from the ROM directory reaches executables.

  @systems [
    %{key: "snes", name: "Super Nintendo", extensions: [".sfc", ".smc", ".zip"]},
    %{key: "gb", name: "Game Boy", extensions: [".gb"]}
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "library-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_root = Application.get_env(:mayonnaios, :rom_root)
    prev_systems = Application.get_env(:mayonnaios, :systems)
    prev_max = Application.get_env(:mayonnaios, :max_upload_bytes)

    Application.put_env(:mayonnaios, :rom_root, root)
    Application.put_env(:mayonnaios, :systems, @systems)

    on_exit(fn ->
      File.rm_rf(root)
      restore(:rom_root, prev_root)
      restore(:systems, prev_systems)
      restore(:max_upload_bytes, prev_max)
    end)

    %{root: root}
  end

  defp restore(key, nil), do: Application.delete_env(:mayonnaios, key)
  defp restore(key, value), do: Application.put_env(:mayonnaios, key, value)

  # A reader in the shape Plug.Conn.read_body/2 has: {:more, chunk, rest} until
  # the last one, which is {:ok, chunk, rest}. The state is the list of chunks
  # still to come, which is all the state a real conn carries here too.
  defp reader do
    fn
      [] -> {:ok, "", []}
      [last] -> {:ok, last, []}
      [head | tail] -> {:more, head, tail}
    end
  end

  describe "safe_name/1" do
    test "accepts an ordinary filename" do
      assert {:ok, "Super Mario World.sfc"} = Library.safe_name("Super Mario World.sfc")
    end

    test "rejects anything with a path separator" do
      assert {:error, :bad_name} = Library.safe_name("../evil.sfc")
      assert {:error, :bad_name} = Library.safe_name("a/b.sfc")
      assert {:error, :bad_name} = Library.safe_name("..\\evil.sfc")
    end

    test "rejects dot and dot-dot" do
      assert {:error, :bad_name} = Library.safe_name(".")
      assert {:error, :bad_name} = Library.safe_name("..")
    end

    test "rejects a leading dot, so nothing lands as a dotfile" do
      assert {:error, :bad_name} = Library.safe_name(".bashrc")
    end

    test "rejects a null byte" do
      assert {:error, :bad_name} = Library.safe_name("game.sfc\0.png")
    end

    test "rejects the empty string and non-binaries" do
      assert {:error, :bad_name} = Library.safe_name("")
      assert {:error, :bad_name} = Library.safe_name(nil)
    end
  end

  describe "path/2" do
    test "resolves inside the system directory", %{root: root} do
      assert {:ok, path} = Library.path("snes", "game.sfc")
      assert path == Path.join([root, "snes", "game.sfc"])
    end

    test "refuses an unknown system" do
      assert {:error, :unknown_system} = Library.path("dreamcast", "game.sfc")
    end

    test "refuses an extension the system does not claim" do
      assert {:error, :bad_extension} = Library.path("gb", "game.sfc")
      assert {:ok, _} = Library.path("gb", "game.gb")
    end

    test "matches the extension case-insensitively" do
      assert {:ok, _} = Library.path("snes", "GAME.SFC")
    end

    test "a traversal cannot reach outside the root, even with a good extension" do
      assert {:error, :bad_name} = Library.path("snes", "../../bundles/x.sfc")
    end
  end

  describe "receive_upload/4" do
    test "writes every chunk, in order, and reports the total", %{root: root} do
      assert {:ok, %{name: "game.sfc", size: 9}, _} =
               Library.receive_upload("snes", "game.sfc", ["abc", "def", "ghi"], reader())

      assert File.read!(Path.join([root, "snes", "game.sfc"])) == "abcdefghi"
    end

    test "creates the system directory on first upload", %{root: root} do
      refute File.dir?(Path.join(root, "snes"))
      assert {:ok, _, _} = Library.receive_upload("snes", "game.sfc", ["x"], reader())
      assert File.dir?(Path.join(root, "snes"))
    end

    test "overwrites an existing file rather than appending", %{root: root} do
      {:ok, _, _} = Library.receive_upload("snes", "game.sfc", ["aaaa"], reader())
      {:ok, %{size: 2}, _} = Library.receive_upload("snes", "game.sfc", ["bb"], reader())
      assert File.read!(Path.join([root, "snes", "game.sfc"])) == "bb"
    end

    test "leaves no .part behind on success", %{root: root} do
      {:ok, _, _} = Library.receive_upload("snes", "game.sfc", ["x"], reader())
      assert File.ls!(Path.join(root, "snes")) == ["game.sfc"]
    end

    test "refuses a body over the ceiling and leaves nothing behind", %{root: root} do
      Application.put_env(:mayonnaios, :max_upload_bytes, 4)

      assert {:error, :too_large, _} =
               Library.receive_upload("snes", "game.sfc", ["aaa", "bbb"], reader())

      # Not even a .part: a partial file that the next upload would have to
      # reason about is worse than no file.
      assert File.ls!(Path.join(root, "snes")) == []
    end

    test "does not create a directory for a rejected name", %{root: root} do
      assert {:error, :bad_name, _} = Library.receive_upload("snes", "../x.sfc", ["a"], reader())
      assert File.ls!(root) == []
    end

    test "propagates a read error and cleans up", %{root: root} do
      reader = fn
        ["boom" | _] -> {:error, :closed}
        [h | t] -> {:more, h, t}
      end

      assert {:error, {:read, :closed}, _} =
               Library.receive_upload("snes", "game.sfc", ["ok", "boom"], reader)

      assert File.ls!(Path.join(root, "snes")) == []
    end
  end

  describe "entries/1 and delete/2" do
    test "lists regular files, hides dotfiles and part files", %{root: root} do
      dir = Path.join(root, "snes")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.sfc"), "12345")
      File.write!(Path.join(dir, ".hidden"), "x")
      File.mkdir_p!(Path.join(dir, "subdir"))

      assert [%{name: "a.sfc", size: 5}] = Library.entries("snes")
    end

    test "returns nothing for a system with no directory yet" do
      assert Library.entries("gb") == []
    end

    test "returns nothing for an unknown system" do
      assert Library.entries("dreamcast") == []
    end

    test "deletes an entry", %{root: root} do
      dir = Path.join(root, "snes")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.sfc"), "x")

      assert :ok = Library.delete("snes", "a.sfc")
      assert Library.entries("snes") == []
    end

    test "delete refuses a traversal rather than following it" do
      assert {:error, :bad_name} = Library.delete("snes", "../../passwd.sfc")
    end
  end
end
