---
active: true
layout: group_index
title: "RUNE"
subtitle: "A gesture wearable that doesn't track your steps"
description: "Building a wrist gesture controller for smart devices — TV, bulbs, plugs, desktop. Not a fitness tracker."
date: 2026-04-25 00:00:00
background_color: '#1a1a2e'
group: rune
permalink: /rune/
---

![RUNE prototype — breadboard day one](/assets/rune/img/IMG_20260330_173915512.jpg)

---

## Before you read the parts

**[Epilogue: Read the Datasheet](/rune/09-epilogue)**
Every fix in this project came from reading a document, not guessing. The SH-2 reference manual, the LSM6DS3 datasheet, the SparkFun library source. On why reading before coding is faster than the alternative — and a gentle word about system design interviews where everything stays in the air.

---

RUNE is a wrist-worn gesture controller. Flick right — D-pad right. Pitch down — back. Hold still — nothing happens, which is the correct default. It talks to smart TVs, bulbs, plugs, and desktop inputs over BLE. No voice. No phone in hand. No accent required.

You don't need an accent to control a smart device. (Alexa 😉😉)

---

## What it's not

It's not a fitness tracker. This is a deliberate product decision, not an oversight.

Knowing your HRV every 20 minutes doesn't improve your health unless you're doing something with that number. Most people aren't. If you're outside having fun wearing a Rolex, you're having a good time. You don't need something on your wrist telling you that.

RUNE is a tool you put on when you want to control something, then take off and wear a real watch. Different category entirely.

*Caution: Your grandma might start dancing to chammak challo.*

---

## How it works

Firmware runs on an nRF52840 with a BNO085 — a 9-axis IMU that does sensor fusion on its own ARM Cortex-M0+ at 400Hz. Gesture segmentation happens on the chip: it classifies when motion starts, what shape it makes, and sends a label over BLE.

The phone app is the bridge. It receives the gesture, maps it to a device action, and fires the command — Android TV D-pad injection, smart plug HTTP, whatever. The execution logic lives in TypeScript, not C++.

That split exists for a reason. Iterating gesture matching at phone-flash speed is 10× faster than Arduino-reflash speed. The firmware stays minimal; the app handles the policy layer. Also: I ain't trusting an LLM with firmware I don't understand yet. The C++ side is written and reviewed line by line.

---

## The roadmap

| Phase | What ships |
|-------|------------|
| **RUNE-I** | Ship to real users, phone-paired, OTA updates |
| **RUNE-II** | Push compute on-device, add memory module |
| **RUNE-III** | Complex gestures — DTW or on-device ML (might split 3A/3B) |
| **RUNE-IV** | Custom PCB, lower profile, IR transmitter/receiver |
| **RUNE-V** | EMG pads for intent detection, extendable via pogo pins |

Everything before RUNE-IV is software. That's intentional — validate the interaction model before spinning custom silicon. RUNE-V is the version that turns it into something you might actually want on your wrist: clip on the EMG module when you need it, leave it off when you don't.

---

## The series

**[Part 1: The hardware](/rune/01-hardware)**
What's in it, what it cost (not cheap), and how it evolved from a glowing breadboard to a plastic box on velcro to a Three.js case model. Thanks to SM Electronics Kodhalli and Robocraze.

**[Part 2: The sensor wars](/rune/02-sensor-wars)**
Why 6-DOF failed, what the Kalman gain has to do with it, and why a magnetometer doesn't fix the problem indoors.

**[Part 3: The chip wouldn't wake up](/rune/03-wakeup)**
Two layered bugs in the sleep/wake path, including a concurrency issue in the SparkFun library that took two days to find.

**[Part 4: Eight problems called gesture detection](/rune/04-gestures)**
Segmentation, drift, axis isolation, combo sequences — each one looks simple until you've shipped it wrong once.

**[Part 5: Calibration, from 125 seconds to 3](/rune/05-calibration)**
MASR throttling, stable windows, and why the timer has to fire in `loop()` regardless of IMU events.

**[Part 6: The app](/rune/06-app)**
Claude built most of it. Humans tested the joints. The androidtvremote2 protocol, DTW, and what required a real TV.

**[Part 7: Power on 300mAh](/rune/07-power)**
Adaptive sample rates, staged sleep tiers, and the nine hours we spent watching INT blink at nothing.

**[Research on RUNE-III: Recognising Symbols in the Air](/rune/08-gesture-symbols)**
DTW, feature vectors, the $1 recognizer, shapelets, HMMs — five approaches to 1-shot gesture matching, ranked by how much they ask of you.

---

The hardware exists. The gestures work. The parts that were broken are documented in the posts above, not papered over.
