defmodule MayonnaiOS.Bluetooth.BondsTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Bluetooth.Bonds

  @laptop {0x00, <<0xA6, 0xA5, 0xA4, 0xA3, 0xA2, 0xA1>>}
  @windows {0x01, <<0xB6, 0xB5, 0xB4, 0xB3, 0xB2, 0xB1>>}

  setup do
    path = Path.join(System.tmp_dir!(), "bonds-#{System.unique_integer([:positive])}/bonds.bin")
    Application.put_env(:mayonnaios, :bond_path, path)

    on_exit(fn ->
      Application.delete_env(:mayonnaios, :bond_path)
      File.rm_rf!(Path.dirname(path))
    end)

    start_supervised!(Bonds)
    %{path: path}
  end

  defp bond(peer, ediv) do
    %{
      ltk: :crypto.strong_rand_bytes(16),
      ediv: ediv,
      rand: :crypto.strong_rand_bytes(8),
      peer: peer,
      key_size: 16
    }
  end

  describe "forgetting one host" do
    test "drops the named bond and keeps the others" do
      Bonds.put(bond(@laptop, <<1, 0>>))
      Bonds.put(bond(@windows, <<2, 0>>))

      :ok = Bonds.forget(@laptop)

      assert [%{peer: @windows}] = Bonds.list()
    end

    test "the key really is gone, not just hidden from the list" do
      %{ediv: ediv, rand: rand} = stored = bond(@laptop, <<3, 0>>)
      Bonds.put(stored)

      assert Bonds.find(ediv, rand) != nil

      :ok = Bonds.forget(@laptop)

      # This is the assertion that matters: a bond dropped from the list but
      # still answering a lookup would let a host that has been "forgotten"
      # keep reconnecting silently.
      assert Bonds.find(ediv, rand) == nil
    end

    test "forgetting something that is not there is not an error" do
      Bonds.put(bond(@laptop, <<4, 0>>))

      assert :ok = Bonds.forget(@windows)
      assert [%{peer: @laptop}] = Bonds.list()
    end

    test "survives a restart, which is the only thing the file is for", %{path: path} do
      Bonds.put(bond(@laptop, <<5, 0>>))
      Bonds.put(bond(@windows, <<6, 0>>))
      :ok = Bonds.forget(@laptop)

      :ok = stop_supervised(Bonds)
      start_supervised!(Bonds)

      assert [%{peer: @windows}] = Bonds.list()
      assert File.exists?(path)
    end
  end

  describe "writing the file" do
    test "leaves no temporary behind", %{path: path} do
      Bonds.put(bond(@laptop, <<7, 0>>))

      refute File.exists?(path <> ".new")
      assert File.exists?(path)
    end

    test "creates the directory it was pointed at", %{path: path} do
      refute File.exists?(Path.dirname(path))

      Bonds.put(bond(@laptop, <<8, 0>>))

      assert File.dir?(Path.dirname(path))
    end

    test "the file on disk is what a fresh reader gets", %{path: path} do
      Bonds.put(bond(@laptop, <<9, 0>>))

      # Read the bytes rather than the process: an fsync that never happened
      # is invisible from in here, but a write that never happened is not, and
      # this is the half that can be checked on a laptop.
      assert {:ok, binary} = File.read(path)
      assert [%{peer: @laptop}] = :erlang.binary_to_term(binary, [:safe])
    end

    test "clearing writes an empty list rather than removing the file", %{path: path} do
      Bonds.put(bond(@laptop, <<10, 0>>))
      :ok = Bonds.clear()

      assert {:ok, binary} = File.read(path)
      assert [] = :erlang.binary_to_term(binary, [:safe])
    end
  end
end
