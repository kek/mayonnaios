defmodule MayonnaiOS.Controller.ReportTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Controller.Report

  # The report descriptor and the bytes packed against it are the one part of
  # this stack that fails silently: a host parses a wrong descriptor without
  # complaining and then believes the wrong thing forever. So the checks here
  # are against the layout as written down in the moduledoc -- byte positions
  # and bit positions -- rather than against whatever the code happens to do.

  describe "descriptor/0" do
    test "declares a gamepad, which is what makes a host treat it as one" do
      # Usage Page (Generic Desktop), Usage (Game Pad), Collection (Application).
      assert <<0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, _rest::binary>> = Report.descriptor()
    end

    test "does not declare any axes, which is what stopped the cursor moving" do
      # Usage (X) and Usage (Y) on the Generic Desktop page. Their presence is
      # what let Steam take the D-pad for a stick and drive the mouse with it
      # while the game was reading the hat; see the moduledoc.
      refute contains?(Report.descriptor(), <<0x09, 0x30>>)
      refute contains?(Report.descriptor(), <<0x09, 0x31>>)
      # And no Pointer collection to put them in.
      refute contains?(Report.descriptor(), <<0x09, 0x01, 0xA1, 0x00>>)
    end

    test "opens and closes the same number of collections" do
      bytes = :binary.bin_to_list(Report.descriptor())

      # 0xA1 is Collection with a one-byte payload, 0xC0 is End Collection.
      # A descriptor that does not balance is rejected outright by some hosts
      # and misparsed by others.
      opens = Enum.count(chunks(bytes), &match?({0xA1, _}, &1))
      closes = Enum.count(chunks(bytes), &match?({0xC0, _}, &1))

      assert opens == closes
      # One: the Game Pad application collection. The physical collection that
      # used to wrap the axes went with them.
      assert opens == 1
    end

    test "declares no report ID at all" do
      # Walked as items rather than searched for as bytes: 0x85 is a perfectly
      # ordinary data byte and a byte search would find one in the physical
      # maximum. With one report an ID buys nothing and splits hosts into two
      # camps about whether the first byte is the ID or the hat.
      tags = Report.descriptor() |> :binary.bin_to_list() |> chunks() |> Enum.map(&elem(&1, 0))

      refute 0x85 in tags
    end

    test "declares exactly the ten buttons the shell has" do
      # Usage Minimum (Button 1), Usage Maximum (Button 10).
      assert contains?(Report.descriptor(), <<0x19, 0x01, 0x29, 0x0A>>)
      # Report Count (10) for the button field, then six bits of padding.
      assert contains?(Report.descriptor(), <<0x95, 0x0A, 0x81, 0x02>>)
      assert contains?(Report.descriptor(), <<0x95, 0x06, 0x81, 0x03>>)
    end

    test "the hat has a null state, so centred is expressible" do
      # Input (Data, Variable, Absolute, Null State) -- bit 6 set.
      assert contains?(Report.descriptor(), <<0x81, 0x42>>)
    end

    test "the degrees unit is turned off again after the hat" do
      # Unit items are sticky: left set, they apply to the button field too,
      # and a host that respects units then reports buttons in degrees.
      assert contains?(Report.descriptor(), <<0x65, 0x14>>)
      assert contains?(Report.descriptor(), <<0x65, 0x00>>)
    end

    # Walk the item stream properly rather than searching for bytes: 0xC0 is
    # also a plausible data byte, and counting occurrences would find it.
    defp chunks(bytes), do: chunks(bytes, [])
    defp chunks([], acc), do: Enum.reverse(acc)

    defp chunks([item | rest], acc) do
      size = Bitwise.band(item, 0x03)
      size = if size == 3, do: 4, else: size
      {data, rest} = Enum.split(rest, size)
      chunks(rest, [{item, data} | acc])
    end

    defp contains?(haystack, needle), do: :binary.match(haystack, needle) != :nomatch
  end

  describe "encode/1" do
    test "nothing pressed is a null hat and no buttons" do
      assert Report.encode(Report.released()) == <<15, 0, 0>>
    end

    test "is three bytes whatever is held" do
      assert byte_size(Report.encode(all_pressed())) == 3
    end

    test "button 1 is the low bit of byte 1, and it is the A button" do
      # :btn_b is the button silkscreened A on this board.
      assert <<_, 0x01, 0x00>> = press(:btn_b)
    end

    test "button 9 is the low bit of byte 2, and button 10 the one above it" do
      assert <<_, 0x00, 0x01>> = press(:btn_select)
      assert <<_, 0x00, 0x02>> = press(:btn_start)
    end

    test "buttons accumulate rather than replace" do
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_b, 1},
          {:ev_key, :btn_a, 1}
        ])

      # Buttons 1 and 2.
      assert <<_, 0x03, 0x00>> = Report.encode(state)
    end

    test "a release clears just that button" do
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_b, 1},
          {:ev_key, :btn_a, 1},
          {:ev_key, :btn_b, 0}
        ])

      assert <<_, 0x02, 0x00>> = Report.encode(state)
    end

    test "an auto-repeat is a press, not a release" do
      state = Report.apply_events(Report.released(), [{:ev_key, :btn_b, 2}])
      assert <<_, 0x01, 0x00>> = Report.encode(state)
    end

    test "the D-pad is the hat, clockwise from north" do
      assert <<0, 0, 0>> = press(:btn_dpad_up)
      assert <<4, 0, 0>> = press(:btn_dpad_down)
      assert <<6, 0, 0>> = press(:btn_dpad_left)
      assert <<2, 0, 0>> = press(:btn_dpad_right)
    end

    test "a diagonal is one hat value" do
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_dpad_down, 1},
          {:ev_key, :btn_dpad_right, 1}
        ])

      assert <<3, 0, 0>> = Report.encode(state)
    end

    test "opposite directions cancel instead of failing to decode" do
      # Four separate switches under one cross can be held at once.
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_dpad_up, 1},
          {:ev_key, :btn_dpad_down, 1}
        ])

      assert Report.encode(state) == <<15, 0, 0>>
    end
  end

  describe "apply_event/2" do
    test "leaves events it does not own alone" do
      state = Report.apply_events(Report.released(), [{:ev_syn, :syn_report, 0}])
      assert state == Report.released()
    end

    test "ignores Menu, which is how you get out of controller mode" do
      assert press(:btn_mode) == Report.encode(Report.released())
      refute Report.known?(:btn_mode)
    end

    test "ignores the volume keys, which belong to Diagnostics" do
      assert press(:key_volumeup) == Report.encode(Report.released())
    end
  end

  describe "known?/1" do
    test "is true for everything in either table" do
      for key <- Map.keys(Report.button_map()) ++ Map.keys(Report.direction_map()) do
        assert Report.known?(key), "#{key} is mapped but not reported as known"
      end
    end
  end

  test "every button number is used exactly once" do
    numbers = Report.button_map() |> Map.values() |> Enum.sort()
    assert numbers == Enum.to_list(1..10)
  end

  defp press(key), do: Report.encode(Report.apply_events(Report.released(), [{:ev_key, key, 1}]))

  defp all_pressed do
    events = for key <- Map.keys(Report.button_map()), do: {:ev_key, key, 1}
    Report.apply_events(Report.released(), events)
  end
end
