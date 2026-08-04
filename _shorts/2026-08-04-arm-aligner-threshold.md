---
date: 2026-08-04 09:14
tags: [rune, firmware]
---
Spent the morning on the arm-aligner threshold again. **15° felt right on my wrist, completely wrong on my brother's** — smaller wrist, faster relaxation snap, false triggers on almost every third gesture.

Options on the table:

- Fixed threshold, tuned per-user in a settings screen
- Auto-calibrate from a few seconds of idle baseline, CGM-style
- Percentile of observed range instead of an absolute degree value

Going with the second one. Rough shape:

```
baseline := sampleIdle(3 * time.Second)
threshold := baseline.roll ± NEUTRAL_BAND
```

Prototyping tonight instead of pushing another magic number.
