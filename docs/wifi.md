> **Documentation for current `trunk`; installed firmware may differ.**

# Connect to and change WiFi

**Status: Verified.** WiFi is the only remote-access path observed on the
Anbernic RG40XXV handheld. USB gadget setup exists, but USB-C enumeration has
not been observed; an unusable initial network can therefore require reflashing.

## Prerequisites

- MayonnaiOS is already running on the RG40XXV.
- The network is open, WPA-PSK, or SAE and its passphrase is available.
- Stay in range of a known-good saved network while adding another when possible.

## Connect or change networks

1. Open **System → WiFi**. The list combines nearby networks with saved networks
   that are currently out of range.
2. Move with D-pad up/down and press **A**. An open network joins immediately; a
   saved network becomes preferred without asking for its key; a new secured
   network opens the passphrase wheel.
3. In the wheel, use left/right to move the caret and up/down to change its
   character. **L1/R1** jump among lowercase, uppercase, digits, and symbols.
   The passphrase remains visible so errors can be found. Press **A** to submit
   or **B** to cancel. WPA passphrases must contain 8–63 characters.
4. To replace a saved key, select its row and press **X**, then use the wheel.
5. To forget a saved network, select it and press **Y twice**. Moving or pressing
   **B** after the first press cancels the confirmation.

## Success

The panel reports that it joined the selected SSID and shows its address. A LAN
association counts as success even if that LAN currently has no internet uplink.
The status bar also reflects a connection that completes after the screen's
30-second wait has expired.

## Safety guarantees and limitations

Joining is additive: `MayonnaiOS.WiFi.join/3` keeps all existing entries,
puts the newly chosen network first, and persists the result. The credentials
built into the firmware therefore remain available. If the access point reports
a rejected key, the panel says so and removes that bad entry so repeated attempts
do not disrupt the network that works. A generic timeout leaves the entry in
place because association or DHCP may still finish.

802.1X/EAP and WEP networks are shown but cannot be joined from the panel.
Enterprise setup needs identity/certificate/method fields, and WEP needs key-slot
handling that has not been verified. A maintainer may configure an exceptional
network over [SSH and IEx](ssh-and-iex.md) with `VintageNet.configure/2`, but do
that only while another recovery route is available.

## Troubleshooting

- **No radio:** leave the screen and inspect logs through the [advanced access
  guide](ssh-and-iex.md). Host development intentionally reports no radio.
- **Passphrase refused:** press **A** to return to the list, select the network,
  press **X**, and re-enter it. The rejected key has already been withdrawn.
- **Timed out:** wait and inspect the status bar before retrying; the saved entry
  remains configured.
- **Initial firmware cannot join:** because WiFi is the only verified remote
  access, correct the build-time credentials and reflash the card.

API reference: `MayonnaiOS.WiFi`, `MayonnaiOS.WiFi.App`, and
`MayonnaiOS.WiFi.Editor`. See also [RG40XXV hardware status](hardware-status.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/wifi.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
