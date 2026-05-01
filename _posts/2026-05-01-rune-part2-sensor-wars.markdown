---
active: true
layout: post
title: "RUNE Part 2: The Sensor Wars"
subtitle: "Why 6 degrees of freedom aren't enough, and why a magnetometer doesn't fix it"
description: "The LSM6DS3, Madgwick, EKF, and why the BNO085 works on the first test."
date: 2026-04-27 00:00:00
background_color: '#16213e'
---

The XIAO nRF52840 Sense has an LSM6DS3TR-C 6-DOF IMU soldered directly on. No extra board. Saves ₹800–1000. Removes four jumper wires. One less thing to vibrate loose. It seemed like the obvious choice.

It wasn't.

---

## Why yaw is unobservable on 6-DOF

A 6-DOF IMU has an accelerometer and a gyroscope. No magnetometer.

The accelerometer measures the gravity vector rotated into the sensor frame. When you rotate around the vertical axis — yaw, the axis pointing toward the ceiling — the gravity vector points straight down. Rotating around the vertical axis does not change the horizontal projection of a vector pointing vertically. The accelerometer output is **identical for all yaw angles**.

This isn't a calibration problem or a software problem. It's structural.

Formally: the predicted accelerometer measurement `h(q)` has a Jacobian `H = ∂h/∂q` whose last row contains zeros in the yaw-sensitive quaternion columns. Kalman gain `K = P·Hᵀ·(H·P·Hᵀ + R)⁻¹`. Zero `H` → zero `K` → zero correction to yaw. The update step cannot touch yaw regardless of what the accelerometer sees.

Only the gyroscope integration updates yaw. The LSM6DS3 datasheet specifies a zero-rate offset of ±10°/s. After 10 seconds stationary: ±100° of accumulated error. With a 15° gesture threshold, a perfectly still wrist triggers a false gesture every ~1.5 seconds.

Roll and pitch work fine. When you pronate your wrist, gravity shifts in the X/Y body axes — the accelerometer sees this clearly. Both axes have real correction from the accelerometer. Drift is suppressed. The yaw problem is specific to yaw.

---

## What it looked like in the serial log

Real data, wrist sitting still on a desk:

```
[Gesture] yaw_left
[Gesture] yaw_left   ← 2.1s gap
[Gesture] yaw_left   ← 2.1s
[Gesture] yaw_left   ← 2.1s
[Gesture] yaw_left   ← 2.1s
```

The 2-second periodicity is not a coincidence. It exactly matches the `lastGestureMs > 2000` guard that force-rebases the reference quaternion. Rebase re-arms yaw. Gyro drift immediately crosses the 15° threshold again. Rebase re-arms it again. The loop is deterministic.

This happened with BETA=0.4 Madgwick. Also with an EKF at `Q=1e-5`, `R=1e-2`. The filter doesn't matter — they are all mathematically equivalent in their inability to correct yaw from accelerometer data alone. The analysis is in the project's DESIGN.md: the Jacobian zero is not a tuning issue, it's a fundamental property of the observable set.

---

## "Just add a magnetometer"

A magnetometer measures the Earth's magnetic field vector and gives absolute compass heading. Add one, get 9-DOF, fix yaw. Obvious.

The problem is the indoor magnetic environment.

Oculus used a magnetometer in the DK1 headset for yaw correction. They removed it in DK2 because indoor interference — laptops, power cables, metal desk frames, wiring in walls — corrupted the heading estimate badly enough that it was worse than running without correction. [SlimeVR](https://docs.slimevr.dev/assets/magnetometer-calibration) ships the BNO085 with the magnetometer **disabled by default** and documents exactly why: home environments produce field variations that make absolute heading unreliable.

More fundamentally: for a discrete gesture device, absolute heading is the wrong thing to measure. I don't need to know which way is north. I need to know whether the wrist rotated 15° from wherever it was a moment ago. **Rebase** — detect stillness, reset the reference — is the right solution. The magnetometer is the wrong tool for this problem.

---

## The BNO085

The [BNO085](https://www.ceva-ip.com/wp-content/uploads/2019/10/BNO080_085-Datasheet.pdf) (CEVA/Bosch) is a 9-DOF sensor with a dedicated ARM Cortex-M0+ running SH-2 firmware. It runs 9-DOF Madgwick at 400Hz internally. Temperature-compensated gyro bias estimation runs continuously. The magnetometer correction happens on the sensor — the host MCU receives a pre-fused quaternion via I2C. No filter code in the Arduino sketch. No drift accumulation to manage on the host side.

All three axes are stable from cold start.

It worked on the first test.

The SH-2 reference manual describes the internal fusion pipeline in detail. The short version: bias tracking, calibration, and sensor fusion run on dedicated silicon at rates and precision that a Cortex-M4 sketch sharing cycles with BLE radio overhead cannot match.

---

## The git evidence

Two commits tell the story cleanly:

- `7083673` — *"removes the dependency on BNO085 9DOF and using nRF52840 Sense, costing doesn't make sense"*
- `95fca10` — *"swap active firmware to BNO085, archive LSM6DS3 as nrf52840 bkp"*

The LSM6DS3 firmware is now `wristturn_nrf52840.ino.bkp`. The cost argument in the first commit was real — saving ₹800 sounds reasonable until you spend three weeks fighting a filter that cannot work. The second commit came after one afternoon of testing with the BNO085.

| Sensor | DOF | Yaw observable | Typical yaw drift | Outcome |
|--------|-----|----------------|-------------------|---------|
| LSM6DS3 | 6 (accel + gyro) | No | ±100° / 10s | Roll/pitch only |
| LSM9DS1 | 9 (+ mag) | Yes (indoors: variable) | < 5° / min | Unreliable indoors |
| BNO085 | 9 (fused, + mag) | Yes | < 2° / min compensated | All axes, reliable |

The custom PCB path uses the BNO085 bare chip — same sensor, no breakout board markup. The cost is baked in because there is no alternative that actually works for all three axes.

The ₹800 saving would have cost the entire gesture recognition stack.
