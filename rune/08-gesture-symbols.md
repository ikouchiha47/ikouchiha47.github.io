---
active: true
layout: group_page
group: rune
group_title: "RUNE"
group_url: "/rune/"
title: "Research on RUNE-III: Recognising Symbols in the Air"
subtitle: "Five approaches to matching wrist gesture time series, ranked by how much they ask of you"
description: "DTW, the $1 recognizer, feature vectors, HMMs, shapelets, and CNNs — what the literature says about 1-shot gesture matching on IMU data."
date: 2026-05-02 00:00:00
background_color: '#12001a'
---

![Early prototype — the hardware that will run RUNE-III](/assets/rune/img/IMG_20260330_173915512.jpg)

RUNE-I maps fixed gestures to fixed actions. Turn right → D-pad right. That's a lookup table. RUNE-III is different: the user draws a symbol in the air — a Z, an L, a circle — and the device recognises it. One recording per gesture, no training set, no server.

This post is the research that went into figuring out how to do that. It is not implementation — that's RUNE-III's problem. This is what we found when we asked: who has solved this before, and with what?

The full research document lives in `docs/GESTURE_SYMBOL_RECOGNITION.md`. This is the annotated version.

---

## The core problem

Record a reference gesture once. Later, the user performs the same gesture 20% slower, or with a brief pause. Simple Euclidean distance between the two time series says they are different. A human says they are the same.

The signal at each timestep is `ω(t) = [ωx, ωy, ωz]` — angular velocity from the BNO085 gyroscope at ~50Hz. A gesture is a short burst of this signal, segmented by the FSM from [Part 4](/rune/04-gestures). The matching problem is: given a reference recording and a query recording, are they the same gesture?

Five approaches, ranked by how much they ask of you.

---

## 1. Feature Vector + Distance

**What it is:** Instead of comparing time series directly, extract a fixed set of scalar features from each gesture — peak roll rate, peak pitch rate, total integral per axis, duration, dominant axis — and compare the resulting vectors with Euclidean or cosine distance.

```
gesture → [peak_roll_rate, peak_pitch_rate, total_roll_integral,
           total_pitch_integral, duration_ms, dominant_axis]
       → compare as a fixed-length vector
```

**Why it works for this:** Benbasat (2002) showed that tracking peaks and their integrals is sufficient to distinguish discrete arm gestures from noise:

> "Since the velocity of the arm is zero at the ends of the gesture, the integral of the acceleration across it must be zero as well. Therefore, recognition is accomplished simply by tracking across an area of activity, and recording the number of peaks and their integral." — [Benbasat 2002](https://3dvar.com/Benbasat2002An.pdf)

A Z drawn in the air has a different peak roll rate and integral profile than an L. A circle has a different dominant-axis distribution than either. For gestures with distinct feature profiles this works well and is trivially fast.

**Where it fails:** Two gestures that differ only in timing or subtle path shape produce similar feature vectors. A fast Z and a slow Z have different peak rates even if the integral is the same. And gestures that share the same dominant axis (two different "horizontal swipe" variants) will be confused.

**Verdict for RUNE-III:** Start here. If the gesture vocabulary is designed to be distinct in feature space — and it can be, because we choose the vocabulary — this is good enough and requires zero libraries.

---

## 2. Dynamic Time Warping (DTW)

**What it is:** DTW warps the time axis of one sequence to find the optimal alignment with another, then measures distance on the aligned version. A gesture drawn 20% slower gets elastically stretched to match the reference; the shape is compared, not the timing.

```
Reference: [A, B, B, C, D, D, E]
Query:     [A, B, C, C, D, E, E]

DTW finds the minimum-cost path through the N×M cost matrix,
where each cell = Euclidean distance between two ω(t) 3D vectors.
```

Path constraints:
- Left-to-right and top-to-bottom only (monotonicity + continuity)
- DTW distance = minimum cost over all valid paths
- Standard O(N²) dynamic programming — [audiolabs-erlangen.de](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C3/C3S2_DTWbasic.html)

**The Sakoe-Chiba band:** Unconstrained DTW can produce degenerate alignments — the entire reference mapped to a single query point, destroying temporal structure. The band constrains the path to stay within W samples of the diagonal:

```
Complexity: O(N²) → O(N·W)
```

This reflects a realistic assumption: a gesture drawn 20% slower shouldn't map the first half of the reference to the first 10% of the query. Timing variations are local and bounded.

**For wrist gestures:** Each cost matrix cell is the Euclidean distance between two `ω(t)` samples (3D vectors). The path warps time while preserving the shape of the angular velocity profile. A Z drawn fast and a Z drawn slow, once aligned, look the same.

**What it gives you:** 1-shot learning (one reference per gesture), handles speed variation, interpretable distance metric. No training, no model.

**What it costs:** O(N·W) per match, per gesture class. At 50Hz and 1-second gestures, N=50. With W=15, that's 750 cell evaluations per pair. With 20 gesture classes, 15,000 evaluations per recognition event. Fast enough on a phone.

**Verdict for RUNE-III:** The fallback when feature vectors can't discriminate. The combination — feature vectors for fast rejection, DTW for confirmation — is the recommended starting point from the literature for small-vocabulary 1-shot wrist gesture matching. ([MDPI Applied Sciences](https://www.mdpi.com/2076-3417/10/12/4213))

---

## 3. The $1 / $N Unistroke Recognizer

**What it is:** Originally designed for touch input stroke gestures. Resamples the gesture path to N equally-spaced points, rotates to canonical angle, scales to unit square, then finds the best-matching template via golden-ratio distance search. About 100 lines of code. Works with one template per class. ([depts.washington.edu/acelab](http://depts.washington.edu/acelab/proj/dollar/index.html))

**For wrist gestures:** Treat the gravity vector tip as the stroke — `g(t)` traces a path on the sphere S² as the wrist moves. `SymbolCapture.ts` already records this. The $1 recognizer treats it as a 2D path on the sphere surface, mapping almost directly to what the capture module records.

Extensions: `$N` handles multi-stroke gestures. `$P` uses point-cloud representations that ignore stroke order and direction entirely.

**Where it fails:** Rotation normalisation is lossy. Two gestures that differ only in starting orientation appear identical after normalisation — if you start drawing a Z from the left vs from the right, the canonical form is the same. For air gestures where starting orientation is unconstrained, this is a real problem.

**Verdict for RUNE-III:** Worth trying specifically for the gravity vector path as stroke. Trivial to implement, 1-shot, interpretable. The rotation-normalisation issue may or may not matter depending on how the gesture vocabulary is defined.

---

## 4. Hidden Markov Models

**What they are:** Each gesture class is modelled as a sequence of hidden states with transition probabilities. Each state emits an observation (quantised ω vector). Training (Baum-Welch) finds the parameters that maximise likelihood of observed sequences. Classification = which HMM gives the highest probability for the input.

HMMs were the industry standard for gesture recognition throughout the 2000s and into the 2010s. They handle variable-length sequences, noise, and tempo variation naturally.

> "HMM-based approaches were shown to be effective at increasing the recognition rate of inertial sensing-based gesture recognition." — [MDPI Applied Sciences](https://www.mdpi.com/2076-3417/10/12/4213)

**What they cost:**

> "HMM classifiers are expensive on account of their computational complexity; moreover, they require more than one training sample to efficiently train the model and obtain better recognition rates." — [MDPI Informatics](https://www.mdpi.com/2227-9709/5/2/28)

Not 1-shot. You need 10–50 training examples per gesture class to train a useful HMM. That's a data collection problem. For a device where the user records one example per gesture, HMMs are the wrong tool.

**Verdict for RUNE-III:** Skip unless the gesture vocabulary expands and per-user training sessions become a product feature. File under "when you have data."

---

## 5. Shapelet-Based Matching

**What it is:** A shapelet is a short subsequence that maximally discriminates between classes. Instead of matching the full time series, find the most characteristic window and match only that.

> "Time series shapelets are small, local patterns in a time series that are highly predictive of a class and are thus very useful features for building classifiers." — [Mueen et al., KDD 2011](https://www.cs.nmsu.edu/~hcao/readings/cs508/kdd2011_p1154-mueen.pdf)

Ultra-Fast Shapelets bring the discovery speed to 3–4 orders of magnitude faster than earlier methods. ([arxiv 1503.05018](https://arxiv.org/pdf/1503.05018))

**For wrist gestures:** The moment of peak jerk + the following ~200ms is typically the most discriminating window. The deceleration phase at the end of a gesture looks similar across gesture classes — it's the onset that carries identity. A shapelet-based approach would focus matching on exactly that window.

**What it costs:** Shapelet discovery requires labelled training data. Without it, you have to hand-pick the discriminative window, which is manual tuning rather than learning. The Logical Shapelets extension handles more expressive queries. ([ACM DL](https://dl.acm.org/doi/10.1145/2020408.2020587))

**Verdict for RUNE-III:** Interesting for a future where we have recorded session data from real users across gesture classes. The insight — the onset window is the discriminative part — is directly applicable even if we don't run full shapelet discovery. Worth baking into the feature vector definition.

---

## 6. 1D CNN on Raw Signal

**What it is:** Treat `ω(t)` as a 3-channel 1D signal. 1D convolutional layers extract local temporal patterns — learned shapelets, essentially. Works extremely well with enough training data.

**What it costs:** "Enough training data" means hundreds of examples per gesture class. For a 1-shot device, this is overkill by several orders of magnitude.

> "For applications with limited training data (1–3 examples per gesture), simpler methods like DTW or feature-based approaches are more appropriate than deep learning approaches." — [MDPI Applied Sciences](https://www.mdpi.com/2076-3417/10/12/4213)

**Verdict for RUNE-III:** File under RUNE-III-B or later. If the device ever ships to real users and we can collect labelled gesture data at scale, revisit. Not now.

---

## What RUNE-III actually builds

The constraint is hard: one example per gesture class, recorded by the user, no server, runs on-device in TypeScript.

**Phase 1 — Feature vectors.** Design the gesture vocabulary to be distinct in feature space. If a Z and an L have different peak rate profiles, a feature vector classifier costs nothing and needs no libraries. `SymbolCapture.ts` already captures the raw gyro stream needed to extract features.

**Phase 2 — DTW with Sakoe-Chiba when needed.** For gestures whose feature vectors overlap, drop into DTW. One reference recording stored as a time series. O(N·W) per match. Still real-time on a phone.

**Phase 3 — Onset shapelet intuition.** When tuning DTW or feature extraction, focus on the jerk-onset window (peak jerk + 200ms). That's where gesture identity lives. The rest of the signal is deceleration that looks alike.

CNNs and HMMs are parked. They require data we don't have yet.

---

## References

- Benbasat, A.Y. (2002). [An Inertial Measurement Unit for User Interfaces](https://3dvar.com/Benbasat2002An.pdf)
- Wobbrock et al. [The $1 Unistroke Recognizer](http://depts.washington.edu/acelab/proj/dollar/index.html) — University of Washington HCI
- Audiolabs Erlangen. [DTW — Fundamentals](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C3/C3S2_DTWbasic.html)
- Mueen et al. (2011). [Logical-Shapelets, KDD 2011](https://www.cs.nmsu.edu/~hcao/readings/cs508/kdd2011_p1154-mueen.pdf)
- Rakthanmanon et al. (2015). [Ultra-Fast Shapelets](https://arxiv.org/pdf/1503.05018)
- Mekruksavanich & Jitpattanakul (2020). [LSTM-based Deep Learning for Gesture Recognition](https://www.mdpi.com/2076-3417/10/12/4213) — MDPI Applied Sciences
- Various IMU gesture classification surveys — [MDPI Informatics](https://www.mdpi.com/2227-9709/5/2/28)
