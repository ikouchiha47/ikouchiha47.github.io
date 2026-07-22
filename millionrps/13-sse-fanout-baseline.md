---
layout: journal_entry
title: "the problem changed"
subtitle: "Not RPS anymore. One write, N subscribers. The ceiling is now about fan-out, not throughput."
group: millionrps
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
chapter: 2
chapter_title: "Fan-out"
entry_date: 2026-07-12
status: done
tags: [SSE, fan-out, hub, goroutine, channel, in-process, likes, fiber]
summary: "Switched problem domains: instead of maximising RPS on a read endpoint, we're now fanning out like-count updates to N SSE subscribers per post. One write triggers a broadcast to everyone watching. First baseline: single goroutine per topic, buffered channels per subscriber, fixed 500 writers + ramping SSE readers."
result: "Events/s peaks at ~7.5M at 20K SSE connections then collapses at 64K. Write throughput drops from ~80K/s (no SSE) to ~8K/s at 64K SSE — the write path and fan-out goroutines compete for CPU on the same non-prefork process. The in-process ceiling is CPU contention, not fan-out iteration speed."
---

Source code: [ikouchiha47/gothun](https://github.com/ikouchiha47/gothun) — `src/likes/`

## the problem is different now

Chapters 1-12 chased raw RPS on a static JSON endpoint. The bottlenecks were all in the network path: IRQ affinity, NIC saturation, prefork, compression. The server did the same work every request.

Fan-out is a different shape. One POST `/like/post_42` needs to reach every viewer currently watching `post_42`. If 10,000 viewers are watching, one write becomes 10,000 SSE events. The metric is no longer requests/second — it's **events delivered per second**, and the ceiling is wherever the broadcast loop breaks.

This is the likes system: users watch live streams, hit like, and the count updates in real time for everyone watching.

## what we built

```
POST /like/:postID
  → increment counter (sharded atomic, LRU dedup)
  → hub.Publish(postID, newCount)
  → topic goroutine reads from broadcast channel
  → iterates subscriber slice, sends to each sub.Ch
  → ServeSSE drains sub.Ch → writes SSE event → flush
```

Each `postID` is a **topic**. Each topic has:
- One buffered `broadcast` channel (64 slots)
- One `run()` goroutine reading from it
- A `[]*Subscriber` slice — one entry per open SSE connection

```go
type topic struct {
    broadcast chan int64
    mu        sync.RWMutex
    subs      []*Subscriber
}

func (t *topic) run() {
    for val := range t.broadcast {
        t.mu.RLock()
        targets := t.subs
        t.mu.RUnlock()
        for _, sub := range targets {
            select {
            case sub.Ch <- val:
            case <-sub.Done:
            default: // slow reader — drop, not block
            }
        }
    }
}
```

**Slow reader policy: drop, not block.** A viewer with a slow connection cannot stall the broadcast loop for everyone else. Like counts are not a reliable stream — the client only needs the latest value, not every intermediate count.

Each `Subscriber` is owned entirely by its `ServeSSE` goroutine — it creates the channels, reads from `Ch`, and closes `Done` when the connection ends. The hub only stores the reference. This avoids the classic "send on closed channel" panic: the hub never touches channel lifecycle.

## setup

- **Server:** c6in.8xlarge (32 vCPU, 64GB, 50 Gbps) — single process, prefork disabled (write path and SSE hub must share memory)
- **Writers:** `like-writer` — 500 goroutines, 10 posts round-robin, fire-and-forget POST
- **SSE clients:** `sse-load-client` — split across 2× c8gn.large (Graviton4 arm64, 2 vCPU each). Each client machine is limited to ~32K outbound ports, so two clients cover 64K connections
- **Delivery%:** `events_received / (writes × subs_per_post) × 100` — measured client-side by comparing received SSE events against server's `increments_total`

Ramp: 2K → 10K → 20K → 64K SSE connections, 30s measurement window per phase.

## results

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

## what this means

**Events/s peaks at 20K connections (~7.5M/s) then collapses.** At 20K connections across 10 posts, each topic has 2K subscribers. The `run()` goroutine can iterate 2K subscriber channels in well under 1ms — it keeps up. At 64K (6.4K subs/topic), iteration takes longer than the inter-event gap. The broadcast channel fills. Events back up. Delivery falls to 5%.

**Write throughput collapses under SSE load.** With no SSE readers, the write path peaks at ~80K inc/s. At 2K SSE connections it's 24K/s. At 64K it's 8K/s. The fan-out goroutines and the write goroutines are competing for CPU cores on the same non-prefork process. The OS scheduler doesn't know that fan-out is less important than writes — it gives them equal time.

**~47KB per SSE connection.** `(3128 - 626) MB / 62K ≈ 40KB`. Each connection holds: a net/http goroutine (~8KB stack minimum), a `Subscriber` struct with two buffered channels, and TCP read/write buffers. This matches expectation.

**Delivery% and events/s are different bottlenecks.** Even at 20K connections where events/s peaks, delivery is only 33%. The 7.5M events/s figure means the fan-out loop is working hard — but a lot of those sends are dropping into the `default` case because subscriber channels are full. The subscriber channel (8 slots) fills when the SSE write can't keep up with the broadcast rate.

<div class="journal-callout finding">
<strong>Finding</strong>
The in-process ceiling is CPU contention between the write path and the fan-out goroutines, not fan-out iteration speed. Sharding the fan-out loop is the obvious next step — but it only helps if that's the actual bottleneck.
</div>

Next: shard each topic's fan-out across N goroutines. If delivery% improves, iteration was the limit. If it doesn't, it was CPU contention all along.
