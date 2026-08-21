defmodule MayonnaiOS.Bluetooth.HOGP do
  @moduledoc """
  The attribute database this device presents: a HID gamepad over GATT.

  HID over GATT is the profile Xbox controllers, Bluetooth keyboards and most
  modern peripherals use, and it is a small number of services arranged in a
  way both Windows and BlueZ recognise without any driver:

      0x1800  Generic Access          the name and the gamepad appearance
      0x1801  Generic Attribute       Service Changed, so a host can be told
                                      the database moved under it
      0x180A  Device Information      PnP ID -- who made this and what it is
      0x180F  Battery                 the handheld's own battery, notified
      0x1812  Human Interface Device  the report descriptor and the reports

  `MayonnaiOS.Bluetooth.GATT` turns the declaration below into attributes and
  answers requests against it. This module is only the declaration and the few
  handles the rest of the stack needs to find again.

  ## Order is a compatibility surface

  The services are declared in ascending UUID order and the HID service comes
  last, which is what nearly every commercial HOGP device does. That is not
  cosmetic: some hosts discover the HID service, read the report map, and
  start subscribing while discovery of the rest is still in flight, and a
  layout that matches what those hosts see every day is a layout their code
  paths have been tested against.

  ## The PnP ID is not borrowed

  Vendor 0x1209 is pid.codes, the identifier set aside for open-source
  hardware that has no USB-IF membership, and 0x4D4F is unregistered within
  it. Picking a real vendor's numbers here -- Microsoft's, say -- would make
  Steam apply that controller's button mapping to this one, which is a worse
  outcome than being unrecognised: an unrecognised gamepad gets the generic
  mapping, which is correct, while a misrecognised one gets a layout that is
  wrong in a way that looks like the device is faulty.

  ## Everything in the HID service needs encryption

  Report Map, the report itself and its subscription descriptor are all marked
  `read: :encrypted` and `write: :encrypted`. This is required by the profile,
  and it is also the mechanism that starts pairing: a host reads the report
  map, is refused, pairs, and reads it again. Marking them open would produce
  a device Windows connects to and never bonds with.

  The Battery Service is deliberately *not* encrypted. It is a percentage, it
  is useful in a scan, and nothing about it is worth a pairing dialog.
  """

  alias MayonnaiOS.Bluetooth.GATT
  alias MayonnaiOS.Controller.Report

  @generic_access 0x1800
  @generic_attribute 0x1801
  @device_information 0x180A
  @battery_service 0x180F
  @hid_service 0x1812

  @device_name 0x2A00
  @appearance 0x2A01
  @service_changed 0x2A05
  @battery_level 0x2A19
  @manufacturer_name 0x2A29
  @pnp_id 0x2A50
  @hid_information 0x2A4A
  @report_map 0x2A4B
  @hid_control_point 0x2A4C
  @report 0x2A4D
  @protocol_mode 0x2A4E

  @cccd 0x2902
  @report_reference 0x2908

  # HID Information: HID specification 1.11, no localisation, and the flags
  # RemoteWake and NormallyConnectable. NormallyConnectable is the one that
  # matters -- it tells the host this device will advertise again by itself
  # after a disconnect, which is what makes a host willing to wait for it
  # rather than dropping the bond.
  @hid_info <<0x0111::16-little, 0x00, 0x03>>

  # Report protocol rather than boot protocol. A gamepad has no boot protocol
  # -- that is a keyboard and mouse thing -- but the characteristic is cheap
  # and some hosts write it unconditionally.
  @report_protocol <<0x01>>

  # See the moduledoc. Source 0x02 is the USB Implementer's Forum's numbering.
  @pnp <<0x02, 0x1209::16-little, 0x4D4F::16-little, 0x0100::16-little>>

  @report_id 1
  @input_report 0x01

  @doc "The report ID the report reference descriptor and the descriptor agree on."
  @spec report_id() :: pos_integer()
  def report_id, do: @report_id

  @doc """
  Build the database.

  `name` is what appears in the host's device list, and the battery level is
  seeded so that a host reading it before the first poll gets a number rather
  than an empty value -- which some hosts render as 0% and others as a fault.
  """
  @spec build(String.t(), keyword()) :: GATT.t()
  def build(name, opts \\ []) do
    battery = Keyword.get(opts, :battery, 100)

    GATT.build(declaration(name), %{
      report: Report.encode(Report.released()),
      battery_level: <<battery>>
    })
  end

  defp declaration(name) do
    [
      {:service, @generic_access,
       [
         {@device_name, [:read], value: name},
         {@appearance, [:read],
          value: <<MayonnaiOS.Bluetooth.Advertising.appearance()::16-little>>}
       ]},
      {:service, @generic_attribute,
       [
         # Empty value, indicate-only. A host subscribes to this and is told
         # when handles move; nothing here ever indicates on it yet, but its
         # absence is what makes some hosts cache a database forever.
         {@service_changed, [:indicate], descriptors: [{@cccd, [write: :open]}]}
       ]},
      {:service, @device_information,
       [
         {@manufacturer_name, [:read], value: "MayonnaiOS"},
         {@pnp_id, [:read], value: @pnp}
       ]},
      {:service, @battery_service,
       [
         {@battery_level, [:read, :notify],
          value: {:dynamic, :battery_level}, descriptors: [{@cccd, [write: :open]}]}
       ]},
      {:service, @hid_service,
       [
         {@hid_information, [:read], value: @hid_info, read: :encrypted},
         {@report_map, [:read], value: Report.descriptor(), read: :encrypted},
         # Write without response, and the host sends 0x00 (suspend) or 0x01
         # (exit suspend) when it sleeps. Nothing acts on it yet; it is
         # required by the profile and its absence makes some hosts refuse the
         # service outright.
         {@hid_control_point, [:write_without_response], write: :encrypted},
         # Always reads back as report protocol, and a write to it is accepted
         # and ignored. Deliberately: boot protocol is a keyboard and mouse
         # thing, there are no boot report characteristics here to switch to,
         # and a characteristic that echoed back 0x00 while the device carried
         # on sending report-protocol reports would be a lie a host could act
         # on. The characteristic exists because hosts write it unconditionally
         # and some refuse the service when it is missing.
         {@protocol_mode, [:read, :write_without_response],
          value: @report_protocol, read: :encrypted, write: :encrypted},
         {@report, [:read, :notify],
          value: {:dynamic, :report},
          read: :encrypted,
          descriptors: [
            {@cccd, [read: :encrypted, write: :encrypted]},
            # Which report in the descriptor this characteristic carries, and
            # in which direction. Report ID 1, Input. A host that finds a
            # report characteristic with no reference descriptor cannot match
            # it to the report map and ignores it.
            {@report_reference, [value: <<@report_id, @input_report>>, read: :encrypted]}
          ]}
       ]}
    ]
  end

  @doc """
  The handle notifications are sent on, and the handle of its subscription
  descriptor.

  Looked up from the built database rather than written down, so that the
  declaration stays the single place handles come from.
  """
  @spec report_handles(GATT.t()) :: %{value: non_neg_integer(), cccd: non_neg_integer() | nil}
  def report_handles(db) do
    value = GATT.find_handle(db, @report)
    %{value: value, cccd: GATT.cccd_handle(db, value)}
  end

  @doc "The same, for the battery level."
  @spec battery_handles(GATT.t()) :: %{value: non_neg_integer(), cccd: non_neg_integer() | nil}
  def battery_handles(db) do
    value = GATT.find_handle(db, @battery_level)
    %{value: value, cccd: GATT.cccd_handle(db, value)}
  end

  @doc "The HID service UUID, 0x1812, which is also what the advertisement carries."
  def hid_service, do: @hid_service
end
