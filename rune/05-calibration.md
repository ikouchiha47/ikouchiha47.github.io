---
active: true
layout: group_page
group: rune
group_title: "RUNE"
group_url: "/rune/"
title: "RUNE Part 5: Calibration, From 125 Seconds to 3"
subtitle: "MASR throttling, stable windows, and a timer that fires regardless of IMU events"
description: "Why the original calibration took 2 minutes and how it was fixed to take 3 seconds."
date: 2026-04-30 00:00:00
background_color: '#0a1628'
---

![Early prototype during calibration testing](/assets/rune/img/IMG_20260330_152939403.jpg)

Calibration answers the question from [Part 4](/rune/04-gestures): reference anchoring. The device needs to know where "neutral" is for this user in this position before it can classify any motion as a gesture. That baseline is captured once after pairing — user holds arm in wearing position, firmware collects rotation vector samples, computes average, stores as the reference.

The original implementation required the user to hold still for up to two minutes. This is not a product.

---

## The cause: MASR throttling

The BNO085 has a feature called Motion Adaptive Sample Rate. When it detects that the device is stationary, it automatically throttles the ROTATION_VECTOR report rate to save power.

Throttled rate: approximately **0.12 Hz**.

The original calibration algorithm waited for 25 samples to fill the buffer. At 0.12 Hz, that's 208 seconds worst case. In practice, 60–120 seconds. The user has to stand there, arm raised in wearing position, not moving, while the sensor slowly decides it might be worth sending another quaternion.

The log tags confirmed it — `[RVRate]` showed 0.12 Hz during the calibration window, `[CalBuf]` showed samples trickling in one every 8 seconds.

---

## The fix: wall-clock deadline, two buffers

The rewrite (`docs/CALIBRATION_REWRITE.md`, implemented in `88aa7d7`) makes one structural change: **stop waiting for a sample count, use a fixed time deadline instead.**

```
3-second collection window, started when arm event fires.
Two buffers:
  calBuffer       — ALL rotation vector samples during window
  stableCalBuffer — samples received while BNO085 stability = STABLE (stab=3)

Finalization priority (at 3-second expiry):
  1. stableCalBuffer.count > 0  →  baseline = mean(stableCalBuffer)
  2. calBuffer.count > 0        →  baseline = mean(calBuffer)
  3. both empty                 →  fail, app retries
```

The key detail is where the timer check lives:

```cpp
// In loop(), before waitForEvent() — fires on every iteration
if (calInProgress && !baselineCaptured) {
  if (millis() - calStartMs >= CAL_WINDOW_MS) {
    finalizeCalibration();
  }
}
```

Not in the IMU event handler. Not gated on receiving a sample. In `loop()`, unconditionally, on every pass. If the IMU is throttled to 0.12 Hz and sends zero samples during the 3-second window, the timer still fires. The fallback path handles it.

---

## The stability window

The BNO085 reports a stability class with each rotation vector sample:

| stab value | Meaning |
|-----------|---------|
| 1 | On table |
| 2 | Stationary |
| 3 | **Stable** — sensor confident in orientation |
| 4+ | In motion |

`stab=3` is what you want for calibration — the sensor is confident. Samples collected during stab=3 go into `stableCalBuffer`. When stab rises above 3 (motion detected), the window pauses but `stableCalBuffer` is not cleared; prior stable samples are retained across brief motion spikes.

```cpp
// In handleStabilityClassifier()
if (calInProgress && !baselineCaptured) {
  if (stab == STABILITY_STABLE) {
    inStableWindow = true;
  } else if (stab >= 4) {
    inStableWindow = false;
    // stableCalBuffer NOT cleared — keep prior stable samples
  }
}
```

If the user's arm is reasonably still during the 3-second window, `stableCalBuffer` fills with a handful of high-confidence samples. If the arm was moving the whole time, the fallback to `calBuffer` (all samples) gives a noisier but usable baseline.

---

## State resets

Calibration state resets on three events:

1. **Disarm** — user explicitly disarms via app
2. **BLE disconnect** — connection dropped
3. **App writes `-999,-999,-999` to the baseline characteristic** — the protocol sentinel for "start over"

All three clear both buffers and the `inStableWindow` flag. The `-999` sentinel is a deliberate API contract: the app can trigger a fresh calibration without bouncing the BLE connection.

The EARS requirements document (`CALIBRATION_REWRITE.md`) has 18 requirements covering every state transition. The full checklist is there if you want to understand why each reset path needs its own handling.

---

## Result

Happy path timing: arm → user raises arm (1s of motion) → stab=3 fires → stableCalBuffer starts collecting → 3-second expiry → baseline set. Total: **3–4 seconds**.

Log confirmation:
```
[Arm] armed
[Reports] rotation vector enabled
[RVRate] sample=10 elapsed=200ms (~50Hz)
[CalBuf] count=1/25 ...
[Cal] stable window used: 8 samples
[Cal] baseline: r=12.3 p=-8.1 y=44.7
```

The app does not forward gestures to the host while `calibrationComplete == false`. That gate lives in TypeScript, not firmware — separation of concerns. Firmware captures baseline. App enforces the gate. Each side owns its piece.

---

## What's still open

Sample rate at 50Hz fills 25 samples in ~500ms. The 3-second window is generous — the actual fill time is fast when the IMU isn't throttled. The open question is whether the MASR throttle kicks in during the calibration window for certain users who hold very still. The log tags exist to detect this. The fallback path handles it. But characterizing the failure rate across different conditions is ongoing.

The multimeter and the serial monitor are the tools. The protocol gives you the visibility.
