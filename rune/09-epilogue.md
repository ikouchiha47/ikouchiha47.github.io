---
active: true
layout: group_page
group: rune
group_title: "RUNE"
group_url: "/rune/"
title: "RUNE Epilogue: Read the Datasheet"
subtitle: "How every fix in this project came from reading documentation, not throwing components"
description: "On reading datasheets, analysing real data before writing code, and why the best engineers I know do exactly this while interview prep teaches the opposite."
date: 2026-05-03 00:00:00
background_color: '#0a0a0a'
---

![The device that got debugged, not replaced](/assets/rune/img/IMG_20260429_174628015.jpg)

Every meaningful fix in this project came from reading something first.

Not Googling "BNO085 not working" and hoping someone had the same problem. Reading the SH-2 Reference Manual. Reading the SparkFun library source. Reading the LSM6DS3 zero-rate offset specification. Reading the datasheet section on MASR. Every time something broke in a way that wasn't immediately obvious, the answer was in a document that existed before the problem did.

This is not a remarkable approach. It is, somehow, increasingly uncommon.

---

## Significant Motion — what it actually is

The BNO085 ships with a set of sensor reports. You don't get just raw IMU data — you get the output of a sensor hub running Bosch SH-2 firmware, and that firmware has opinions about what you probably want.

From the [SH-2 Reference Manual (CEVA/Bosch)](https://www.ceva-ip.com/wp-content/uploads/2019/10/SH-2-Reference-Manual.pdf):

> **Significant Motion** — Reports when the device has experienced significant motion since the last time it was stationary. Designed for use as a wake source. Once triggered, it does not repeat until the device returns to rest.

That last sentence matters. It's a one-shot detector. It fires once, then arms again when the device is still. It does not continuously report motion. If you treat it like a continuous sensor and poll it looking for ongoing movement, you will always see silence.

The SparkFun library exposes this as `SH2_SIGNIFICANT_MOTION` but wraps it via `imu.enableReport()` which hardcodes `wakeupEnabled=false`. That field — buried in `sh2_SensorConfig_t` — is what tells the BNO085 to assert the INT pin on a wake event while the hub is sleeping. Without it, the detector runs internally but never surfaces to you. The fix required going past the library wrapper to the raw SH-2 config:

```cpp
sh2_SensorConfig_t cfg = {};
cfg.reportInterval_us = SHAKE_WAKE_INTERVAL_US;  // 0.5 Hz or 5 Hz
cfg.wakeupEnabled = true;                         // THIS is what makes it a wake source
int status = sh2_setSensorConfig(SH2_SHAKE_DETECTOR, &cfg);
```

This is not in the Arduino example code. It is on page 47 of the SH-2 reference manual.

---

## What reports the BNO085 actually provides

The BNO085 is not one sensor. It is a sensor hub that runs multiple virtual sensors simultaneously, each with its own report rate and behaviour. From the [BNO085 datasheet](https://www.ceva-ip.com/wp-content/uploads/2019/10/BNO080_085-Datasheet.pdf) and SH-2 reference:

| Report ID | What it gives you | Used in RUNE |
|---|---|---|
| `ROTATION_VECTOR` | Fused quaternion (accel+gyro+mag, 9DOF) — stable yaw | Gesture baseline, calibration |
| `GYROSCOPE_CALIBRATED` | Bias-corrected angular velocity (rad/s) | Gesture FSM input |
| `LINEAR_ACCELERATION` | Acceleration with gravity removed | Shake detection |
| `STABILITY_CLASSIFIER` | On-table / stationary / stable / in-motion | Calibration window, sleep trigger |
| `SHAKE_DETECTOR` | One-shot shake event, configurable as wake source | Sleep/wake |
| `TAP_DETECTOR` | Single and double tap events | `tap` gesture |
| `STEP_COUNTER` | Cumulative step count | Unused (wearable experiment) |

Each of these has a `reportInterval_us` — how often the hub sends updates. Setting it to 0 stops the report. This is how you "disable" a sensor in the SH-2 protocol: `imu.enableReport(SENSOR_REPORTID_X, 0)`. There is no separate disable call. This is also in the SH-2 reference manual, not the library README.

The Stability Classifier is what made calibration possible. It outputs:
- `1` — on a table (flat, high-confidence rest)
- `2` — stationary (some motion, possibly handheld)
- `3` — **stable** (sensor confident in current orientation — ideal for calibration)
- `4+` — in motion

The calibration fix in [Part 5](/rune/05-calibration) collected samples preferentially when `stab=3`. That classification comes from this report. It's not something we computed — the BNO085 computes it internally, continuously, as part of its fusion pipeline. We just had to read the manual to know it existed.

---

## The Seeed Studio and SparkFun example code

Both vendors ship example sketches. They are useful for verifying that the hardware is connected and the library initialises. They are not useful for understanding what the hardware can actually do.

The [SparkFun BNO08x Arduino library](https://github.com/sparkfun/SparkFun_BNO08x_Arduino_Library) ships examples for rotation vector, accelerometer, gyroscope. The sleep/wake example is incomplete — it demonstrates entering sleep but doesn't show the correct wake sequence. The Significant Motion example doesn't set `wakeupEnabled`. These are not bugs in the library; they are demos, not production code.

The [Seeed Studio XIAO nRF52840 docs](https://wiki.seeedstudio.com/XIAO_BLE/) cover the board well. They do not cover what happens when the LSM6DS3 onboard IMU has ±10°/s zero-rate offset and you try to use it for yaw detection. That information is in the [LSM6DS3 datasheet (ST)](https://www.st.com/resource/en/datasheet/lsm6ds3.pdf), Table 3, "Zero-rate level" row: `±10 mdps/digit` at 1kHz ODR, meaning ~10°/s worst case. Four seconds of gyro integration at that rate = 40° of phantom yaw. The gesture threshold was 15°. The math explains the serial log.

Every refactor in this project was preceded by reading something. The gyro FSM rewrite came after reading the SH-2 gyroscope report documentation and understanding that the bias-corrected output was already temperature-compensated — which meant the jerk gate threshold could be set tighter than it could for a raw gyro. The calibration window fix came after reading the MASR section of the BNO085 datasheet and understanding that "still" = throttled sample rate. The sleep fix came after reading the SH-2 transport specification section on hub sleep states.

Reading the datasheet before writing the fix is not a virtue. It is just the fastest path.

---

## On data before constants

The gesture thresholds in this firmware are not made up. Every tunable constant — `JERK_ONSET_THRESHOLD = 8.0 rad/s²`, `INTEGRAL_THRESHOLD = 0.25 rad`, `ZUPT_GYRO_THRESHOLD = 0.03 rad/s` — was derived from actual session recordings.

The `tools/` directory has `analyze_firmware_log.py`. The firmware was run in raw mode, session JSONL files were recorded, and the gyro signal was plotted for clean pronation sweeps vs idle drift. The 8 rad/s² threshold sits cleanly above the noise floor and below the onset spike of any deliberate gesture. The 0.03 rad/s ZUPT threshold was measured as the maximum residual gyro reading during confirmed stillness, with bias correction applied.

You cannot pick those numbers from first principles. You measure them from your specific sensor on your specific wrist in your specific orientation. The CLAUDE.md says it directly:

> "If a constant or threshold is not validated against real-world data, it is not production ready. Guard it, disable it by default, document why it's unvalidated."

This is the only honest approach to sensor thresholds. Everything else is superstition in code.

---

## On system design interviews

There is a genre of engineering interview where you are asked to design Twitter, or Uber, or a URL shortener, and the correct answer involves drawing boxes — load balancer, application server, Redis, message queue, sharded database — in about 45 minutes.

I have given these interviews. I have passed these interviews. I have watched people who are very good at this interview style struggle when a real system behaves unexpectedly, because the real system doesn't care about your box diagram. It has a race condition in a third-party library that deadlocks sensor enables. It has a zero-rate offset that accumulates faster than your rebase timer. It has a firmware that silently drops events when you call it from the wrong thread context.

The skills that make those interviews tractable — pattern matching to known architectures, fluency with distributed systems vocabulary, comfort with whiteboard hand-waving — are genuinely useful skills. They are not the same skills as reading an error and knowing where to look. They are not the same as pulling up a datasheet and finding the relevant register. They are not the same as writing a test that fails before you write the fix.

I am not claiming this project is hard. It is a wrist-worn remote control for a television. The chips are commodity hardware. The protocols are documented. The library source is on GitHub.

What I am saying is that most of the time I have spent debugging was spent reading, and most of the time I have saved was saved by reading before coding. That pattern has been more consistently useful across more contexts — embedded firmware, distributed systems, database internals, compiler toolchains — than any amount of architectural vocabulary.

The boxes are fine. Know what's inside them.

---

## What was read for this project

In rough chronological order:

- [Seeed Studio XIAO nRF52840 Sense wiki](https://wiki.seeedstudio.com/XIAO_BLE/) — board pinout, BLE setup, flash procedure
- LSM6DS3TR-C datasheet (STMicroelectronics) — search "LSM6DS3TR-C" on st.com, Table 3, zero-rate level ±10 mdps/digit. This is what confirmed 6DOF yaw was a dead end.
- [BNO085 datasheet (CEVA/Bosch)](https://www.ceva-ip.com/wp-content/uploads/2019/10/BNO080_085-Datasheet.pdf) — report IDs, MASR behaviour, power modes, tap detector configuration
- [SH-2 Reference Manual](https://www.ceva-ip.com/wp-content/uploads/2019/10/SH-2-Reference-Manual.pdf) — full sensor report list, `sh2_SensorConfig_t` fields, hub sleep/wake architecture, transport behaviour during sleep. This is the document that fixed the wakeup bug.
- [SparkFun BNO08x library source](https://github.com/sparkfun/SparkFun_BNO08x_Arduino_Library) — specifically `hal_wait_for_int()` in the I2C HAL. This is where the INT pin race condition was found.
- [androidtvremote2 Python library](https://github.com/tronikos/androidtvremote2) — Polo pairing protocol, protobuf message format, port assignments. This is the source the Kotlin implementation follows.
- [Nordic nRF52840 Product Specification](https://infocenter.nordicsemi.com/pdf/nRF52840_PS_v1.1.pdf) — deep sleep current (~2µA), WFE instruction, interrupt wakeup behaviour
- [Audiolabs DTW tutorial](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C3/C3S2_DTWbasic.html), [Benbasat 2002](https://3dvar.com/Benbasat2002An.pdf), [$1 recognizer](http://depts.washington.edu/acelab/proj/dollar/index.html) — gesture recognition research for RUNE-III

Every fix has a corresponding document. The document existed before the bug. That is always true. The question is whether you read it.
