---
layout: journal_entry
title: "Sharding the SSE fan-out goroutine: same ceiling, different drop point"
subtitle: "8 parallel shard goroutines per topic instead of 1. The events/s ceiling didn't move. Here's why."
group: millionrps
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
chapter: 2
chapter_title: "Fan-out"
entry_date: 2026-07-15
status: done
tags: [SSE, fan-out, sharding, goroutine, channel, coordinator, unsafe.Pointer]
summary: "Replaced the single run() goroutine per topic with a coordinator + 8 shard goroutines, each owning 1/8 of the subscriber slice and draining its own buffered channel. Hypothesis: parallel iteration would raise the events/s ceiling and improve delivery at high connection counts."
result: "The ceiling is unchanged at ~7.5M events/s. Delivery% is statistically identical to the baseline. The bottleneck is not iteration speed — it is CPU contention between the write path and the fan-out goroutines on a single non-prefork process. The coordinator→shard channel (buffered 128) becomes the new drop point under load, not the subscriber iteration."
---

Source code: [ikouchiha47/gothun](https://github.com/ikouchiha47/gothun) — `src/likes/`

## the hypothesis

Entry 13 ended with a question: is the single `run()` goroutine iterating subscribers sequentially the bottleneck, or is it CPU contention?

The ceiling at 20K SSE connections was ~7.5M events/s with 33% delivery. At 64K it collapsed to 5%. If the `run()` goroutine was spending most of its time in the iteration loop and couldn't keep up with the broadcast rate, parallelising that loop across N goroutines should move the ceiling. If it was CPU — if the OS scheduler was just starving the fan-out goroutines because write goroutines were consuming cores — then sharding would do nothing.

The only way to know was to build the sharded version and run the same benchmark.

## what changed

The single `run()` goroutine becomes a coordinator that fans out to N shard goroutines. Each shard owns a contiguous slice of subscribers and drains its own buffered channel.

```
broadcast channel
      ↓
coordinator goroutine (one per topic)
      ↓  ↓  ↓  ↓  (N sends to N shard channels, buffered 128)
shard[0] shard[1] ... shard[N-1]
goroutine goroutine    goroutine
owns 1/N  owns 1/N     owns 1/N
of subs   of subs      of subs
```

`numShards = runtime.NumCPU() / 4` — 8 on the 32-core server.

Shard assignment for a subscriber:

```go
idx := int(uintptr(unsafe.Pointer(sub)) % uintptr(n))
```

Stable for the lifetime of the subscriber (pointer doesn't move after allocation), zero allocation, and requires no extra field on the `Subscriber` struct. The `unsafe.Pointer` cast is just arithmetic — we're treating the address as a number to get a deterministic bucket.

The coordinator loop:

```go
func (t *topic) run() {
    for val := range t.broadcast {
        t.mu.RLock()
        shards := t.shards
        t.mu.RUnlock()
        for _, sh := range shards {
            select {
            case sh.ch <- val:
            default: // shard channel full — drop for all subs in this shard
            }
        }
    }
}
```

Each shard goroutine:

```go
func (s *shard) run() {
    for val := range s.ch {
        for _, sub := range s.subs {
            select {
            case sub.Ch <- val:
            case <-sub.Done:
            default:
            }
        }
    }
}
```

Same drop policy as before — slow reader loses the event. The difference is that 8 goroutines are now iterating subscriber slices in parallel instead of one.

The coordinator does N channel sends per event. At 8 shards, that's 8 non-blocking sends into buffered channels. Microseconds. Not a bottleneck.

## results

Machine: c6in.8xlarge (32 vCPU, 50 Gbps) | Clients: 2× c8gn.large (Graviton4 arm64)
Writers: 500 goroutines, 10 posts round-robin. Delivery% = events_received / (writes × subs_per_post) × 100.

<div class="bench-table-wrap">
<table class="bench-table">
<thead><tr><th>SSE Connections</th><th>Events/s</th><th>Delivery%</th><th>Write inc/s</th><th>Server RSS</th><th>FDs</th></tr></thead>
<tbody>
<tr><td>2,000</td><td>4,452,394</td><td>90.1%</td><td>24,700</td><td>626 MB</td><td>2,529</td></tr>
<tr><td>10,000</td><td>6,682,850</td><td>56.6%</td><td>11,814</td><td>922 MB</td><td>10,529</td></tr>
<tr><td class="highlight">20,000</td><td class="highlight">7,543,145</td><td>33.1%</td><td>11,406</td><td>1,325 MB</td><td>20,529</td></tr>
<tr><td>64,000</td><td class="bottleneck">2,599,775</td><td class="bottleneck">5.0%</td><td>8,192</td><td>3,128 MB</td><td>64,527</td></tr>
</tbody>
</table>
</div>

Comparison against Checkpoint 4 (single goroutine):

<div class="bench-table-wrap">
<table class="bench-table">
<thead><tr><th>SSE Connections</th><th>Events/s (single)</th><th>Events/s (sharded)</th><th>Delta</th></tr></thead>
<tbody>
<tr><td>2,000</td><td>4,877,998</td><td>4,452,394</td><td>-8.7%</td></tr>
<tr><td>10,000</td><td>6,410,218</td><td>6,682,850</td><td>+4.3%</td></tr>
<tr><td class="highlight">20,000</td><td class="highlight">7,449,766</td><td class="highlight">7,543,145</td><td>+1.3%</td></tr>
<tr><td>64,000</td><td class="bottleneck">2,862,760</td><td class="bottleneck">2,599,775</td><td>-9.2%</td></tr>
</tbody>
</table>
</div>

## what this means

**The ceiling didn't move.** ~7.5M events/s at 20K connections, whether you use 1 goroutine or 8. The delta across all four connection levels is within noise — +4% at 10K, -9% at 64K. There's no signal here. The hypothesis was wrong.

**The coordinator→shard channel is the new drop point.** At 64K connections, each shard owns ~8K subscribers. When the broadcast rate is high, the shard goroutines can't drain their channels fast enough — iterating 8K subscribers takes longer than the inter-event gap. The coordinator hits the `default` case on `sh.ch <- val` and drops the event for the entire shard. With 8 shards, one full shard channel silently discards all events for 8K subscribers. This is actually worse in terms of fairness than the single-goroutine model, where drops were per-subscriber.

The shardBuf of 128 is just a number. Make it bigger and you defer the drop; you don't eliminate it. The shard goroutines are still CPU-bound.

**Write throughput degrades identically.** With no SSE readers: ~80K inc/s. At 64K SSE connections: ~8K inc/s. This is the same curve as Checkpoint 4. The write goroutines and fan-out goroutines share the same OS process. The scheduler splits cores between them without knowing that writes are on the critical path. More fan-out goroutines (8× more) means 8× more goroutines competing for the same cores — if anything, sharding adds scheduler overhead.

<div class="journal-callout finding">
<strong>Finding</strong>
Sharding the fan-out loop is not the bottleneck. The in-process ceiling is CPU competition between the write path and the fan-out goroutines. Both are on the same OS process. The OS scheduler has no knowledge of their relative priority, and adding more goroutines makes this worse, not better. The iteration speed of a single goroutine over N subscribers is not the limiting factor — it's how many CPU cycles the process gets in total.
</div>

## what we learned about the drop point

There are two places events can be dropped in the sharded design:

1. **Coordinator → shard channel** (`shardBuf=128`): drops the event for every subscriber in that shard — bulk loss
2. **Shard goroutine → subscriber channel** (`sub.Ch`, 8 slots): drops for one slow subscriber only

The single-goroutine design had only drop point 2. Sharding introduced drop point 1, which is coarser. Under high load, most drops happen at point 1, which explains why delivery% at 64K is similar (5%) despite the different architecture — the shard channels fill just as the broadcast channel did before.

## what's next

The conclusion from two checkpoints is consistent: in-process fan-out on a single non-prefork process has a CPU ceiling around 7.5M events/s. You cannot cross it by changing how you iterate subscribers inside that process.

The correct boundary is between the write path and the fan-out path. They need separate CPU budgets. That means either:

- **Separate processes**: prefork-style, where fan-out happens in workers that don't share the write goroutine pool
- **Message passing across process boundary**: fan-out over a Unix socket or shared memory ring, so the write path is never scheduled on the same core as fan-out

Phase 2 is separate processes. That's the next checkpoint.
