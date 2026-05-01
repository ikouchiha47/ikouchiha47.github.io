---
active: true
layout: post
title: "RUNE Part 6: The App"
subtitle: "Claude built most of it. Humans tested the joints."
description: "Architecture of the React Native app — BLE bridge, TypeScript core, the androidtvremote2 protocol reverse-engineered into Kotlin, and how a research detour led to DTW."
date: 2026-05-01 00:00:00
background_color: '#0f1923'
---

![App connected and active](/assets/rune/img/IMG_20260421_120823252-2.jpg)

The app is the bridge. Firmware classifies gestures. The app decides what to do about them — D-pad the TV, toggle a bulb, send a keypress to a desktop. The execution logic lives in TypeScript and Kotlin, not C++.

Most of the app code was written by Claude. The parts that required a physical device to verify — Claude got wrong.

---

## Architecture

Three layers. Dependencies point inward.

```
UI (React Native screens)
  → Core (pure TypeScript, no framework imports, testable with Bun)
  → Infrastructure (BLE service, native bridge)
```

Core is testable without a device or simulator — just Bun and a test file. Infrastructure is thin: it calls core. Screens display state and capture input. No business logic in the screens. This boundary is defined in `wristturn-app/CLAUDE.md` and enforced by code review.

What Claude built: the BLE state machine (`useBLE.ts`, `BLEServiceNative.ts`), the InteractionEngine (covered in [Part 4](/2026/04/29/rune-part4-gestures.html)), `ComboValidator`, `MotionClassifier`, `BaselineTracker`, the calibration flow, all screen layouts. The `StatePacket` discriminated union parser that turns raw BLE bytes into typed events:

```typescript
type StatePacket =
  | { type: "stab";    value: number }
  | { type: "grav";    pose: "flat" | "hanging" | "raised" }
  | { type: "batt";    percent: number }
  | { type: "gesture"; name: string; roll: number; pitch: number; yaw: number }
```

The gravity pose packet (`PKT_GRAV = 0x07`) was added late, replacing a pitch-below-baseline arm detection hack that worked and was wrong. The firmware now sends the actual arm pose derived from gravity vector projection. This is typical: the clean version comes after you've shipped the hack and watched it fail at the edges.

---

## Android TV — not what you'd expect

![Device on desk](/assets/rune/img/IMG_20260501_021252907.jpg)

The Android TV integration (`modules/androidtv/`) does not use `InputManager.injectInputEvent()`. It implements the **androidtvremote2 protocol** — Google's actual remote control protocol used by the official Android TV Remote app, running over two TLS-over-TCP connections on ports 6467 (pairing) and 6466 (remote).

This was found by asking: who has solved the exact problem of controlling an Android TV from a non-TV Android device? The answer was the [`androidtvremote2`](https://github.com/tronikos/androidtvremote2) Python library — a clean open-source implementation of the protocol, reverse-engineered from traffic captures. The Kotlin code in `AndroidTVRemoteClient.kt` follows the same protocol. There's even a comment in the pairing code crediting the source:

```kotlin
// Protocol from androidtvremote2:
// sha256(bytes.fromhex(clientMod) + bytes.fromhex(0+clientExp) + ...)
```

**How the protocol works:**

Pairing (port 6467) uses Google's Polo protocol — a TLS handshake where both sides present self-signed RSA-2048 certificates, then exchange a shared secret derived from those certs and a 6-digit hex PIN shown on the TV screen:

```kotlin
// The secret is SHA-256 over both RSA public key moduli + exponents + the PIN
val digest = MessageDigest.getInstance("SHA-256")
digest.update(hexToBytes(clientMod))
digest.update(hexToBytes(clientExp))
digest.update(hexToBytes(serverMod))
digest.update(hexToBytes(serverExp))
digest.update(hexToBytes(pin.substring(2)))
val hash = digest.digest()
// hash[0] must match pin[0:2] — this is the checksum that makes the PIN verifiable
```

Once paired, the client identity (private key + cert) is persisted to disk. Subsequent connections skip pairing — the TV recognizes the cert.

Remote control (port 6466) sends protobuf-encoded key events. There's no protobuf dependency — the encoding is implemented inline with ~50 lines of varint and length-delimited field helpers:

```kotlin
fun keyEventMessage(keyCode: Int, direction: Int): ByteArray {
    // RemoteMessage field 10 = remote_key_inject { key_code(1), direction(2) }
    // direction: SHORT=3, START_LONG=1, END_LONG=2
    val keyEvent = int32Field(1, keyCode) + int32Field(2, direction)
    val outer    = lengthDelimited(10, keyEvent)
    return frameMessage(outer)
}
```

The writer thread drains a `LinkedBlockingQueue` and measures enqueue-to-send latency. The reader thread handles the TV's ping frames (field 8 → field 9 pong) and configure messages. App links (`remote_app_link_launch_request`, field 90) are also supported for deep-launching apps directly.

What required physical testing to get right: the configure handshake the TV expects on first connection, the specific feature bitmask (`PING=1 | KEY=2 | POWER=32 | VOLUME=64 | APP_LINK=512 = 611`), BouncyCastle cert generation via Android's bundled internal classes (which requires reflection because the APIs aren't public), and the soTimeout dance — set during handshake, cleared after so the reader thread doesn't time out on quiet connections.

None of this was in any tutorial. It required reading the Python source, reading the Kotlin TLS docs, and running it against a physical TV with logcat open.

---

## Finding the protocol: how research applies here

The approach used to find `androidtvremote2` — "who has solved the same problem or a close variant, and what did they learn?" — is a repeatable pattern that came up again for gesture symbol recognition.

The RUNE-III goal is drawing symbols in the air (Z, L, circle) and having the device recognize them. The naive approach is: record one reference gesture, compare future gestures against it. The problem: gestures drawn at different speeds produce different time series. Simple Euclidean distance says they're different. A human says they're the same.

Searching for "time series classification with one training example" turns up the same cluster of results across audio, speech, and gesture literature:

**DTW (Dynamic Time Warping)** — warps the time axis to find the optimal alignment between two sequences, then measures distance on the aligned version. A gesture drawn 20% slower gets stretched to match the reference; the shape is preserved.

```
Reference: [A, B, B, C, D, D, E]
Query:     [A, B, C, C, D, E, E]

DTW finds the diagonal path through the cost matrix that minimizes total distance.
Cost matrix cell = Euclidean distance between ω(t) samples (3D vectors).
```

The **Sakoe-Chiba band** constrains the warping path to stay within W samples of the diagonal — prevents degenerate alignments where the entire reference maps to a single query point, and reduces complexity from O(N²) to O(N·W).

**The $1 Unistroke Recognizer** ([depts.washington.edu/acelab](http://depts.washington.edu/acelab/proj/dollar/index.html)) — resamples the gesture path to N equally-spaced points, rotates to canonical angle, scales to unit square, compares against templates. Originally for touch strokes, but directly applicable if you treat the gravity vector tip as the "stroke" on the sphere surface. ~100 lines of code. Works with one template per class.

**Feature vectors** (Benbasat 2002) — extract peak gyro rate, total integral, duration, dominant axis from each gesture and compare as a fixed-length vector. Much simpler than DTW. Works well for gestures with distinct profiles (Z vs L vs circle have different peak rates and dominant axes). Fails for gestures that only differ in subtle timing.

**HMMs** were the 2000s standard when you have 10–50 training examples per class. Not 1-shot. Overkill for the current problem.

The research is written up in full in [Research on RUNE-III](/2026/05/02/rune-iii-gesture-symbol-research.html). The short version: start with feature vectors (simplest, fastest, interpretable), fall back to DTW with Sakoe-Chiba when features alone can't discriminate. Both are implementable in TypeScript without a ML framework. No training data required beyond one reference recording per gesture.

`SymbolCapture.ts` in `src/gestures/` is the capture side — it records the gravity vector path during an arm gesture window. The matching side is RUNE-III.

---

## Testing

The gesture logic has unit tests running under Bun — hand-rolled harness, no Jest, no Mocha, exits non-zero on failure. The `InteractionEngine` tests cover Terminal, Sequence, and Repeat rules with synthetic gesture streams.

The Kotlin bridge has no unit tests. It's tested physically against a real Android TV. The failure modes are hardware-dependent in ways a mock cannot capture — TV firmware versions, the exact configure handshake timing, soTimeout behavior on different Android versions. The tests that exist are integration tests performed by hand.

This is an honest gap. Unit-testable Kotlin would require either a real device in CI or a detailed mock of the TLS protocol stack. Neither is worth it at this stage.

---

## What's next

RUNE-I is the phone-paired version. BLE range and battery are the main constraints; both are work in progress. RUNE-III adds symbol recognition — the research is done, the implementation is next. RUNE-V adds EMG, which finally answers the engagement problem from [Part 4](/2026/04/29/rune-part4-gestures.html): knowing when the user means to gesture versus just moving their arm.

The hardware is a plastic box on velcro. The TV responds to wrist flicks. The series ends here for now.
