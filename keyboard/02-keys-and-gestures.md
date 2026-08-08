---
active: true
layout: group_page
group: keyboard
group_title: "CodeKeyboard Rebuild Notes"
group_url: "/keyboard/"
title: "CodeKeyboard Part 2: Keys, Dual Layout, Gestures"
subtitle: "Canvas keys, dual layout, hold-tap, TapMachine"
date: 2026-08-08 02:00:00
background_color: '#16213e'
---

## Canvas keyboard

`NativeKeyboardView` extends `View`. It does not inflate a grid of buttons from XML.

- `setKeys(keys, state, heightPx)` stores `List<PositionedKey>` and requests layout.
- `onDraw` fills `#111111` and draws each key as a round rect with label paint.
- Active modifiers and layers change fill color and a bottom accent bar.
- `onMeasure` uses the height from the layout computer when set.

Geometry comes from `SofleLayoutComputer` (implements `KeyboardLayoutComputer`): given width and layer name, it returns positioned keys. Snap distance for misses between keys uses `maxSafeSnapPx` from that computer when width is known.

## Dual layout rule

Two independent definitions must stay in sync by hand:

1. `src/keyboard/Layout.ts` - RN preview / settings
2. `android/.../SofleKeyData.kt` - IME (source of truth for typing)

The IME never reads Layout.ts at runtime. `CLAUDE.md` documents this. If you change one file only, preview and typing diverge. History includes a fix that added the emoji key to the native layout after it existed only on the RN side.

## Layers and hold annotations

Layer names in data: `base`, `lower`, `raise`, `adj`, `func`.

`SofleKeyData` comments describe V5 structure: top row, left 4x5, right 4x5.

Hold annotations on base (from the file, not from memory):

- Home row: `a` ctrl, `s` meta, `d` alt, `f` shift; `h` shift, `j` alt, `k` meta, `l` ctrl (timer path).
- Thumb spaces: hold lower / raise (timer path).
- Dedicated Shift, Ctrl, Alt, LWR, RSE, FUNC, ADJ: `holdAction` set; touch path treats them as activate-on-down.

## Hit testing

Constants in `NativeKeyboardView` companion:

```kotlin
private const val HIT_EXPAND_DP = 2.5f
```

`hitTest` first checks expanded bounds (`hitExpandPx = density * 2.5`). If none hit, nearest key within `snapThresholdPx * snapThresholdPx` wins. Drawing still uses the unexpanded rect.

## Gesture matrix

Authoritative design notes: `GESTURE_ARCHITECTURE.md`. Runtime: `NativeKeyboardView.onTouchEvent` + `KeyboardState` + `TapMachine`.

### Constants (verified)

| Name | Value | Where |
|------|------:|-------|
| TAPPING_TERM_MS | 150 | NativeKeyboardView |
| REPEAT_INITIAL_DELAY_MS | 400 | NativeKeyboardView |
| REPEAT_INTERVAL_MS | 50 | NativeKeyboardView |
| TapMachine doubleTapMs | 300 (default) | TapMachine.kt |

### Normal keys

DOWN: haptic, `onKeyTapped` immediately. If action is backspace/delete, also arm repeat timer (400ms then 50ms). MOVE off key cancels repeat. UP cancels repeat.

### Hold-tap (home row letters, thumb space)

DOWN when `holdAction != null` and action not in dedicated-mod set:

- start 150ms timer
- UP before fire: `onKeyTapped` (type letter/space)
- timer fires: `onKeyHeld` -> `KeyboardState.applyHold`
- UP after hold: `onKeyReleased` -> `releaseHold`
- MOVE off key: same as UP resolution (tap if not fired, else release)

### Dedicated modifiers

Set in view: `shift`, `ctrl`, `alt`, `lower`, `raise`, `func`, `adj`.

DOWN: `onKeyHeld` immediately, remember pointer, `modHoldOtherKeyPressed = false`.

Other key DOWN while held: set `modHoldOtherKeyPressed = true`.

UP:

```kotlin
val wasQuickTap = !otherPressed &&
    (now - modHoldStartTime) < TAPPING_TERM_MS
onKeyReleased(key)
if (wasQuickTap) onKeyTapped(key)  // cycle latch/lock
```

MOVE does not cancel dedicated holds (comment in source: drift while holding LWR is expected).

### KeyboardState

- Latch map for shift/ctrl/alt/caps: NONE, LATCHED, LOCKED
- Hold set for ctrl/shift/alt/meta; `layerHeld` for layer holds
- `effectiveLayer = layerHeld ?: layer`
- `isShiftActive` = latch or hold on **shift only** (not caps)
- `isCapsActive` = caps latch not NONE
- Letter case in `resolveLabel`: upper if `(shift && !caps) || (!shift && caps)`
- `onCharCommitted`: clear LATCHED mods and latched layer; reset TapMachines; does not clear holds
- Double-tap via `TapMachine.check` on modifier/layer cycle

### Multi-touch

Repeat and hold track pointer ids. Second finger can type while a mod is held.

---

## Verification (part 2)

| Claim | Evidence |
|-------|----------|
| HIT_EXPAND 2.5, tap 150, repeat 400/50 | NativeKeyboardView companion |
| doubleTap 300 | TapMachine default |
| Dedicated mod set | DEDICATED_MOD_ACTIONS in NativeKeyboardView |
| Home row hold map | SofleKeyData BASE left/right rows |
| isShiftActive excludes caps | KeyboardState.kt lines for isShiftActive / resolveLabel |
| Dual layout rule | CLAUDE.md; Layout.ts vs SofleKeyData.kt |
| Canvas view not RN for IME keys | NativeKeyboardView; CodeKeyboardIME.onCreateInputView |
