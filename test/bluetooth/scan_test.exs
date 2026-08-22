defmodule MayonnaiOS.Bluetooth.ScanTest do
  use ExUnit.Case, async: true

  alias MayonnaiOS.Bluetooth.{Advertising, HCI, Scan}

  # A real advertising report, built the way the controller sends one: one
  # report, interleaved fields, RSSI last.
  defp report(opts) do
    data = Keyword.get(opts, :data, <<>>)
    address = Keyword.get(opts, :address, <<0xF6, 0xE5, 0xD4, 0xC3, 0xB2, 0xA1>>)
    event_type = Keyword.get(opts, :event_type, 0x00)
    address_type = Keyword.get(opts, :address_type, 0x00)
    rssi = Keyword.get(opts, :rssi, -60)

    params =
      <<0x01, event_type, address_type, address::binary, byte_size(data), data::binary,
        rssi::signed-8>>

    <<0x04, 0x3E, byte_size(params) + 1, 0x02, params::binary>>
  end

  defp decode_one(opts) do
    {:event, :le_advertising_report, %{reports: [report]}} = HCI.decode(report(opts))
    report
  end

  describe "decoding an advertising report" do
    test "one report comes back with its address in printed order" do
      report = decode_one([])

      assert report.address == "A1:B2:C3:D4:E5:F6"
      assert report.event_type == :adv_ind
      assert report.rssi == -60
    end

    test "several reports in one event are read as records, not as columns" do
      # The columnar reading of the specification parses a single report
      # correctly and mangles two, so this is the test that distinguishes them.
      first = <<0x00, 0x00, 1, 2, 3, 4, 5, 6, 0x00, -50::signed-8>>
      second = <<0x04, 0x01, 7, 8, 9, 10, 11, 12, 0x00, -90::signed-8>>
      params = <<0x02, first::binary, second::binary>>
      packet = <<0x04, 0x3E, byte_size(params) + 1, 0x02, params::binary>>

      {:event, :le_advertising_report, %{reports: [one, two]}} = HCI.decode(packet)

      assert one.address == "06:05:04:03:02:01"
      assert one.rssi == -50
      assert one.event_type == :adv_ind
      assert two.address == "0C:0B:0A:09:08:07"
      assert two.rssi == -90
      assert two.event_type == :scan_rsp
      assert two.address_type == 0x01
    end

    test "an RSSI of 127 is 'not available', not the strongest signal in the room" do
      assert decode_one(rssi: 127).rssi == nil
    end

    test "a truncated run keeps the reports that parsed" do
      good = <<0x00, 0x00, 1, 2, 3, 4, 5, 6, 0x00, -50::signed-8>>
      params = <<0x02, good::binary, 0x00, 0x00, 1, 2>>
      packet = <<0x04, 0x3E, byte_size(params) + 1, 0x02, params::binary>>

      {:event, :le_advertising_report, %{reports: reports}} = HCI.decode(packet)

      assert length(reports) == 1
    end

    test "the event survives a report count of zero" do
      packet = <<0x04, 0x3E, 0x02, 0x02, 0x00>>
      assert {:event, :le_advertising_report, %{reports: []}} = HCI.decode(packet)
    end
  end

  describe "the scan commands" do
    test "scan parameters are active by default, seven bytes of them" do
      assert <<0x01, 0x0B, 0x20, 7, 0x01, 0x60, 0x00, 0x30, 0x00, 0x00, 0x00>> =
               HCI.le_set_scan_parameters()
    end

    test "a passive scan is the same command with the first byte cleared" do
      assert <<0x01, 0x0B, 0x20, 7, 0x00, _rest::binary>> =
               HCI.le_set_scan_parameters(type: 0x00)
    end

    test "scan enable does not filter duplicates unless asked" do
      assert <<0x01, 0x0C, 0x20, 2, 0x01, 0x00>> == HCI.le_set_scan_enable(true)
      assert <<0x01, 0x0C, 0x20, 2, 0x00, 0x00>> == HCI.le_set_scan_enable(false)
      assert <<0x01, 0x0C, 0x20, 2, 0x01, 0x01>> == HCI.le_set_scan_enable(true, true)
    end
  end

  describe "building the list" do
    test "an advertisement and its scan response are one device" do
      types = Advertising.types()
      flags = Advertising.encode([{types.flags, <<0x06>>}])
      name = Advertising.encode([{types.complete_name, "Headphones"}])

      scan =
        Scan.new()
        |> Scan.observe(decode_one(data: flags), 0)
        |> Scan.observe(decode_one(data: name, event_type: 0x04, rssi: -70), 10)

      assert [device] = Scan.list(scan)
      assert device.name == "Headphones"
      assert device.flags == 0x06
      assert device.reports == 2
      assert device.last_seen == 10
      assert device.first_seen == 0
    end

    test "a later nameless advertisement does not wipe the name" do
      types = Advertising.types()
      name = Advertising.encode([{types.complete_name, "Pad"}])

      scan =
        Scan.new()
        |> Scan.observe(decode_one(data: name), 0)
        |> Scan.observe(decode_one(data: <<>>), 100)

      assert [%{name: "Pad", reports: 2}] = Scan.list(scan)
    end

    test "a scan response does not downgrade a connectable device" do
      scan =
        Scan.new()
        |> Scan.observe(decode_one(event_type: 0x00), 0)
        |> Scan.observe(decode_one(event_type: 0x04), 5)

      assert [%{connectable?: true}] = Scan.list(scan)
    end

    test "an unconnectable beacon stays unconnectable" do
      scan = Scan.observe(Scan.new(), decode_one(event_type: 0x03), 0)
      assert [%{connectable?: false}] = Scan.list(scan)
    end

    test "the same address with a different address type is a different device" do
      scan =
        Scan.new()
        |> Scan.observe(decode_one(address_type: 0x00), 0)
        |> Scan.observe(decode_one(address_type: 0x01), 0)

      assert Scan.count(scan) == 2
    end

    test "the order is first seen first, and a stronger signal does not jump the queue" do
      first = <<1, 1, 1, 1, 1, 1>>
      second = <<2, 2, 2, 2, 2, 2>>

      scan =
        Scan.new()
        |> Scan.observe(decode_one(address: first, rssi: -95), 0)
        |> Scan.observe(decode_one(address: second, rssi: -30), 1)
        |> Scan.observe(decode_one(address: first, rssi: -20), 2)

      assert Scan.list(scan) |> Enum.map(& &1.sequence) == [0, 1]
      assert Scan.list(scan) |> Enum.map(& &1.address) |> hd() == "01:01:01:01:01:01"
    end

    test "a device that stops advertising ages out" do
      scan = Scan.observe(Scan.new(), decode_one([]), 0)

      assert Scan.count(Scan.forget_stale(scan, 10_000, 30_000)) == 1
      assert Scan.count(Scan.forget_stale(scan, 40_000, 30_000)) == 0
    end

    test "age never goes negative on a clock that has not moved" do
      scan = Scan.observe(Scan.new(), decode_one([]), 500)
      [device] = Scan.list(scan)

      assert Scan.age(device, 400) == 0
      assert Scan.age(device, 900) == 400
    end
  end

  describe "reading the advertisement" do
    test "flags with BR/EDR Not Supported clear mean a dual-mode device" do
      types = Advertising.types()
      # 0x02 is General Discoverable with bit 2 clear: it also does classic.
      dual = Advertising.encode([{types.flags, <<0x02>>}])
      scan = Scan.observe(Scan.new(), decode_one(data: dual), 0)

      assert [device] = Scan.list(scan)
      assert Scan.dual_mode?(device) == true
    end

    test "this project's own advertisement reads back as LE only" do
      # Advertising.data/0 is what the controller app puts on the air, and it
      # sets BR/EDR Not Supported. Round-tripping it through the scanner is
      # the cheapest available check that the flag is being read off the same
      # bit it is written to.
      scan = Scan.observe(Scan.new(), decode_one(data: Advertising.data()), 0)

      assert [device] = Scan.list(scan)
      assert Scan.dual_mode?(device) == false
      assert device.appearance == Advertising.appearance()
      assert 0x1812 in device.services
    end

    test "no flags yet is nil, which is not the same as LE only" do
      scan = Scan.observe(Scan.new(), decode_one(data: <<>>), 0)
      assert [device] = Scan.list(scan)
      assert Scan.dual_mode?(device) == nil
    end

    test "a shortened name is flagged as one" do
      types = Advertising.types()
      data = Advertising.encode([{types.short_name, "Sony WH"}])
      scan = Scan.observe(Scan.new(), decode_one(data: data), 0)

      assert [%{name: "Sony WH", shortened_name?: true}] = Scan.list(scan)
    end

    test "a name that is not valid UTF-8 is dropped rather than drawn" do
      types = Advertising.types()
      data = Advertising.encode([{types.complete_name, <<0xFF, 0xFE>>}])
      scan = Scan.observe(Scan.new(), decode_one(data: data), 0)

      assert [device] = Scan.list(scan)
      assert device.name == nil
      assert Scan.label(device) == "A1:B2:C3:D4:E5:F6"
    end

    test "a nameless device is labelled by its address" do
      scan = Scan.observe(Scan.new(), decode_one(data: <<>>), 0)
      assert [device] = Scan.list(scan)
      assert Scan.label(device) == "A1:B2:C3:D4:E5:F6"
    end
  end
end
