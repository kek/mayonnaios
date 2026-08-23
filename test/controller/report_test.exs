defmodule MayonnaiOS.Controller.ReportTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Controller.Report

  # The report descriptor and the bytes packed against it are the one part of
  # this stack that fails silently -- and now that the descriptor claims to be
  # an Xbox Wireless Controller's, the hosts that matter do not even read it:
  # their drivers parse reports against the layout they know that pad to have.
  # So the checks here are against the reference capture and the 1914's layout
  # as written down in the moduledoc, byte positions and bit positions, rather
  # than against whatever the code happens to do.

  # `XboxOneS_1914_HIDDescriptor` from ESP32-BLE-CompositeHID, captured from a
  # real pad on the BLE firmware. If `descriptor/0` is ever edited, this pin
  # must be re-derived from a fresh capture of the real controller -- never
  # from the code under test.
  @reference Base.decode16!(
               "05010905A10185010901A10009300931150027FFFF0000950275108102C0" <>
                 "0901A10009320935150027FFFF0000950275108102C0" <>
                 "050209C5150026FF039501750A810215002500750695018103" <>
                 "050209C4150026FF039501750A810215002500750695018103" <>
                 "05010939150125083500463B0166140075049501814275049501" <>
                 "15002500350045006500810305091901290F150025017501950F8102" <>
                 "15002500750195018103050C0AB20015002501950175018102" <>
                 "15002500750795018103050F09218503A10209971500250175049501" <>
                 "91021500250075049501910309701500256475089504910209506601" <>
                 "10550E150026FF0075089501910209A7150026FF0075089501910265" <>
                 "005500097C150026FF00750895019102C0C0"
             )

  describe "descriptor/0" do
    test "is the Xbox Wireless Controller 1914's descriptor, byte for byte" do
      assert Report.descriptor() == @reference
      assert byte_size(Report.descriptor()) == 283
    end

    test "declares a gamepad, which is what makes a host treat it as one" do
      # Usage Page (Generic Desktop), Usage (Game Pad), Collection (Application).
      assert <<0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, _rest::binary>> = Report.descriptor()
    end

    test "opens and closes the same number of collections" do
      bytes = :binary.bin_to_list(Report.descriptor())

      # 0xA1 is Collection with a one-byte payload, 0xC0 is End Collection.
      # A descriptor that does not balance is rejected outright by some hosts
      # and misparsed by others.
      opens = Enum.count(chunks(bytes), &match?({0xA1, _}, &1))
      closes = Enum.count(chunks(bytes), &match?({0xC0, _}, &1))

      assert opens == closes
      # Four: the Game Pad application collection, a physical collection per
      # stick, and the rumble report's logical collection.
      assert opens == 4
    end

    test "declares report IDs 1 and 3, which the report references must match" do
      # Walked as items rather than searched for as bytes: 0x85 is a perfectly
      # ordinary data byte elsewhere. `MayonnaiOS.Bluetooth.HOGP` puts these
      # two numbers in the Report Reference descriptors, and a host matches
      # reports to the map through that pair -- a drifted ID is a dead pad.
      ids =
        Report.descriptor()
        |> :binary.bin_to_list()
        |> chunks()
        |> Enum.filter(&match?({0x85, _}, &1))
        |> Enum.map(fn {0x85, [id]} -> id end)

      assert ids == [1, 3]
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
  end

  describe "encode/1" do
    test "nothing pressed is sixteen bytes: sticks centred, everything else zero" do
      assert Report.encode(Report.released()) ==
               <<0, 0x80, 0, 0x80, 0, 0x80, 0, 0x80, 0, 0, 0, 0, 0, 0, 0, 0>>
    end

    test "is sixteen bytes whatever is held" do
      assert byte_size(Report.encode(all_pressed())) == 16
      assert Report.size() == 16
    end

    test "the button silkscreened A is the Xbox A, in the low bit of byte 13" do
      # :btn_b is the button silkscreened A on this board.
      assert buttons(press(:btn_b)) == {0x01, 0x00}
    end

    test "B, X and Y land on the Xbox bits, skipping the ones this shell lacks" do
      # Bits 2, 5, 8 and 9 belong to controls the 1914 reserves for other
      # devices in the family; the driver expects them unused.
      assert buttons(press(:btn_a)) == {0x02, 0x00}
      assert buttons(press(:btn_y)) == {0x08, 0x00}
      assert buttons(press(:btn_x)) == {0x10, 0x00}
    end

    test "the shoulders are LB and RB" do
      assert buttons(press(:btn_tl)) == {0x40, 0x00}
      assert buttons(press(:btn_tr)) == {0x80, 0x00}
    end

    test "Select and Start are the View and Menu buttons, in byte 14" do
      assert buttons(press(:btn_select)) == {0x00, 0x04}
      assert buttons(press(:btn_start)) == {0x00, 0x08}
    end

    test "Select and Start together are the Xbox button, and nothing else" do
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_select, 1},
          {:ev_key, :btn_start, 1}
        ])

      assert buttons(Report.encode(state)) == {0x00, 0x10}
    end

    test "the chord suppresses the survivor of a staggered release" do
      # Letting go of the chord one finger at a time must not press Menu on
      # the way out; the moduledoc has the account.
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_select, 1},
          {:ev_key, :btn_start, 1},
          {:ev_key, :btn_select, 0}
        ])

      assert buttons(Report.encode(state)) == {0x00, 0x00}
    end

    test "once both halves are up, the single buttons are themselves again" do
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_select, 1},
          {:ev_key, :btn_start, 1},
          {:ev_key, :btn_select, 0},
          {:ev_key, :btn_start, 0},
          {:ev_key, :btn_start, 1}
        ])

      assert buttons(Report.encode(state)) == {0x00, 0x08}
    end

    test "the chord does not swallow bystanders" do
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_b, 1},
          {:ev_key, :btn_select, 1},
          {:ev_key, :btn_start, 1}
        ])

      # The A button rides along untouched; only View and Menu are rewritten.
      assert buttons(Report.encode(state)) == {0x01, 0x10}
    end

    test "L2 pulls the brake fully, because a switch has no half way" do
      assert <<_::binary-size(8), 0xFF, 0x03, 0, 0, _::binary>> = press(:btn_tl2)

      released =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_tl2, 1},
          {:ev_key, :btn_tl2, 0}
        ])

      assert <<_::binary-size(8), 0, 0, 0, 0, _::binary>> = Report.encode(released)
    end

    test "R2 is the accelerator" do
      assert <<_::binary-size(10), 0xFF, 0x03, _::binary>> = press(:btn_tr2)
    end

    test "buttons accumulate rather than replace" do
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_b, 1},
          {:ev_key, :btn_a, 1}
        ])

      assert buttons(Report.encode(state)) == {0x03, 0x00}
    end

    test "a release clears just that button" do
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_b, 1},
          {:ev_key, :btn_a, 1},
          {:ev_key, :btn_b, 0}
        ])

      assert buttons(Report.encode(state)) == {0x02, 0x00}
    end

    test "an auto-repeat is a press, not a release" do
      state = Report.apply_events(Report.released(), [{:ev_key, :btn_b, 2}])
      assert buttons(Report.encode(state)) == {0x01, 0x00}
    end

    test "the D-pad is the hat in byte 12, 1 at north and clockwise from there" do
      assert hat(press(:btn_dpad_up)) == 1
      assert hat(press(:btn_dpad_right)) == 3
      assert hat(press(:btn_dpad_down)) == 5
      assert hat(press(:btn_dpad_left)) == 7
    end

    test "a diagonal is one hat value" do
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_dpad_down, 1},
          {:ev_key, :btn_dpad_right, 1}
        ])

      assert hat(Report.encode(state)) == 4
    end

    test "opposite directions cancel instead of failing to decode" do
      # Four separate switches under one cross can be held at once.
      state =
        Report.apply_events(Report.released(), [
          {:ev_key, :btn_dpad_up, 1},
          {:ev_key, :btn_dpad_down, 1}
        ])

      assert hat(Report.encode(state)) == 0
    end

    test "the stick scales the ADC's 0..4096 up to the report's range" do
      assert <<0, 0, 0, 0x80, _::binary>> = stick(0, 2048)
      assert <<0xFF, 0xFF, 0, 0x80, _::binary>> = stick(4096, 2048)
    end

    test "the Y axis is flipped, because the ADC's up is HID's down" do
      # Read off the hardware: pushing this stick up raises the raw value,
      # and a HID Y of 0 is up. Shipping it straight through walked
      # characters upside down on a Steam Deck.
      assert <<_, _, 0xFF, 0xFF, _::binary>> = stick(2048, 0)
      assert <<_, _, 0, 0, _::binary>> = stick(2048, 4096)
    end

    test "stick values are quantised, so ADC noise is not a report" do
      # The stick rests near 2050 and the low bits wander. 256 steps swallow
      # that; `MayonnaiOS.Controller.Pad` then sees identical bytes and sends
      # nothing.
      assert stick(2048, 2048) == stick(2055, 2052)
    end

    test "values outside the promised range are clamped, not wrapped" do
      assert stick(-3, 2048) == stick(0, 2048)
      assert stick(5000, 2048) == stick(4096, 2048)
    end

    test "the right stick never moves" do
      for report <- [Report.encode(all_pressed()), stick(0, 4096), press(:btn_b)] do
        assert <<_::binary-size(4), 0, 0x80, 0, 0x80, _::binary>> = report
      end
    end

    test "the Share byte is a constant zero" do
      assert <<_::binary-size(15), 0>> = Report.encode(all_pressed())
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

    test "ignores axes the stick does not have" do
      state = Report.apply_events(Report.released(), [{:ev_abs, :abs_z, 4096}])
      assert Report.encode(state) == Report.encode(Report.released())
    end
  end

  describe "known?/1" do
    test "is true for everything in any table" do
      keys =
        Map.keys(Report.button_map()) ++
          Map.keys(Report.trigger_map()) ++ Map.keys(Report.direction_map())

      for key <- keys do
        assert Report.known?(key), "#{key} is mapped but not reported as known"
      end
    end
  end

  test "every button mask is used once and belongs to the 1914" do
    masks = Report.button_map() |> Map.values() |> Enum.sort()

    # A, B, X, Y, LB, RB, View, Menu -- the eight of the fifteen bits this
    # shell can press. Anything else here is a button the driver will hand to
    # games as something this device never meant.
    assert masks == [0x0001, 0x0002, 0x0008, 0x0010, 0x0040, 0x0080, 0x0400, 0x0800]
  end

  defp press(key), do: Report.encode(Report.apply_events(Report.released(), [{:ev_key, key, 1}]))

  defp stick(x, y) do
    Report.encode(
      Report.apply_events(Report.released(), [{:ev_abs, :abs_x, x}, {:ev_abs, :abs_y, y}])
    )
  end

  defp hat(report), do: :binary.at(report, 12)

  defp buttons(report), do: {:binary.at(report, 13), :binary.at(report, 14)}

  defp all_pressed do
    keys = Map.keys(Report.button_map()) ++ Map.keys(Report.trigger_map())
    events = for key <- keys, do: {:ev_key, key, 1}
    Report.apply_events(Report.released(), events)
  end
end
