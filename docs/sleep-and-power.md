> **Documentation for current `trunk`; installed firmware may differ.**

# Sleep, wake, and power off

**Status:** backlight sleep/wake is **Verified**. The extra low-power mode is
**Experimental**; its total saving is **Estimated** and unmeasured. This is fake
sleep, not suspend-to-RAM.

## Prerequisites

- MayonnaiOS is running on the Anbernic RG40XXV handheld.
- Save game progress before sleeping or powering off.
- If debugging over WiFi, remember that low-power entry takes `wlan0` down and
  ends the SSH session.

## Sleep and wake

1. Briefly press the physical power button, or choose **System → Sleep**.
2. Leave the launcher idle for three minutes for automatic sleep. The timer does
   not run while charging or while an external program/BEAM app is active; it
   starts fresh when returning to the launcher.
3. Press any launcher/gamepad button to wake. The waking press is consumed so it
   does not also launch a game or move a cursor. The volume rocker is handled by
   another input path and does not wake the device.
4. To disable only the idle timer, choose **System → Automatic sleep: on/off**.
   The setting is persisted across reboot and firmware update. Manual power-button
   and menu sleep continue to work.

A successful sleep turns off the GPIO backlight, stops the Scenic renderer,
takes WiFi down, attempts a lower CPU governor, and offlines three of four cores.
On wake those actions are reversed before the backlight returns. Governor and
rfkill steps are no-ops on the current system image, and individual extra steps
may fail without preventing the remaining recovery steps.

**Success:** the panel goes dark and the application-controlled LED flashes green
slowly; after a button press, the current frame returns under a solid green LED.
`MayonnaiOS.Sleep.asleep?/0` reports the last backlight value written, not an
independent optical measurement.

## Power off orderly

Use **Select+Menu**, or choose **System → Power off** and confirm with **Y**.
Both call the Nerves poweroff path after accepting the request. This is preferable
to pulling power because it lets active writes settle.

Do not use a long power-button hold as the normal shutdown. After about four
seconds the PMIC cuts the rail in hardware without asking Linux or flushing data.

## LED meanings

| Signal | Meaning |
|---|---|
| Quick flashing green | BEAM is starting the supervision tree. |
| Solid green | Application startup completed and the device is running. |
| Slow flashing green | MayonnaiOS considers the device asleep. |
| Slow blinking red | Battery is at or below 20% and not charging; it clears at 30% or while charging/full. |
| Quick blinking red | Application startup failed; failure takes priority over low battery. |
| Yellow in the other window | PMIC charge indication, not controlled by MayonnaiOS. |

## Evidence and limitations

Firmware `3cc86f59` recorded a **Measured** awake baseline of 415 mA at 3.78 V
(1.57 W). The 255–315 mA backlight saving and 150–250 mA full fake-sleep draw are
**Estimated**, not measurements. Backlight dark/light behavior is **Verified**;
extra low-power effects and total savings must not be described as measured.
The board exposes no useful deep suspend, and current s2idle cannot provide the
promised behavior, so CPUs continue running.

## Troubleshooting

- **Panel stays lit:** sleep did not count; inspect logs for a backlight write
  error. MayonnaiOS does not offline cores behind a lit panel.
- **WiFi disappears:** expected during low-power sleep. Wake before reconnecting.
- **A game reacts to the wake press:** an external program owns its own input
  descriptor; only launcher-owned input can be swallowed.
- **Power off reboots:** this is a board-support regression; inspect the AXP717
  soft-poweroff patch in the RG40XXV system repository.
- **LED differs from the table:** see `MayonnaiOS.Led` for arbitration and exact
  sysfs behavior.

API reference: `MayonnaiOS.Sleep`, `MayonnaiOS.AutoSleep`,
`MayonnaiOS.LowPower`, `MayonnaiOS.Led`, and `MayonnaiOS.Power`. Status
summary: [RG40XXV hardware status](hardware-status.md).

[Edit this page](https://github.com/kek/mayonnaios/edit/trunk/docs/sleep-and-power.md) ·
[Report a documentation issue](https://github.com/kek/mayonnaios/issues/new)
