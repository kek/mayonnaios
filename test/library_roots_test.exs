defmodule MayonnaiOS.LibraryRootsTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Library

  @systems [
    %{key: "snes", name: "Super Nintendo", extensions: [".sfc", ".smc"]}
  ]

  # Two roots standing in for the internal card and the games card. The point
  # of every test here is that reads span both while writes do not.
  setup do
    id = System.unique_integer([:positive])
    internal = Path.join(System.tmp_dir!(), "roots-internal-#{id}")
    card = Path.join(System.tmp_dir!(), "roots-card-#{id}")
    File.mkdir_p!(Path.join(internal, "snes"))
    File.mkdir_p!(Path.join(card, "snes"))

    prev_roots = Application.get_env(:mayonnaios, :rom_roots)
    prev_root = Application.get_env(:mayonnaios, :rom_root)
    prev_systems = Application.get_env(:mayonnaios, :systems)

    Application.put_env(:mayonnaios, :rom_roots, [internal, card])
    Application.put_env(:mayonnaios, :systems, @systems)

    on_exit(fn ->
      File.rm_rf(internal)
      File.rm_rf(card)

      if prev_roots,
        do: Application.put_env(:mayonnaios, :rom_roots, prev_roots),
        else: Application.delete_env(:mayonnaios, :rom_roots)

      if prev_root,
        do: Application.put_env(:mayonnaios, :rom_root, prev_root),
        else: Application.delete_env(:mayonnaios, :rom_root)

      if prev_systems,
        do: Application.put_env(:mayonnaios, :systems, prev_systems),
        else: Application.delete_env(:mayonnaios, :systems)
    end)

    %{internal: internal, card: card}
  end

  describe "reading across roots" do
    test "lists content from both", %{internal: internal, card: card} do
      File.write!(Path.join([internal, "snes", "uploaded.sfc"]), "a")
      File.write!(Path.join([card, "snes", "chrono.sfc"]), "bb")

      names = Library.entries("snes") |> Enum.map(& &1.name)
      assert names == ["chrono.sfc", "uploaded.sfc"]
    end

    test "sizes come from whichever root holds the file", %{internal: i, card: c} do
      File.write!(Path.join([i, "snes", "small.sfc"]), "a")
      File.write!(Path.join([c, "snes", "large.sfc"]), String.duplicate("x", 100))

      sizes = Library.entries("snes") |> Map.new(&{&1.name, &1.size})
      assert sizes == %{"small.sfc" => 1, "large.sfc" => 100}
    end

    test "a name in both roots is listed once, from the first", %{internal: i, card: c} do
      # The same game on both cards is normal: copied to the internal one and
      # never removed from the card. Listing it twice would look like a bug in
      # the UI, and deleting the wrong copy would be worse.
      File.write!(Path.join([i, "snes", "dup.sfc"]), "internal")
      File.write!(Path.join([c, "snes", "dup.sfc"]), "card-is-longer")

      assert [%{name: "dup.sfc", size: size}] = Library.entries("snes")
      assert size == byte_size("internal")
    end

    test "a missing games card is not an error", %{internal: i, card: c} do
      File.rm_rf!(c)
      File.write!(Path.join([i, "snes", "only.sfc"]), "a")
      assert Library.entries("snes") |> Enum.map(& &1.name) == ["only.sfc"]
    end

    test "directories are hidden, on either root", %{internal: i, card: c} do
      File.mkdir_p!(Path.join([i, "snes", "a-directory"]))
      File.mkdir_p!(Path.join([c, "snes", "another"]))
      assert Library.entries("snes") == []
    end

    test "dotfiles are hidden, which matters more with a Mac-written card", %{card: c} do
      # The card really does have .Spotlight-V100 and .fseventsd at its root.
      File.write!(Path.join([c, "snes", ".DS_Store"]), "x")
      File.write!(Path.join([c, "snes", "game.sfc"]), "y")
      assert Library.entries("snes") |> Enum.map(& &1.name) == ["game.sfc"]
    end
  end

  describe "writing" do
    test "root/0 is the first root, never the card", %{internal: internal} do
      assert Library.root() == internal
    end

    test "path/2 always names the writable root", %{internal: internal} do
      assert {:ok, path} = Library.path("snes", "new.sfc")
      assert path == Path.join([internal, "snes", "new.sfc"])
    end
  end

  describe "find/2" do
    test "finds a file on the card", %{card: c} do
      File.write!(Path.join([c, "snes", "chrono.sfc"]), "x")
      assert {:ok, found} = Library.find("snes", "chrono.sfc")
      assert found == Path.join([c, "snes", "chrono.sfc"])
    end

    test "prefers the internal root when both have it", %{internal: i, card: c} do
      File.write!(Path.join([i, "snes", "dup.sfc"]), "x")
      File.write!(Path.join([c, "snes", "dup.sfc"]), "x")
      assert {:ok, found} = Library.find("snes", "dup.sfc")
      assert found == Path.join([i, "snes", "dup.sfc"])
    end

    test "says enoent rather than guessing a path" do
      assert Library.find("snes", "absent.sfc") == {:error, :enoent}
    end

    test "still refuses a bad name" do
      assert Library.find("snes", "../escape.sfc") == {:error, :bad_name}
    end

    test "still refuses an unknown system" do
      assert Library.find("nope", "game.sfc") == {:error, :unknown_system}
    end
  end

  describe "delete/2" do
    test "deletes from the card, not just the internal root", %{card: c} do
      path = Path.join([c, "snes", "chrono.sfc"])
      File.write!(path, "x")
      assert Library.delete("snes", "chrono.sfc") == :ok
      refute File.exists?(path)
    end

    test "deletes the internal copy first when both exist", %{internal: i, card: c} do
      ip = Path.join([i, "snes", "dup.sfc"])
      cp = Path.join([c, "snes", "dup.sfc"])
      File.write!(ip, "x")
      File.write!(cp, "x")

      assert Library.delete("snes", "dup.sfc") == :ok
      refute File.exists?(ip)
      # The card's copy survives, and a second delete removes it. Deleting one
      # name twice is odd, but silently removing two files from two cards for
      # one request would be worse.
      assert File.exists?(cp)
      assert Library.delete("snes", "dup.sfc") == :ok
      refute File.exists?(cp)
    end

    test "deleting what is not there reports it" do
      assert Library.delete("snes", "absent.sfc") == {:error, :enoent}
    end
  end

  describe "single-root configuration" do
    test "falls back to :rom_root when :rom_roots is unset" do
      Application.delete_env(:mayonnaios, :rom_roots)
      Application.put_env(:mayonnaios, :rom_root, "/tmp/just-one")
      assert Library.roots() == ["/tmp/just-one"]
      assert Library.root() == "/tmp/just-one"
    end
  end
end
