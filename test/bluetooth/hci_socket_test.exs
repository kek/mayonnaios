defmodule ScenicRg40xxv.Bluetooth.HCISocketTest do
  use ExUnit.Case, async: true

  alias ScenicRg40xxv.Bluetooth.HCISocket

  # There is no AF_BLUETOOTH on this machine, so nothing here opens a socket.
  # What can be tested from a desk is the part that would be wrong silently:
  # the byte layout going out and the parse coming back. A wrong opcode byte
  # order or an off-by-one on the event length reads as "the controller did
  # not answer" on the device, which is the same symptom as a dead chip --
  # exactly the confusion this module exists to remove.

  describe "command framing" do
    test "HCI Reset is the four bytes from the spec" do
      # Opcode 0x0C03, little-endian on the wire, no parameters.
      assert HCISocket.reset() == <<0x01, 0x03, 0x0C, 0x00>>
    end

    test "Read Local Version is opcode 0x1001, also little-endian" do
      assert HCISocket.read_local_version() == <<0x01, 0x01, 0x10, 0x00>>
    end

    test "parameters are appended and their length counted" do
      assert HCISocket.command(0x0C03, <<0xAA, 0xBB>>) == <<0x01, 0x03, 0x0C, 0x02, 0xAA, 0xBB>>
    end
  end

  describe "sockaddr/2" do
    test "is dev then channel, little-endian, for OTP to prefix the family to" do
      # OTP writes sa_family itself and copies :addr into sa_data, so these
      # four bytes plus the two it adds are the six-byte sockaddr_hci.
      assert HCISocket.sockaddr(0, 1) == %{family: 31, addr: <<0, 0, 1, 0>>}
      assert HCISocket.sockaddr(1, 3) == %{family: 31, addr: <<1, 0, 3, 0>>}
    end
  end

  describe "command_complete/2" do
    test "returns the parameters of the matching completion" do
      packet = <<0x04, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00>>
      assert HCISocket.command_complete(packet, 0x0C03) == {:ok, <<0x00>>}
    end

    test "another command's completion is unrelated, not an error to give up on" do
      # The recv loop keeps waiting on this, which is the difference between
      # tolerating an unsolicited event and timing out on it.
      packet = <<0x04, 0x0E, 0x04, 0x01, 0x01, 0x10, 0x00>>
      assert {:error, {:unrelated, ^packet}} = HCISocket.command_complete(packet, 0x0C03)
    end

    test "a non-event packet is unrelated too" do
      packet = <<0x02, 0x00, 0x20, 0x01, 0x00, 0xFF>>
      assert {:error, {:unrelated, ^packet}} = HCISocket.command_complete(packet, 0x0C03)
    end

    test "a different event code is unrelated" do
      # 0x0F is Command Status, which is not a completion.
      packet = <<0x04, 0x0F, 0x04, 0x00, 0x01, 0x03, 0x0C>>
      assert {:error, {:unrelated, ^packet}} = HCISocket.command_complete(packet, 0x0C03)
    end

    test "a length that disagrees with the payload is truncated, not parsed" do
      # plen says three return parameters, only one is present. Parsing this
      # anyway is how a short read turns into a plausible-looking version.
      packet = <<0x04, 0x0E, 0x06, 0x01, 0x03, 0x0C, 0x00>>
      assert {:error, {:truncated, ^packet}} = HCISocket.command_complete(packet, 0x0C03)
    end
  end

  describe "status/1" do
    test "0x00 is success and hands back the rest" do
      assert HCISocket.status(<<0x00, 0x09, 0x01>>) == {:ok, <<0x09, 0x01>>}
    end

    test "a non-zero status is reported rather than parsed past" do
      # 0x12 is Invalid HCI Command Parameters. The bytes after it are not
      # return parameters, so treating them as a version would invent one.
      assert HCISocket.status(<<0x12, 0x09>>) == {:error, {:hci_status, 0x12}}
    end

    test "empty return parameters are an error, not a success" do
      assert HCISocket.status(<<>>) == {:error, :no_return_parameters}
    end
  end

  describe "local_version/1" do
    test "decodes this board's actual RTL8821CS reply" do
      # These are not invented. btrtl reads the same fields over the same
      # command during setup and logs them, and this device logged:
      #
      #   Bluetooth: hci0: RTL: examining hci_ver=08 hci_rev=000c
      #                         lmp_ver=08 lmp_subver=8821
      #
      # so hci_version 8, hci_revision 0x000C, lmp_version 8, lmp_subversion
      # 0x8821. All the 16-bit fields are little-endian on the wire.
      #
      # Manufacturer is the one value here not taken from that line -- btrtl
      # does not log it. 0x005D is Realtek in the SIG's assigned company
      # identifiers, and confirming it is precisely what probe_bluetooth/0 is
      # for on real hardware.
      params = <<0x08, 0x0C, 0x00, 0x08, 0x5D, 0x00, 0x21, 0x88>>

      assert {:ok, version} = HCISocket.local_version(params)
      assert version.manufacturer == 0x005D
      assert version.manufacturer_name == "Realtek"
      assert version.hci_version == 8
      assert version.core_spec == "4.2"
      assert version.hci_revision == 0x000C
      assert version.lmp_version == 8
      assert version.lmp_subversion == 0x8821
    end

    test "does not confuse the byte order of the two-byte fields" do
      # Big-endian would read manufacturer 0x5D00 here, which is nobody.
      params = <<0x09, 0x01, 0x02, 0x09, 0x0F, 0x00, 0x03, 0x04>>

      assert {:ok, version} = HCISocket.local_version(params)
      assert version.manufacturer == 0x000F
      assert version.manufacturer_name == "Broadcom"
      assert version.hci_revision == 0x0201
      assert version.core_spec == "5.0"
    end

    test "an unknown company identifier is shown as hex rather than guessed at" do
      params = <<0x08, 0x00, 0x00, 0x08, 0xAB, 0x0C, 0x00, 0x00>>
      assert {:ok, %{manufacturer_name: "0x0CAB"}} = HCISocket.local_version(params)
    end

    test "the wrong number of bytes is an error, not a partial version" do
      assert {:error, {:malformed_local_version, <<0x08>>}} = HCISocket.local_version(<<0x08>>)
      assert {:error, {:malformed_local_version, <<>>}} = HCISocket.local_version(<<>>)
    end
  end

  describe "the exchange a healthy controller produces" do
    test "the two replies parse end to end into a Realtek version" do
      # A rehearsal of read_version/2 without a socket, so this fails if the
      # framing and the parse disagree even though each is individually
      # self-consistent.
      #
      # The version payload carries this board's real values (hci_rev 0x000C,
      # lmp_subver 0x8821, from btrtl's own log line). The HCI framing around
      # it is constructed from the spec, not captured -- nothing has yet
      # recorded what hci0 actually puts on a user channel, which is the whole
      # point of probe_bluetooth/0 and the reason this test cannot stand in
      # for running it.
      reset_reply = <<0x04, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00>>

      version_reply =
        <<0x04, 0x0E, 0x0C, 0x01, 0x01, 0x10, 0x00, 0x08, 0x0C, 0x00, 0x08, 0x5D, 0x00, 0x21,
          0x88>>

      assert {:ok, reset_params} = HCISocket.command_complete(reset_reply, 0x0C03)
      assert HCISocket.status(reset_params) == {:ok, <<>>}

      assert {:ok, version_params} = HCISocket.command_complete(version_reply, 0x1001)
      assert {:ok, rest} = HCISocket.status(version_params)
      assert {:ok, version} = HCISocket.local_version(rest)
      assert version.manufacturer_name == "Realtek"
    end

    test "a controller that refuses Reset is an error, not a version" do
      # Status 0x0C, Command Disallowed. The failure this guards against is
      # carrying on to Read Local Version and reporting whatever came back.
      reply = <<0x04, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x0C>>

      assert {:ok, params} = HCISocket.command_complete(reply, 0x0C03)
      assert HCISocket.status(params) == {:error, {:hci_status, 0x0C}}
    end
  end

  describe "core_spec/1" do
    test "says so when the version byte is not one it knows" do
      # Better than reporting a wrong specification number for a controller
      # newer than this table.
      assert HCISocket.core_spec(99) == "unknown (99)"
    end
  end

  # The socket half cannot run here, but it must fail as a tuple rather than
  # raise: Diagnostics calls probe/1 inside a GenServer that must survive it.
  if match?({:unix, :darwin}, :os.type()) do
    describe "probe/1 on a machine with no AF_BLUETOOTH" do
      test "returns an error tuple instead of raising" do
        assert {:error, :eafnosupport} = HCISocket.probe()
      end
    end
  end
end
