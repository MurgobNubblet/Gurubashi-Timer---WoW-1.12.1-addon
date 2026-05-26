Gurubashi Timer - WoW 1.12.1 addon

Install:
1. Copy the GurubashiTimer folder into Interface\AddOns.
2. Launch/reload WoW.
3. Use /gt or /gurubashi.

Controls:
- Left-drag the timer to move it.
- Right-click the timer to open options.
- /gt options opens options.
- /gt test tests the alarm.
- /gt lock and /gt unlock toggle dragging.
- /gt show and /gt hide toggle visibility.
- /gt reset resets position/settings. The options-panel Reset button requires a second confirmation click.

3-hour cycle calibration:
- The timer always treats Gurubashi as a repeating 3-hour cycle.
- Default cycle is 00:00, 03:00, 06:00, 09:00, 12:00, 15:00, 18:00, 21:00 server time.
- Custom cycle uses an offset from that default, useful after server restarts or private-server drift.

Commands:
- /gt default
  Restores the normal 00/03/06/09/etc. server schedule.

- /gt offset MINUTES
  Sets the repeating cycle offset from 0 to 179 minutes.
  Example: /gt offset 60 = 01:00, 04:00, 07:00, 10:00, etc.
  Example: /gt offset 77 = 01:17, 04:17, 07:17, 10:17, etc.

- /gt chestnow
  Calibration shortcut. Use this when the chest has just spawned.
  It sets the current server minute as a chest spawn time, then repeats every 3 hours.

- /gt chestat HH:MM
  Sets the repeating cycle from a known server-time chest spawn.
  Example: /gt chestat 14:42 = 14:42, 17:42, 20:42, 23:42, etc.

- /gt status
  Prints the active schedule mode.

Options panel:
- The options window is tabbed: General, Alarms, Schedule.
- General: lock position, scale, transparency.
- Alarms: Alarm On, interval checkboxes, alert targets, snooze duration.
- Schedule: custom repeating cycle, cycle offset, Default, Chest Now, chest-window duration.

Important distinction:
- "At chest time" under alarms only controls the alarm at 00:00.
- "Chest Now" under schedule calibration changes the repeating timer schedule.

Notes:
- Timer uses server time from GetGameTime(). Vanilla gives server hour/minute only, so seconds are estimated between minute ticks.
- Chest Now is accurate to the current displayed server minute, not exact server seconds.


v1.3 note:
- Reworked the options menu into tabs so Reset/Test no longer collide with schedule text or timer controls.

v1.4 note:
- Replaced default stretched WoW button textures with flat dark custom buttons.
- Added live numeric labels above Scale, Transparency, Snooze, Cycle Offset, and Chest Window sliders.
- Kept the setting named Transparency instead of Opacity to match the slider behavior.


v1.5 note:
- Made the Cycle Offset slider wider and stopped it from rebuilding the options panel while dragging, so it should slide normally instead of feeling sticky.
- Moved Reset out of the footer and changed it to a two-click confirmation button under General to reduce accidental resets.
