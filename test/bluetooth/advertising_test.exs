defmodule MayonnaiOS.Bluetooth.AdvertisingTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Bluetooth.Advertising

  # The 31-byte budget is the only hazard in this module, and overrunning it
  # is not an error anyone sees: the controller refuses the command and goes
  # on advertising whatever it had before, which on a fresh boot is nothing.

  describe "data/0" do
    test "fits, with room to spare" do
      assert byte_size(Advertising.data()) <= 31
    end

    test "says LE only, so a dual-mode host does not try the classic transport" do
      types = Advertising.types()
      structures = Advertising.decode(Advertising.data())

      assert {_type, <<flags>>} =
               Enum.find(structures, fn {type, _} -> type == types.flags end)

      # Bit 1: LE General Discoverable. Bit 2: BR/EDR Not Supported.
      assert Bitwise.band(flags, 0x02) != 0
      assert Bitwise.band(flags, 0x04) != 0
    end

    test "carries the gamepad appearance, which is what draws the right icon" do
      types = Advertising.types()

      assert {_type, <<0x03C4::16-little>>} =
               Advertising.data()
               |> Advertising.decode()
               |> Enum.find(fn {type, _} -> type == types.appearance end)
    end

    test "carries the HID service UUID, which is what hosts filter on" do
      types = Advertising.types()

      assert {_type, <<0x1812::16-little>>} =
               Advertising.data()
               |> Advertising.decode()
               |> Enum.find(fn {type, _} -> type == types.complete_uuid16 end)
    end

    test "does not carry the name, because it does not fit next to the rest" do
      types = Advertising.types()
      structures = Advertising.decode(Advertising.data())

      refute Enum.any?(structures, fn {type, _} -> type == types.complete_name end)
    end
  end

  describe "scan_response/1" do
    test "carries the whole name when it fits" do
      types = Advertising.types()

      assert [{type, "Xbox Wireless Controller"}] =
               Advertising.decode(Advertising.scan_response("Xbox Wireless Controller"))

      assert type == types.complete_name
    end

    test "a name at exactly the limit is still complete" do
      name = String.duplicate("a", 29)
      types = Advertising.types()

      assert [{type, ^name}] = Advertising.decode(Advertising.scan_response(name))
      assert type == types.complete_name
      assert byte_size(Advertising.scan_response(name)) == 31
    end

    test "a longer name is truncated and says so in its type byte" do
      name = String.duplicate("a", 40)
      types = Advertising.types()

      assert [{type, value}] = Advertising.decode(Advertising.scan_response(name))

      # Shortened rather than complete. A truncated name sent as a complete
      # one is what a host caches, by that name, indefinitely.
      assert type == types.short_name
      assert byte_size(value) == 29
      assert byte_size(Advertising.scan_response(name)) <= 31
    end
  end

  describe "encode/1" do
    test "each structure is a length, a type and the value" do
      assert Advertising.encode([{0x01, <<0x06>>}]) == <<0x02, 0x01, 0x06>>
    end

    test "raises rather than producing a packet that parses and lies" do
      assert_raise ArgumentError, ~r/limit is 31/, fn ->
        Advertising.encode([{0x09, String.duplicate("x", 40)}])
      end
    end
  end

  describe "decode/1" do
    test "stops at the zero padding a 31-byte field is filled with" do
      padded = Advertising.data() <> :binary.copy(<<0>>, 31 - byte_size(Advertising.data()))

      assert Advertising.decode(padded) == Advertising.decode(Advertising.data())
    end

    test "returns what parsed when a length runs off the end" do
      assert Advertising.decode(<<0x02, 0x01, 0x06, 0x05, 0x09, "ab">>) == [{0x01, <<0x06>>}]
    end
  end
end
