---
active: true
layout: post
title: "RUNE Part 1: The Hardware"
subtitle: "From breadboard to a thing that fits on your wrist"
description: "What's actually in the RUNE prototype, what it cost, and how it evolved from a glowing breadboard circuit to a plastic box held on by velcro."
date: 2026-04-26 00:00:00
background_color: '#0f2027'
---

![First working circuit — breadboard, BNO085 Qwiic, nRF52840 XIAO](/assets/rune/img/IMG_20260330_173915512.jpg)

That blue glow is the BLE advertising indicator. That's the whole device. Everything RUNE does — gesture detection, BLE communication, power management — is running on those two boards jammed into a breadboard at 17:39 on March 30th, somewhere in Bengaluru.

This post is about how it got from there to something you can actually wear.

---

## What's in it

Nothing here is cheap.

**Seeed Studio XIAO nRF52840 Sense — ₹1100+**
Nordic nRF52840 MCU: BLE 5.0, 64MHz Cortex-M4F, 256KB RAM, 1MB flash. BLE-certified. USB-C charging. Has an onboard LSM6DS3TR-C 6DOF IMU — which turns out to matter a lot, and not in a good way. That story is [Part 2](/2026/04/27/rune-part2-sensor-wars.html).

**SparkFun BNO085 Qwiic Breakout — ₹800–1000**
A 9-axis IMU with a dedicated ARM Cortex-M0+ running Bosch SH-2 sensor fusion at 400Hz internally. More expensive than the MCU. Worth it. Qwiic connector makes the I2C wiring a single keyed cable rather than four loose jumpers that vibrate loose at the worst possible moment.

**TP4056-based LiPo charger, 3.7V 300mAh LiPo, perfboard, velcro strap, a small plastic component box.**

That's the full BOM for the prototype. The custom PCB target for RUNE-IV brings this to ₹1400–1950/unit with assembly — Raytac MDBT50Q bare module (₹450–600, smaller than XIAO, still nRF52840, still certified), BNO085 bare chip (₹350–450), LDO + charger + passives + a 2-layer PCB from JLCPCB. Still not cheap. But product-shaped.

---

## Thanks

Initial soldering was done at **SM Electronics, Kodhalli** — the kind of local shop where you walk in with a board, explain what you need, and walk out with something that works. Parts sourced from **Robocraze**. Eventually learned to solder myself, which is faster than it sounds and more satisfying than it should be.

---

## The physical evolution

**Breadboard (March 2026)**
The photo above. Works. Glows. Falls apart if you look at it wrong. A wearable that disconnects when you move your arm is not a wearable — it's a desk toy.

The BNO085 resets under vibration because loose breadboard contacts cause momentary I2C glitches that trigger the sensor's internal watchdog. The fix for production: 100nF ceramic decoupling cap between BNO085 VDD and GND (< 2mm trace), 10µF bulk cap on the 3.3V rail, solid solder joints. For prototyping: the Qwiic cable at least removes the four loose jumpers that were the worst offenders.

**Sandwich stack concept**
Sensor on top (clean signal, away from RF noise and heat), foam spacer in the middle, MCU below, battery behind. This is how every real smartwatch is built internally. Stack > loose wires.

```
[ BNO085 sensor ]
[ foam spacer   ]   ← 3–8mm, prevents shorts and noise coupling
[ nRF52840 XIAO ]
[ LiPo battery  ]
```

**Perfboard**
Solder both modules to a small perfboard with short solid-core wire between pads. Dramatically more vibration-resistant than breadboard. The I2C glitch resets mostly disappeared.

**Plastic component box + velcro strap (April 2026)**

![Prototype housing — plastic box, battery inside, wireless](/assets/rune/img/IMG_20260429_174628015.jpg)

Ugly. Self-contained. Battery inside. Wireless. This is what you actually test with — not the breadboard, not a render.

**Three.js case models (April 2026)**
Designed three case iterations in the browser using Three.js before committing to dimensions. v3 landed at:

- Outer body: 29 × 33 × 14.5mm
- Inner cavity: 26 × 30 × 11.5mm
- Wall thickness: 1.5mm
- Strap slots: 22 × 3mm each side
- USB-C cutout on the +Z face

That's WHOOP-territory thickness. The model has orbit controls — you can drag and inspect it. When someone asks what it's going to look like, you show them the Three.js render. When you're actually testing, you use the box.

---

## Power

300mAh LiPo at 3.7V = 1.11 Wh.

Currently: survives one full night on a single charge. Target: one full day minimum, two days on a fresh device.

Approximate draw breakdown:
- BLE TX at −20dBm instead of 0dBm default: saves ~5mA during connection events
- PDM microphone disabled at boot (`PIN_PDM_PWR LOW`): saves ~1.5mA
- BNO085 in sleep between gestures: drops from ~1mA to ~few hundred µA
- nRF52840 deep sleep: ~2µA

Getting from one night to two days means average draw under ~23mA across the duty cycle. That's tight with BLE active. The sleep/wake logic on the BNO085 is the main variable — and it was completely broken when we first implemented it. [That's Part 3](/2026/04/28/rune-part3-wakeup.html).

The current debugging approach: multimeter in series with the battery line to measure real draw in each state. Serial logs tell you what the firmware thinks it's doing. The multimeter tells you what's actually happening.

---

## RUNE-IV/V hardware direction

RUNE-IV: custom 2-layer PCB with the Raytac MDBT50Q (no USB-C port thickness penalty) and BNO085 bare chip. Decoupling caps built in. IR transmitter/receiver on the underside for controlling non-smart TVs.

RUNE-V: EMG pads via extendable pogo pins. Clip the EMG module on when you want muscle-based intent detection, off when you don't. Clip-on or standalone watch form factor. This is the version that makes it something you might actually choose to wear.

Not a fitness tracker. A control surface that happens to sit on your wrist.
