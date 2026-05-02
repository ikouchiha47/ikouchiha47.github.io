---
layout: group_page
group: rune
group_title: "RUNE"
group_url: "/rune/"
title: "Part 7: Power on 300mAh"
subtitle: "Adaptive sample rates, staged sleep, and nine hours watching INT blink at nothing"
background_color: '#0a1a0a'
---

300mAh at 3.7V is 1.11 Wh. The device survives one full night. The target is two days. Getting from here to there is not firmware magic — it's accounting: measure every state's draw, then cut what's unnecessary.

Two independent systems manage power while the device is active. They share a single input signal: the BNO085 stability classifier.

---

## 1. Adaptive RV Rate

### The knob you actually have

The BNO085 fusion engine runs at ~400Hz internally regardless of what you tell it. What you control is how often the SH-2 hub *pushes data over I2C* — the report rate. Fewer pushes = fewer `waitForEvent()` returns in `loop()` = less MCU active time and less I2C bus traffic.

The BNO085 chip power is dominated by its fusion engine, not the output rate. The savings land on the nRF52840 side.

| Rate | Interval | When |
|------|----------|------|
| 50Hz | 20ms | Default on arm/wake; always during MOTION |
| 10Hz | 100ms | Knob/symbol mode only, after 5s stationary |

### The state machine

Driven by `handleStabilityClassifier()` on every stab change:

```
stab=4 (MOTION)
  → snap to 50Hz immediately
  → reset idle countdown

stab=3 (STABLE — arm raised, user resting between gestures)
  → reset idle countdown
  → hold current rate

stab≤2 (STATIONARY / TABLE — device truly at rest)
  → if MODE_GESTURE: reset timer, hold 50Hz forever
  → if MODE_KNOB / MODE_SYMBOL: start 5s countdown
      → after 5s: drop to 10Hz

Any arm/wake event
  → enableReports() always resets to 50Hz
```

### Why gesture mode never drops

In gesture mode the arm rests at `stab=3` (STABLE) between flicks — user is holding their wrist up, waiting to gesture. Dropping to 10Hz at stab=3 would cause a missed-onset problem: the BNO085 report rate takes one full interval to ramp back up, so the first 100ms of a gesture could be missed entirely.

Knob and symbol modes involve deliberate sustained motion, so they tolerate a short ramp from 10Hz back to 50Hz when motion resumes.

---

## 2. PowerManager — The Sleep Stack

### Entry conditions

`enterSleep()` fires from `loop()` when:

```cpp
(millis() - lastMotionMs) > SLEEP_TIMEOUT_MS  // 5 min production, 30s debug
```

`lastMotionMs` updates on stab=4 (MOTION), shake, tap, and `exitSleep()`. Path to sleep: no MOTION events for 5 minutes.

### How the two systems share a signal

The adaptive rate system and sleep entry use the same root signal:

```
User puts device down
  → stab drops: 4 → 3 → 2 → 1
  → stab=4 events stop → lastMotionMs freezes
  → sleep countdown begins (5 min)
  → adaptive rate: stab≤2 for 5s → drops to 10Hz (non-gesture modes)
  → at 5 min: enterSleep()
```

The rate drops at 5s of stillness. Sleep fires at 5 min. Both reset on the same MOTION signal. The timers are independent.

### The sleep tiers

```
enterSleep()
  → disable high-freq reports (RV, linear accel, gyro, stability)
  → drain FIFO
  → StagedPolicy.arm()

Stage 0: ShakeSleepPolicy  (light sleep, runs 10 min)
─────────────────────────────────────────────────────
  arm():
    configureSensor(SHAKE_DETECTOR, 200ms interval, wakeupEnabled=false)
    modeSleep()
    start 30s software timer

  tick() every ~10ms:
    if timer < 30s → return false (stay asleep)
    on 30s expiry:
      modeOn() + drainFifo(200ms)   ← BNO085 wakes briefly, samples shake detector
      if 0x19 (shake) seen → return true → full wake
      else → modeSleep() + reset 30s timer

Stage 1: SigMotionSleepPolicy  (deep sleep, indefinite)
───────────────────────────────────────────────────────
  arm():
    configureSensor(SIG_MOTION, 2s interval, wakeupEnabled=true)
    modeSleep()                      ← always-on domain handles wake

  tick() every ~10ms:
    if INT pin HIGH → return false
    if INT pin LOW:
      modeOn() + drainFifo(300ms)
      if 0x12 (significant motion) seen → return true → full wake
```

### Full timeline

```
T+0s      stab=4 stops → lastMotionMs freezes
T+5s      RV rate drops to 10Hz (knob/symbol modes)
T+5min    enterSleep() → Stage 0 (ShakeSleepPolicy)
          BNO085: modeSleep, shake configured at 200ms, no INT dependency
T+5m30s   tick fires: modeOn 200ms, check shake, back to sleep
T+6m00s   tick fires: modeOn 200ms, check shake, back to sleep
...       (every 30s for 10 min)
T+15min   Stage 0 ends → Stage 1 (SigMotionSleepPolicy)
          BNO085: SIG_MOTION armed wakeupEnabled=true, modeSleep
          nRF52840: WFE, wakes only on SIG_MOTION INT or FreeRTOS tick
```

The device wakes on: user shaking during a Stage 0 sample window (latency: 0–30s), or Significant Motion firing at Stage 1 (requires walking-scale movement).

---

## 3. Getting Here — Four Things That Didn't Work

### Approach 1: INT pin with wakeupEnabled=true on shake detector

Configure `SH2_SHAKE_DETECTOR` with `wakeupEnabled=true`. In `loop()`, poll INT pin — INT LOW = shake = wake.

What happened: INT stayed LOW continuously from the moment `modeSleep()` was called. The SHTP transport sends an ACK pulse (INT LOW) every time a sensor command is processed. With shake configured at 200ms intervals and wakeupEnabled, the BNO085 drove INT LOW again almost immediately after each drain. The sleep loop spent 9 hours in a continuous "INT pin LOW — draining to clear INT" spin:

```
[04:21:42.827] [Sleep] INT pin LOW during MIN_SLEEP_MS window (elapsed=4335ms) — draining to clear INT
[04:21:43.389] E [DEADLOCK WARNING] ...
... (repeating every 63ms for ~9 hours)
[13:11:04.152] [Sleep] INT pin LOW while sleeping (elapsed=417ms) — waking SH-2 hub
```

Root cause: `SH2_SHAKE_DETECTOR` with `wakeupEnabled=true` is a periodic sensor — it sends a report on schedule whether or not shaking occurred. It is not an edge-triggered interrupt. INT never stays HIGH.

---

### Approach 2: Longer guard window to absorb ACKs

After `modeSleep()`, enter a 10s guard window where INT LOW → drain without waking. After the window, treat the next INT LOW as a real shake wake.

What happened: The drain log showed 54 consecutive 0x19 shake events at ~196ms spacing in the first 10 seconds:

```
[00:05:03.611] [Sleep] drain[5] event=0x19 elapsed=361ms
[00:05:04.784] [Sleep] drain[11] event=0x19 elapsed=1534ms
...
[00:05:13.191] [Sleep] drain[53] event=0x19 elapsed=9746ms
[00:05:13.247] [Sleep] drain window ended (elapsed=10000ms drainCycles=54) — re-sleeping hub
[00:05:13.253] [Sleep] INT pin LOW after MIN_SLEEP_MS (elapsed=10006ms) — waking
```

Device woke immediately after the guard window because the next shake report arrived 6ms after it closed. The guard window delayed the false wake. It didn't prevent it.

---

### Approach 3: 2s interval + guard window

Change shake interval to 2s to reduce ACK frequency. Keep a shorter guard window (~10s, ~6 drain cycles). After the guard window, treat the first INT LOW as a real wake.

What happened: consistent pattern across all cycles — device woke at exactly ~11.85s (6 guard drains × ~1.95s) regardless of user activity:

```
[00:05:05.353] [Sleep] BNO085 SH-2 sleep — INT=0 after modeSleep
[00:05:05.443] [Sleep] INT LOW in guard window (elapsed=125ms) — drain ACK, no re-sleep
...
[00:05:15.104] [Sleep] INT pin LOW while sleeping (elapsed=11854ms) — waking SH-2 hub
[00:05:15.159] [Sleep] wake event=0x19 drained=0
```

The "wake event=0x19 drained=0" is the tell: the drain reported 0 events actually decoded from FIFO, yet still triggered exit. The 7th INT pulse was the next periodic shake report. The guard window approach cannot distinguish a real shake from a scheduled report.

---

### What the datasheet actually says

Reading the BNO085 SH-2 Application Note:

- **`SH2_SIGNIFICANT_MOTION`** (0x12): Requires a 5-step walking pattern with acceleration threshold crossing. Designed for "user picked up and started walking" detection. Not "device moved" detection.

- **`SH2_SHAKE_DETECTOR`** (0x19): Documented as requiring "significant acceleration changes in rapid succession." In practice, sends periodic reports at its configured interval — the report payload indicates shake direction, but the report fires on schedule whether or not shaking occurred.

Neither sensor was wired correctly for the use case. The INT pin cannot distinguish a real event from a periodic heartbeat for either sensor.

---

### Approach 4 (the fix): Software timer

Inspired by SparkFun BNO08x Example20-Sleep. Instead of waiting for INT to signal a shake event, use a software timer:

1. Configure shake detector with `wakeupEnabled=false` — no INT-pin dependency
2. `modeSleep()` — hub sleeps
3. Every 30s: software timer fires → `modeOn()` + drain FIFO for 200ms → check for 0x19 → if found, full wake; else `modeSleep()` again

This completely avoids the periodic-report-as-interrupt problem. Wake latency: 0–30s. The user shakes and holds for a few seconds; eventually a sample window catches it.

This is `ShakeSleepPolicy` in `PowerManager.h`.

---

## 4. Validated from Hardware Logs

### Before the fix — the DEADLOCK bug (logs.39)

The firmware had a missing `return` after `delay(10)` in the sleep block. After `enterSleep()`, `loop()` fell through to the DEADLOCK check on every 10ms iteration because the sleep branch didn't return. The modeSleep() SHTP ACK held INT LOW, triggering 301 consecutive warnings over ~3 seconds:

```
[00:05:03.247] [Sleep] inactivity timeout — entering light sleep
[00:05:03.284] [Sleep] pre-sleep drain: 5 cycles, INT=1
[00:05:03.376] E [DEADLOCK WARNING] CPU about to sleep but BNO085 INT is LOW!
[00:05:03.386] E [DEADLOCK WARNING] ...   ← repeats 301 times over 3 seconds
...
[00:10:00.579] [Sleep] PowerManager: wake event confirmed — exiting sleep
[00:10:00.641] [Sleep] reports restored — restarting BLE advertising
```

Key observation: despite 301 warnings, the device did not actually deadlock — FreeRTOS RTC tick continued waking the CPU from WFE every ~1ms. It eventually woke correctly from the shake cycle. The bug was noise + wasted cycles, not a crash.

**Fix**: added `return` after `delay(10)` in the sleeping block. The DEADLOCK check and `waitForEvent()` are now skipped entirely while sleeping.

### After the fix — clean stage transition (logs.39 era, new firmware)

```
[00:05:03.247] [Sleep] inactivity timeout — entering light sleep (armed=0 lastMotionAge=300004ms)
[00:05:03.284] [Sleep] pre-sleep drain: 5 cycles, INT=1

[00:09:33.452] [Sleep] stage=1 deep sleep (SigMotion, INT-based)
                        ↑ exactly 4.5 min → ShakeSleepPolicy → SigMotionSleepPolicy

[00:14:07.756] [Sleep] PowerManager: wake event confirmed — exiting sleep
[00:14:07.813] [Sleep] exitSleep drained 1 residual events, INT=1
[00:14:07.813] [Reports] enable start rawMode=0 armed=0 sleeping=0
[00:14:07.825] [Sleep] reports restored — restarting BLE advertising for reconnect
[00:14:08.259] [Stab] stab=4
                        ↑ SigMotion fired on motion, ~4.5 min in deep sleep
```

Observations:
- Pre-sleep drain exits clean (`INT=1`) — no ACK flooding.
- SigMotion (`SH2_SIGNIFICANT_MOTION`, 0x12) confirmed working on this hardware with `wakeupEnabled=true` from `modeSleep`.
- `exitSleep drained 1 residual events` — normal, that's the SigMotion event itself.
- `stab=4` immediately after wake — BNO085 reporting motion within 500ms of reports being re-enabled.
- No DEADLOCK warnings. `return` fix confirmed.

One bug found in this log: `lastStage` was initialised to `0`, same as `staged.currentStage`, so the stage=0 entry was never logged. **Fixed**: initialise `lastStage = 0xFF`.

---

## 5. Known Limitations (RUNE-I)

**Shake detection is sampling-based.** `SH2_SHAKE_DETECTOR` does not run in the BNO085 always-on domain during `modeSleep()`. The 30s cycle wakes the BNO085 for 200ms. The user must shake during that window. Typical wake latency: 0–30s. Shake and hold a few seconds.

**SigMotion requires walking, not just motion.** `SH2_SIGNIFICANT_MOTION` (0x12) uses a 5-step + acceleration pattern. It will not fire from picking up the device or flicking a wrist — only from walking-scale motion. Confirmed working from hardware log.

**nRF52840 WFE tick rate.** `waitForEvent()` uses `sd_app_evt_wait()` which wakes on any interrupt including the FreeRTOS RTC tick (~1ms). This is how `powerMgr.tick()` runs without a dedicated hardware timer. The `delay(10)` in the sleep path rate-limits tick checks to ~100/s.

---

## RUNE-II Direction

Push Significant Motion detection further onto the BNO085 always-on domain, or add a dedicated low-power motion interrupt source external to the BNO085 — an accelerometer with a hardware wake output. Goal: true deep sleep with sub-µA idle current on the motion sensing path, wake on genuine gross motion only. Stage 0 (ShakeSleepPolicy) disappears entirely; Stage 1 becomes the only sleep state.

The current device survives a full night. Two days requires measuring actual draw per state with a multimeter in series on the battery line — the serial log tells you what the firmware thinks is happening; the multimeter tells you what's actually happening.
