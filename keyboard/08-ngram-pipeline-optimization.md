---
active: true
layout: group_page
group: keyboard
group_title: "CodeKeyboard Rebuild Notes"
group_url: "/keyboard/"
title: "CodeKeyboard Part 8: Optimizing a 583MB N-gram Pipeline"
subtitle: "From OOM and 2-hour hangs to an 11-minute build on AWS"
date: 2026-08-19 08:00:00
background_color: '#0d1b2a'
---

## 1. The problem

We're building next-word prediction for a keyboard app. The training data is the SwiftKey en_US corpus: a single 583MB text file with 4.27 million lines of real-world typing. From it we need:

- **Bigrams** -- shipped in the production keyboard (`bigrams.json`)
- **Trigrams** -- for evaluation and future language packs (`trigrams.json`)
- Both scored with **Kneser-Ney smoothing** (discount 0.75, top-10 followers, min-count thresholds)

The constraints that made this interesting:

- The corpus is far too big to hold in memory as raw text, let alone as counted n-grams
- The pipeline must be **resumable** -- it runs on AWS spot instances that can die at any moment
- It must run on modest hardware: a 16GB laptop or a 4-vCPU spot instance

## 2. How it failed before

**Attempt 1: naive in-memory.** Read everything, count into dicts. Crashed with OOM. Not a surprise -- 583MB of text expands to tens of millions of n-gram keys.

**Attempt 2: durable multi-stage.** A resumable count/merge/index/score rewrite (`extract_ngrams_durable.py`, still in `scripts/` for comparison). It ran, but a faster variant (`extract_ngrams_fast.py`) hit the real wall: each worker's dump path did **one in-memory `sorted()` of ~10M pairs** at the end. On AWS the 4th worker (w002) sat there for hours -- it had written its unigram and bigram files but never finished the trigram sort. The run was killed after ~8 hours.

**Attempt 3: the k-way merge decision.** The fix was external merge sort: each worker spills **bounded sorted runs** to disk as it counts, then a **k-way heap merge** (`heapq.merge`) sums duplicates across all runs -- no single giant in-memory sort anywhere. A smoke test with 2 workers  10 spill runs merged all 20 runs exactly and matched the pre-rewrite baseline.

**Attempt 4: streaming with a bug.** The relaunch still hung -- 2+ hours, 4 workers at 96% CPU, zero spill files. `py-spy` found the cause: the new line-splitting loop did `buf = buf[nl+1:]` per line, **O(n) buffer slicing** over a 1MB buffer. The workers never even reached the first spill.

The lesson: **a subtle O(n) in a hot loop is worse than no optimization at all.**

## 3. The 5-stage pipeline

The rewrite that fixed the architecture -- five plain, resumable stages:

1. **Split** -- divide the file into byte ranges, aligned to line boundaries using `f.tell()`, so no worker ever gets a partial line.
2. **Count** -- N workers each read their whole range in one shot, count n-grams into dicts, and spill **sorted runs** to disk when the dict hits 2M entries (external merge sort).
3. **Reconcile** -- k-way merge the sorted runs with `heapq.merge`, summing duplicate keys, and insert into SQLite.
4. **Normalize** -- compute Kneser-Ney helper values (continuation probabilities, context totals) into a second SQLite DB.
5. **Score** -- stream contexts in key order, apply KN smoothing, write the JSON outputs.

Every stage is **streaming and memory-bounded**. The spill-to-disk pattern is what makes a 583MB corpus countable on a laptop.

## 4. Benchmarking: find the real bottleneck

Before optimizing, we measured each stage on a 250MB sample (1.09M lines):

| Stage | Wall time | Notes |
|---|---|---|
| count | 112s | 4 workers, 5 spills each |
| **reconcile** | **238s** | 18M trigram rows |
| normalize | 11s | |
| **score** | **161s** | 1M contexts, single-threaded |
| **total** | **~8.7 min** | |

Two clear targets. Reconcile was #1.

## 5. Fix #1: the SQLite bulk-load pattern (238s -> 63s)

Reconcile had two anti-patterns:

**Dead-weight conflict handling.** The k-way merge already sums adjacent equal keys, so every key it emits is unique. But the insert used `INSERT ... ON CONFLICT DO UPDATE` -- SQLite paid for a conflict check on every one of 18M rows, and the branch never fired.

**Index maintenance during insert.** The tables were created with PRIMARY KEYs, so SQLite maintained the B-tree index incrementally across 18M inserts. That's the classic bulk-load mistake.

The fix is the standard bulk-load pattern:

- Create **heap tables** (no index)
- Plain `INSERT` (the merge guarantees uniqueness)
- Build the indexes **once, after** the load

Since the merge emits rows already sorted by key, the index build is nearly free.

```
238s -> 63s   (3.8)
```

We also found and fixed a resume bug along the way: when a stage rebuilds its output, the downstream `.done` markers must be invalidated, or a later run silently uses stale data.

## 6. Fix #2: algorithmic scoring (hang -> 51s)

The score stage was the second bottleneck -- it had hung for >240s on just 50MB. The problem: for every trigram context, it recomputed the full backoff distribution from raw counts.

Two algorithmic fixes:

**Memoization.** `backoff(w2)` depends only on the last word of the context, not the whole context. Compute it once per distinct `w2` instead of once per context.

**Top-k dominance pruning.** A word that only appears in the backoff distribution scores `P_backoff(w|w2)` -- a monotonic function. So only the top `max_followers` backoff entries can ever reach the top-`max_followers` result. Use `heapq.nlargest` instead of sorting everything.

```
hanging (>240s) -> 51s on 250MB
```

## 7. SQLite WAL tuning

Small but real: `journal_mode=WAL`, `synchronous=NORMAL`, 64MB journal limit, 64MB page cache, 128MB mmap. These are the same defaults Rails 7.1 adopted for SQLite. They made the reconcile writes and score reads noticeably faster.

## 8. Results

**250MB sample, same machine:**

| Stage | Before | After |
|---|---|---|
| count | 112s | 37s |
| reconcile | 238s | 63s |
| normalize | 11s | 3.7s |
| score | 161s | 51s |
| **total** | **~8.7 min** | **~2.6 min** |

Outputs were byte-identical before and after -- the optimizations changed speed, not results.

**Full 583MB corpus on a spot t3.xlarge (4 vCPU): ~11 minutes.**

- 427,651 unigrams  10.36M bigrams  **35.9M trigram rows**
- 1,940,183 trigram contexts scored
- Outputs: `trigrams.json` (377MB), `bigrams.json` (20.6MB), `bigrams_support.json` (2.6MB)
- Instance self-terminated after upload

**Operationalizing.** The whole thing is now a one-command affair: a small `aws_ngrams.sh` wrapper handles upload -> launch -> wait -> status, and a cron monitor kills any instance that runs past 3 hours without producing output. A failed run costs minutes, not hours.

## 9. Lessons learned

1. **Measure before optimizing.** Per-stage timing turned "it's slow" into "reconcile is 46% of the time." We'd have wasted effort optimizing count otherwise.
2. **The bulk-load pattern is a superpower.** Insert without an index, build the index after. It's the difference between 18M incremental index updates and one sorted pass.
3. **Streaming + memory-bounded at every step.** External merge sort is why a 583MB corpus fits on a laptop.
4. **Algorithmic wins beat micro-optimizations.** Memoization and top-k pruning turned a hang into 51 seconds. No amount of loop tuning would have done that.
5. **Beware O(n) in hot loops.** The buffer-slicing bug cost us an entire AWS run.
6. **Disk pressure is a silent killer.** A 96%-full disk turned a 73-second stage into a 15-minute stall. Check `df` before long runs.
7. **Resumability pays for itself.** Stage markers + self-terminating spot instances meant a failed run costs minutes, not hours.