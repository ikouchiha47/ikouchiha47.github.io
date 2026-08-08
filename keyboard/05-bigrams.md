---
active: true
layout: group_page
group: keyboard
group_title: "CodeKeyboard Rebuild Notes"
group_url: "/keyboard/"
title: "CodeKeyboard Part 5: Bigram Next-Word Prediction"
subtitle: "Seed, user layer, librime decay, limits"
date: 2026-08-08 05:00:00
background_color: '#0f2027'
---

## Gap

Prefix tries answer "what continues `th`?". After the user commits `thank` and presses space, composing is empty. A pure prefix bar has nothing to query. Bigrams answer "what often follows `thank`?" (`you`, ...).

Design notes: `docs/bigram-prediction-design.md`, `docs/adr-001-bigram-prediction.md`.  
Implementation: `BigramModel.kt`.  
Seed builder: `scripts/extract_bigrams.py`.

## Two layers

### Seed - assets/bigrams.json

Built from Norvig `count_2w.txt` (Google Web 1T style counts, MIT-licensed redistribution via Norvig).

Script flow:

1. Parse `w1 w2 \t count` lines, keep clean lowercase words  
2. Sort by count, take top N (`--top`, default 30000)  
3. Group by w1, keep up to `--max-followers` (default 10)  
4. Score inside each bucket: `log(count+1) / log(total+1)`  
5. Write compact JSON: `{ "want": [["to", 0.9822], ...], ... }`  

**Measured shipped file** (do not trust ADR "100k pairs" wording without measuring):

| Metric | Value |
|--------|------:|
| Bytes | 633187 (~618 KiB) |
| Predecessors | 9287 |
| Pairs | 34632 |
| Avg followers | 3.73 |
| Max followers | 10 |

Spot checks from file:

- `thank` -> you, the, all, my, them  
- `please` -> contact, note, click, ... (formal/web)  
- `want` -> to, it, a, the, ...  
- `i` has a full cap of followers (have, am, was, can, ...)  

Loaded in `loadSeed()` into `Map<String, List<Pair<String, Float>>>`.

### User - filesDir/user_bigrams.json

Format v2:

```json
{
  "tick": 1234,
  "entries": {
    "want": [["to", 12.4, 1230], ["a", 3.1, 800]]
  }
}
```

Each triple: next word, `dee`, `lastTick`.  
If file lacks `entries`, load returns empty (v1 wipe). Documented as intentional; no migration.

Max followers per predecessor: `MAX_USER_FOLLOWERS = 20`.  
Persist async after each `recordTransition`.

## librime decay

Constants:

```kotlin
HALF_LIFE = 200.0
DEE_AMPLITUDE = 1.0
SCORE_CEIL = 1.0
SCORE_FLOOR = 0.05
KM = 1.0 / (1.0 - exp(-0.005))
SEED_WEIGHT = 0.4f
USER_WEIGHT = 0.6f
```

**formula_d**

```kotlin
dee + DEE_AMPLITUDE * exp((lastTick - currentTick).toDouble() / HALF_LIFE)
```

**formula_p**

```kotlin
val m = SCORE_CEIL - (SCORE_CEIL - SCORE_FLOOR) *
        (1.0 - exp(-globalTick / 10_000.0)).pow(10)
if (dee < 20.0) m + (0.5 - m) * (dee / KM)
else m + (1.0 - m) * (4.0.pow(dee / KM) - 1.0) / 3.0
```

`globalTick` increments on every `recordTransition` after the update, and is stored in JSON.

Port source cited in code: librime `algo/dynamics.h`.

## Scoring merge

```kotlin
// seed
scores[word] += SEED_WEIGHT * seedScore
// user
scores[word] += USER_WEIGHT * formulaP(dee).toFloat()
// filter prefix, sort desc, take n
```

## Call sites

| Event | Action |
|-------|--------|
| flushComposing with non-empty word | recordTransition(prev, word); prev = word |
| suggestion tap | same; then nextWords(word) into bar |
| space after flush | nextWords(prevCommittedWord, n=5), update("", list) |
| mid-word suggest | suggest(prefix, k, context=prevCommittedWord) promotes bigram hits |

Mixed Latin scripts: plain string keys. User layer learns `ami` -> `tomake` without language IDs.

## Limits (accurate framing)

1. Seed coverage is thin (many preds have 1 follower; avg 3.7).  
2. Norvig web register skews formal (`please contact`).  
3. No unigram backoff if predecessor missing from both layers.  
4. Seed hard-capped at 10 followers.  

Mid-word with empty bigram context still has Merged trie + BEVA.  
After space with unknown prev and empty user layer, bar can be empty. Those are different failures.

## Upgrade direction (detail in part 7)

Replace densify seed (HeliBoard/AOSP `.combined` / `.dict`), keep user decay, add backoff. Do not throw away `BigramModel`'s two-layer shape.

---

## Verification (part 5)

| Claim | Evidence |
|-------|----------|
| 0.4 / 0.6 weights | BigramModel companion |
| MAX_USER 20, seed max 10 | BigramModel; extract_bigrams default |
| formula_d / formula_p | BigramModel private methods |
| v2 JSON shape | loadUserBigrams / persistAsync |
| 9287 / 34632 / 633187 | measured bigrams.json |
| extract log-normalize | extract_bigrams.py scored append |
| BigramAware promote | SuggestionStrategy.kt |
| record on flush and tap | CodeKeyboardIME flushComposing, handleSuggestionTap |
