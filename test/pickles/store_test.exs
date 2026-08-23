defmodule MayonnaiOS.Pickles.StoreTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Pickles.Store
  import MayonnaiOS.PickleFixtures

  setup do
    root = Path.join(System.tmp_dir!(), "pickles-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "valid_name?/1" do
    test "accepts the names pickles use" do
      assert Store.valid_name?("tuya-lamps")
      assert Store.valid_name?("hello")
      assert Store.valid_name?("a2_b")
    end

    test "rejects what would escape a path or a URL" do
      refute Store.valid_name?("../etc")
      refute Store.valid_name?("has space")
      refute Store.valid_name?("Caps")
      refute Store.valid_name?("-leading")
      refute Store.valid_name?("")
      refute Store.valid_name?(String.duplicate("a", 33))
      refute Store.valid_name?(nil)
    end
  end

  describe "install/3" do
    test "installs a well-formed pickle and reads it back", %{root: root} do
      tar = pickle_tarball(root, "hello", "x = 1", %{"capabilities" => ["storage"]})

      assert {:ok, manifest} = Store.install(root, "hello", tar)
      assert manifest.name == "hello"
      assert manifest.capabilities == ["storage"]
      assert manifest.main == "main.lua"
      refute manifest.autostart

      assert {:ok, ^manifest} = Store.manifest(root, "hello")
      assert File.exists?(Path.join([root, "hello", "main.lua"]))
    end

    test "accepts a tarball whose files sit inside one directory", %{root: root} do
      tar =
        tarball(root, [
          {"hello/pickle.json", manifest("hello")},
          {"hello/main.lua", "x = 1"}
        ])

      assert {:ok, _} = Store.install(root, "hello", tar)
      assert File.exists?(Path.join([root, "hello", "main.lua"]))
    end

    test "rejects members that would escape the staging directory", %{root: root} do
      tar =
        tarball(root, [
          {"pickle.json", manifest("hello")},
          {"../evil.lua", "x = 1"}
        ])

      assert {:error, {:bad_member, "../evil.lua"}} = Store.install(root, "hello", tar)
      refute File.exists?(Path.join(root, "hello"))
    end

    test "rejects a manifest naming a different pickle", %{root: root} do
      tar = pickle_tarball(root, "other", "x = 1")
      assert {:error, {:name_mismatch, "other"}} = Store.install(root, "hello", tar)
    end

    test "rejects unknown capabilities rather than ignoring them", %{root: root} do
      tar = pickle_tarball(root, "hello", "x = 1", %{"capabilities" => ["root_shell"]})
      assert {:error, {:unknown_capability, ["root_shell"]}} = Store.install(root, "hello", tar)
    end

    test "rejects a missing main script", %{root: root} do
      tar = tarball(root, [{"pickle.json", manifest("hello")}])
      assert {:error, {:no_main, "main.lua"}} = Store.install(root, "hello", tar)
    end

    test "rejects a main that is a path rather than a filename", %{root: root} do
      tar = pickle_tarball(root, "hello", "x = 1", %{"main" => "../main.lua"})
      assert {:error, :bad_main} = Store.install(root, "hello", tar)
    end

    test "rejects bodies that are not tarballs", %{root: root} do
      path = Path.join(root, "junk.tar.gz")
      File.write!(path, "not a tarball")
      assert {:error, {:not_a_tarball, _}} = Store.install(root, "hello", path)
    end

    test "replaces an existing install whole", %{root: root} do
      tar1 =
        tarball(root, [
          {"pickle.json", manifest("hello")},
          {"main.lua", "x = 1"},
          {"extra.lua", "y = 2"}
        ])

      assert {:ok, _} = Store.install(root, "hello", tar1)

      tar2 = pickle_tarball(root, "hello", "x = 2")
      assert {:ok, _} = Store.install(root, "hello", tar2)

      assert File.read!(Path.join([root, "hello", "main.lua"])) == "x = 2"
      # The old install's extra file did not survive into the new one.
      refute File.exists?(Path.join([root, "hello", "extra.lua"]))
    end
  end

  describe "list/1" do
    test "lists installed pickles and shows broken ones", %{root: root} do
      tar = pickle_tarball(root, "good", "x = 1")
      assert {:ok, _} = Store.install(root, "good", tar)

      File.mkdir_p!(Path.join(root, "broken"))
      File.write!(Path.join([root, "broken", "pickle.json"]), "not json")

      assert [%{error: :bad_manifest, name: "broken"}, %{name: "good"}] = Store.list(root)
    end

    test "an empty or missing root is an empty list", %{root: root} do
      assert Store.list(root) == []
      assert Store.list(Path.join(root, "nonexistent")) == []
    end
  end

  describe "delete/2" do
    test "removes the pickle and its state", %{root: root} do
      tar = pickle_tarball(root, "hello", "x = 1")
      assert {:ok, _} = Store.install(root, "hello", tar)

      state = Store.state_path(root, "hello")
      File.mkdir_p!(Path.dirname(state))
      File.write!(state, ~s({"remembered": true}))

      assert :ok = Store.delete(root, "hello")
      refute File.exists?(Path.join(root, "hello"))
      refute File.exists?(state)
    end

    test "deleting what is not there says so", %{root: root} do
      assert {:error, :enoent} = Store.delete(root, "hello")
    end
  end
end
