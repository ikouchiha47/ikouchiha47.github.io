---
layout: journal_entry
title: "100ms aggregation tier: collapsing 23K dispatches/s into 100"
subtitle: "The architecture was right. The event shape was wrong. Swap per-increment HTTP POST for a batched flush every 100ms."
group: millionrps
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
chapter: 2
chapter_title: "Fan-out"
entry_date: 2026-07-22
status: wip
tags: [SSE, fan-out, aggregation, ticker, batch, dispatcher, likes-server]
summary: "Checkpoint 7: add a 100ms aggregation tier inside likes-server. Instead of one HTTP POST per increment, accumulate postID → latestCount in a map and flush once per tick per fanout-node. Benchmarks not run — AWS shut down due to cost. Implementation is complete and the math holds."
result: "Implemented. At 23K inc/s across 10 posts, fan-out dispatches collapse from ~23K/s to ~100/s (one per post per 100ms tick). push_dropped expected to reach zero. Benchmark pending."
---

Source code: [ikouchiha47/gothun](https://github.com/ikouchiha47/gothun) — `src/likes/`

## the regression from checkpoint 6

Checkpoint 6 (process separation) regressed events/s by ~60% at every connection count. The cause was simple: `likes-server` was firing one HTTP POST per increment to the fanout-node. At 23K inc/s that's 23,000 HTTP POSTs per second — each costing ~50µs — saturating the drainer goroutine and filling the 512-slot push channel.

The fix isn't a faster transport. The fix is batching.

Like counts are not a reliable stream. Viewers don't need every intermediate value — they need the current value, refreshed fast enough to feel live. 100ms is imperceptible. So instead of dispatching every increment individually, accumulate them and flush the current state once per tick.

## what changed

A new `aggregator` sits between the write handler and the `pusher`. The write path calls `Accumulate` — a mutex lock, one map write, unlock. No network, no allocation beyond the first time a postID is seen in a window.

```go
type aggregator struct {
    p        *pusher
    interval time.Duration
    mu       sync.Mutex
    counts   map[string]int64  // postID → latest count in this window
}

func (a *aggregator) Accumulate(postID string, count int64) {
    a.mu.Lock()
    if count > a.counts[postID] {
        a.counts[postID] = count
    }
    a.mu.Unlock()
}
```

We store the **latest count**, not a delta. If 230 increments arrive for `post_42` in a 100ms window, we send the final value once. Subscribers get the current count — same semantics they had before, just fresher by at most 100ms.

Every 100ms, the flush goroutine swaps out the map and dispatches:

```go
func (a *aggregator) flush() {
    a.mu.Lock()
    if len(a.counts) == 0 {
        a.mu.Unlock()
        return
    }
    snap := a.counts
    a.counts = make(map[string]int64, len(snap))
    a.mu.Unlock()

    flushesTotal.Add(1)
    for postID, count := range snap {
        a.p.push(postID, count)
    }
}
```

The lock is held only for the map swap — a pointer assignment plus a `make`. The actual HTTP dispatch happens outside the lock. The write path is never blocked by network.

The pusher's `push()` method is unchanged — it still resolves the node via the consistent-hash ring and enqueues to the per-node buffered channel. The only difference is who calls it and how often.

## the arithmetic

Before (CP6): 23K inc/s, 10 posts → 23,000 HTTP POSTs/s to fanout-node.

After (CP7): 10 posts × 10 flushes/s = **100 HTTP POSTs/s**.

The 512-slot push channel drains 100 items per second. The drainer goroutine is idle 99.9% of the time. `push_dropped` should reach zero.

The fanout-node side is unchanged — it still fans to local SSE subscribers via the sharded hub from CP5. The question CP7 was meant to answer: once the push side stops being the bottleneck, does delivery% recover to CP5 levels, or does the subscriber-side shard channel become the new limit?

## what we didn't get to run

AWS was shut down after $112 in spend. The benchmark for CP7 was never run.

The implementation is complete and the math holds — but we don't have numbers. The expected result based on CP5 and CP6 data:

- `push_dropped` → 0 (push channel never fills at 100 items/s)
- Write throughput recovers toward the no-SSE baseline (~80K inc/s)
- Events/s and delivery% should recover to CP5 range or better, since fanout-node is no longer saturated by incoming push volume while trying to serve 64K SSE writes simultaneously
- The remaining question is whether the shard channel at fanout-node becomes the new ceiling — CP5 showed it filling at 64K connections regardless of push load

<div class="journal-callout warning">
<strong>Financial constraint</strong>
Benchmarking stopped here. c6in.8xlarge + 2× c8gn.large in ap-south-2 runs ~$5.50/hr. At that rate, serious iteration gets expensive fast. The implementation is done; the numbers will have to wait.
</div>

## what's still open

Two questions CP7 would have answered:

1. **Does write throughput recover?** CP6 showed it holding at ~12K inc/s under load — not the ~80K baseline. With aggregation removing the fan-out load from the write process, the write goroutines should get their CPU budget back.

2. **Where's the new ceiling?** At 64K SSE connections, CP5's sharded hub was already dropping at the shard channel level. CP7 removes the push bottleneck. If delivery% at 64K doesn't improve past CP5's 5%, the shard channel is the new limit — and the fix there is either larger shard buffers or coarser sharding.
