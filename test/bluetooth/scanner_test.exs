defmodule MayonnaiOS.Bluetooth.ScannerTest do
  use ExUnit.Case, async: false

  alias MayonnaiOS.Bluetooth.{Advertising, FakeController, HCI, Scanner}

  setup do
    start_supervised!({FakeController, self()})
    start_supervised!(Scanner)

    # Setup runs in a handle_continue, which is executed before any call this
    # test makes, so one call is enough to know it has finished.
    Scanner.status()
    :ok
  end

  defp advertise(opts) do
    data = Keyword.get(opts, :data, <<>>)
    address = Keyword.get(opts, :address, <<0xF6, 0xE5, 0xD4, 0xC3, 0xB2, 0xA1>>)
    event_type = Keyword.get(opts, :event_type, 0x00)
    rssi = Keyword.get(opts, :rssi, -55)

    params =
      <<0x01, event_type, 0x00, address::binary, byte_size(data), data::binary, rssi::signed-8>>

    packet = <<0x04, 0x3E, byte_size(params) + 1, 0x02, params::binary>>
    FakeController.emit(HCI.decode(packet))
  end

  test "setup resets, masks, and turns the scan on, in that order" do
    assert_received {:command, 0x0C03, _}
    assert_received {:command, 0x0C01, _}
    assert_received {:command, 0x2001, _}
    assert_received {:command, 0x0C6D, _}
    assert_received {:command, 0x200B, _}
    assert_received {:command, 0x200C, <<0x01, 0x00>>}

    assert %{scanning: true, error: nil, devices: 0} = Scanner.status()
  end

  test "no buffer sizes are read, because a scan sends nothing" do
    refute_received {:command, 0x2002, _}
    refute_received {:command, 0x1005, _}
  end

  test "an advertisement becomes a device" do
    advertise([])

    assert [device] = Scanner.devices()
    assert device.address == "A1:B2:C3:D4:E5:F6"
    assert device.label == "A1:B2:C3:D4:E5:F6"
    assert device.rssi == -55
    assert %{devices: 1} = Scanner.status()
  end

  test "a device carries the tag the screen puts where Connect would be" do
    # BR/EDR Not Supported clear: this is a dual-mode device, which is what a
    # pair of headphones looks like from an LE scan.
    types = Advertising.types()
    data = Advertising.encode([{types.flags, <<0x02>>}, {types.complete_name, "Headphones"}])

    advertise(data: data)

    assert [%{label: "Headphones", dual_mode?: true}] = Scanner.devices()
  end

  test "this device's own advertisement reads back as LE only" do
    advertise(data: Advertising.data())
    assert [%{dual_mode?: false}] = Scanner.devices()
  end

  test "an age comes back with every device" do
    advertise([])
    assert [%{age_ms: age}] = Scanner.devices()
    assert age >= 0
  end

  test "an event with no reports in it is counted rather than dropped silently" do
    FakeController.emit({:event, :le_advertising_report, %{reports: []}})

    assert %{undecodable: 1, devices: 0} = Scanner.status()
  end

  test "an event this process does not handle does not take it down" do
    pid = Process.whereis(Scanner)
    FakeController.emit({:event, :disconnection_complete, %{status: 0, handle: 1, reason: 0x13}})
    FakeController.emit({:acl, 0x0040, :start, <<1, 2, 3>>})

    assert %{scanning: true} = Scanner.status()
    assert Process.whereis(Scanner) == pid
  end

  test "stopping the scanner turns the scan off rather than leaving the radio busy" do
    :ok = stop_supervised(Scanner)

    assert_received {:command, 0x200C, <<0x00, 0x00>>}
  end
end
