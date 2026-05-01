---
active: true
layout: post
title: "RUNE Part 3: The Chip Wouldn't Wake Up"
subtitle: "A concurrency bug in a third-party library, found the hard way"
description: "The BNO085 sleep/wake feature, two layered bugs, and why you have to drain INT events before reading them."
date: 2026-04-28 00:00:00
background_color: '#0d0d0d'
---

<video src="/assets/rune/video/vid_20260401.webm" controls width="100%" style="max-width:640px; display:block; margin-bottom:1.5rem;"></video>

A wearable that drains its battery on the table is not a wearable. The BNO085 supports hardware sleep — `imu.modeSleep()` suspends the SH-2 sensor hub, drops IMU draw from ~1mA to a few hundred µA, and lets the nRF52840 enter deep sleep at ~2µA. Wrist goes flat on a surface: sleep. Significant arm movement: wake. Clean.

This feature was completely broken for two days.

---

## The plan

The BNO085 has a significant motion detector that keeps running in sleep mode. When the sensor detects a qualifying shake or arm movement, it asserts the INT pin LOW. The firmware ISR fires, sets a flag, and `loop()` processes the wake event. The sequence:

1. Detect `sleeping == true` + INT pin LOW
2. Call `imu.modeOn()` to restore the SH-2 transport
3. Drain the event FIFO
4. Call `exitSleep()` to re-enable gesture reports

Simple. Documented. Didn't work.

---

## Bug #1 — reading a suspended bus

The device went to sleep correctly. Shaking it did nothing. The interrupt fired — confirmed with a scope. The wake branch in firmware executed. Then silence. No events. No error codes. The device stayed asleep.

The root cause: after detecting INT LOW, the firmware called `imu.getSensorEvent()` directly to read the significant motion event. But the SH-2 I2C transport is **suspended during sleep**. `getSensorEvent()` reads nothing from a sleeping hub. The significant motion event is in the FIFO, waiting. It will never be decoded until you wake the hub first.

The INT pin tells you *that* there are events. `modeOn()` opens the transport. Then you drain.

```cpp
// Wrong — getSensorEvent() while hub is asleep returns nothing
if (digitalRead(BNO085_INT_PIN) == LOW && sleeping) {
  imu.getSensorEvent(&sensorValue);  // reads nothing, hub is suspended
  handleSleepShake();                // never fires
}

// Correct
if (digitalRead(BNO085_INT_PIN) == LOW && sleeping) {
  imu.modeOn();
  delay(50);  // let the SH-2 transport initialize
  while (imu.getSensorEvent(&sensorValue)) {
    if (sensorValue.sensorId == SH2_SIGNIFICANT_MOTION) {
      handleSleepShake();
    }
  }
}
```

Fix deployed. Wakeup started working — sometimes.

---

## Bug #2 — the library race condition

After fixing Bug #1, a second problem surfaced: `enableReport()` calls were failing silently after reconnecting. Sensors weren't enabling. The rotation vector report never started. The serial log showed the enable calls happening; reports never arrived.

The [SparkFun BNO08x Cortex library](https://github.com/sparkfun/SparkFun_BNO08x_Arduino_Library) has a design flaw in its INT pin handling. When you pass an INT pin to `begin()`:

```cpp
imu.begin(0x4B, Wire, INT_PIN, RST_PIN);  // sets _int_pin internally
```

The library stores `_int_pin`. Then **every subsequent `enableReport()` call** invokes `hal_wait_for_int()` **before** sending the enable command to the BNO085. It waits for an INT pulse that the BNO085 has no reason to send, because it hasn't received the command yet. After 500ms, `hal_wait_for_int()` times out, calls `hal_hardwareReset()`, and the enable fails. This happens for every single report you try to enable.

It's a classic deadlock: waiting for an acknowledgement to a message that hasn't been sent.

The fix is to not pass the INT pin to `begin()` at all:

```cpp
// Two arguments only — leaves _int_pin = -1, bypasses hal_wait_for_int()
imu.begin(0x4B, Wire);

// Register your own interrupt separately for wake detection
attachInterrupt(digitalPinToInterrupt(BNO085_INT_PIN), [](){}, FALLING);
```

I2C communication is synchronous — the INT pin is not needed for normal operation. `enableReport()` works fine without it. The interrupt you register separately handles wake detection in `loop()`.

Both fixes landed in commit `966e4c9` on April 27th.

---

## Is this a concurrency bug?

Technically: `hal_wait_for_int()` blocks the calling thread waiting for a hardware signal that cannot arrive because the prerequisite (sending the command) hasn't happened yet. The library assumes the INT pin will pulse after every enable command. The BNO085 does not work that way without specific initialization that the library doesn't perform.

Whether you call it a race condition, a sequencing error, or just wrong assumptions in the blocking path — the practical effect is the same: `enableReport()` silently fails, reports never start, and the firmware behaves as if the sensor isn't there.

This was found by cross-referencing the [SH-2 reference manual](https://www.ceva-ip.com/wp-content/uploads/2019/10/SH-2-Reference-Manual.pdf) (which documents that the I2C transport suspends during sleep), GitHub issues on the SparkFun repo, and similar reports of `enableReport()` failing in other projects using this library. The pattern — "pass fewer arguments to `begin()`" — was not in the library documentation.

---

## What this costs in battery terms

Sleep mode is not optional for hitting the battery targets. 300mAh at 3.7V = 1.11 Wh. Without sleep:

- nRF52840 active + BLE: ~7–10mA
- BNO085 running reports: ~1mA
- Total: ~8–11mA continuous → **10–14 hours**. One night, on a good night.

With sleep between gestures:
- nRF52840 deep sleep: ~2µA
- BNO085 in sleep with significant motion active: ~few hundred µA
- BLE disconnected during sleep: 0mA radio

The difference between "one night" and "two days" lives in whether sleep actually works. It does now. The current device survives a full night. Getting to two days means tuning the sleep entry/exit thresholds and measuring real draw per state with a multimeter — which is the next debugging session.

---

## The documentation fix

Both bugs are now documented in `wristturn_audrino/CLAUDE.md`:

```
### BNO08x INT pin — known library bug
Do NOT pass INT/RST pins to begin() for this library.
Discovered and confirmed 2026-04-27.

### BNO085 modeSleep() / shake-to-wake — architecture
Correct wake sequence: detect INT LOW → modeOn() + delay(50ms)
→ drain FIFO → exitSleep(). Wrong: calling getSensorEvent() while hub is asleep.
```

The next person — or next Claude session — does not spend two days on this.
