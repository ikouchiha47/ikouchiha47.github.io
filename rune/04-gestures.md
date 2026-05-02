---
active: true
layout: group_page
group: rune
group_title: "RUNE"
group_url: "/rune/"
title: "RUNE Part 4: Eight Problems Called Gesture Detection"
subtitle: "From Euler angle deltas to a gyro integration FSM — and why the naive version fails seven ways"
description: "Every naive gesture algorithm has the same failure modes. Here's the taxonomy and the rewrite."
date: 2026-04-29 00:00:00
background_color: '#1a0a2e'
---

<video src="/assets/rune/video/inshot_420422.webm" controls width="100%" style="max-width:640px; display:block; margin-bottom:1.5rem;"></video>

The first version of gesture detection was twelve lines: store baseline Euler angles at calibration time, compute delta per sample, emit a gesture if `|delta| > threshold`. Simple. Works for a demo. Fails in practice in at least seven distinct ways, each with its own cause and its own fix.

The project has a document — `docs/problems.md` — that lists them out. It was written after the twelfth hack to the gesture code stopped working. This is what's in it.

---

## The taxonomy

**1. Engagement — when is control active?**
If pitch continuously maps to brightness, every time you move your arm to scratch your head, brightness changes. All continuous control needs explicit intent gating. Without it, you're not building a remote — you're building an annoyance.

**2. Reference anchoring — relative to what?**
"Arm lifted = lights on" — lifted relative to which position? Every user sits differently. Holds their arm differently. The baseline must be captured at engagement time, not factory-set. Otherwise the same arm position means different things per user, per session, per chair.

**3. Axis isolation — roll bleeds into pitch**
When you pronate your wrist (roll), your elbow and shoulder compensate slightly — pitch and yaw drift. For simultaneous independent controls (roll = volume, pitch = brightness), you need to know how much of the observed pitch change is incidental bleed from roll vs intentional. Without this, turning the volume accidentally moves the brightness slider.

**4. Output mapping — angle to value curve**
Volume: logarithmic (human hearing is logarithmic; small changes at low volume matter more). Brightness: linear or slight gamma. "Lights on at elevation X": threshold + hysteresis, not linear mapping. These are different functions. The algorithm needs to know which applies.

**5. Tremor rejection without latency**
Raw pitch/yaw has 3–8Hz hand tremor. Too much filtering adds latency. Cursor needs < 50ms. Brightness slider can tolerate 100ms. "Lights on" can tolerate 200ms. These are different products with different tolerances.

**6. Threshold vs continuous**
"Arm lifted = lights on" is categorically different from "pitch = brightness value." The first is an event: one-shot trigger when crossing a level, needs debounce, may latch. The second is a value: tracks position in real time, needs tremor rejection and smooth mapping. The algorithm must know which contract applies before it can emit anything correct.

**7. Fatigue**
Holding your arm at elevation for sustained output (lights stay on while arm is raised) causes fatigue in 30–60 seconds. Latching semantics — crossing fires a toggle, arm can return to rest — are almost always better than holding semantics.

**8. Snap/reposition detection**
When the user re-centers their arm without intending a gesture. The only problem the naive algorithm was even trying to solve.

The naive algorithm addressed #8 partially. The rest weren't even defined yet.

---

## The hacks accumulate

The intermediate firmware accrued: `CROSS_INHIBIT_MS`, `FORCE_REARM_MS`, `lastGestureMs` debounce, stability-classifier rebase, `rollArmed / pitchArmed / yawArmed` booleans, `STABILITY_REBASE_HOLDOFF_MS`. Each hack fixed one symptom and added one new assumption about ordering. Adding a new gesture type required touching five files. The code was untestable without a physical device in your hand.

This is the point where you stop patching and rewrite.

---

## The rewrite — physics first

A gyroscope measures **angular velocity** (rad/s), not angle. The old firmware converted gyro → quaternion → Euler angles and compared positions to a stored baseline. That introduced drift: if the baseline was set at the wrong moment, every comparison was wrong. The new approach never stores position.

**Jerk gate — blocking drift**

```cpp
float jerk = (gyroVal - _prevGyro) / dt;  // rad/s²
if (fabsf(jerk) > 8.0f) {
  accumulating = true;
}
```

Gyro drift is a slow, low-frequency error. It never produces an angular acceleration spike above 8 rad/s². A deliberate wrist flick does. This gate blocks drift from ever entering the integration path.

**Windowed integral — measuring the gesture**

```cpp
sum += gyroVal * dt;  // rad/s × s = rad
// Threshold: 0.25 rad ≈ 14°
```

Riemann sum over a 32-sample ring buffer at ~50Hz covers ~640ms — more than enough for any wrist motion. The sign of the integral gives direction for free. No separate direction logic needed.

**4-state FSM per axis**

```
IDLE ──(jerk ≥ 8 rad/s²)──► ONSET ──(integral ≥ 0.25 rad within 300ms)──► PEAK
  ▲                             │                                               │
  │                       timeout → IDLE                              (gyro < 0.15)
  │                                                                              │
  └──────────────────────────────────────────────────────────────────────── DECAY
                                                                               │
                                                                  (gyro < 0.03 rad/s)
                                                                               │
                                                                      FIRE + → IDLE
```

Each state rejects a specific class of false positive:

| State | Waiting for | Rejects |
|-------|-------------|---------|
| IDLE | Jerk spike | Slow drift that never spikes |
| ONSET | Integral to cross threshold | Weak twitches that don't commit, within 300ms |
| PEAK | Gyro to start dropping | Held positions — user freezes at an angle |
| DECAY | Gyro to fully settle (ZUPT) | Mid-flick re-triggers |

The gesture fires on DECAY→IDLE, not at PEAK. The motion is confirmed complete. The axis is back in IDLE ~100ms later, immediately ready for the next gesture. This is called a Zero-Velocity Update (ZUPT).

**Dominant-axis ratio test — replacing CROSS_INHIBIT_MS**

```cpp
float ratio = fabsf(dominant) / (fabsf(other1) + fabsf(other2) + 0.001f);
if (ratio >= 1.5f) { /* emit */ } else { /* ambiguous, drop */ }
```

A clean deliberate flick concentrates most energy on one axis — ratio typically 3–8. Accidental compound motion splits it — ratio 1.0–1.4. 1.5 sits cleanly in the gap. No timer needed. `CROSS_INHIBIT_MS` is deleted.

---

## The gesture vocabulary

From the BLE protocol spec — what the firmware emits and the app maps to actions:

| Gesture | Axis | Motion |
|---------|------|--------|
| `turn_right` | Roll | Wrist pronation |
| `turn_left` | Roll | Wrist supination |
| `pitch_up` | Pitch | Wrist flexion |
| `pitch_down` | Pitch | Wrist extension |
| `yaw_right` | Yaw | Wrist abduction |
| `yaw_left` | Yaw | Wrist adduction |
| `tap` | — | BNO085 hardware tap detector |
| `shake` | — | Linear acceleration threshold |

---

## The InteractionEngine

`GestureFilter`, `ComboEngine`, and `HoldDetector` were three classes doing overlapping jobs, wired ad-hoc in `useBLE.ts` with mode-specific branching and ordering dependencies. Adding a new behavior required touching all three plus the wiring.

Collapsed into one engine with three rule types, evaluated top-down — first match wins, like Express route ordering:

**Terminal** — single token → action, with per-token refractory and snap-back suppression:
```typescript
{ type: "terminal", token: "turn_right", action: "dpad_right", refractoryMs: 200 }
```

**Sequence** — N tokens in order within a time window → action:
```typescript
{ type: "sequence", tokens: ["turn_right", "turn_right"], windowMs: 300, action: "ff" }
```

**Repeat** — entry sequence → fire at interval → cancel on token:
```typescript
{
  type: "repeat",
  tokens: ["yaw_left", "yaw_left", "yaw_left"],
  windowMs: 600, action: "scroll_left",
  intervalMs: 200, cancelOn: ["yaw_right"]
}
```

Inspired by Unreal Engine's Enhanced Input System — rules as data, one interpreter. Adding a new behavior means adding a rule object, not a new class.

Hold = triple same gesture. No time-based ambiguity about whether the user is still or just paused. Consistent with how every other intentional action in the vocabulary works.

---

Calibration — the other piece of reference anchoring — is covered separately in [Part 5](/rune/05-calibration). It went from 125 seconds to 3.
