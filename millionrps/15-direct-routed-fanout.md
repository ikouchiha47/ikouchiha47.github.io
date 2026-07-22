---
layout: journal_entry
title: "Direct-routed SSE fan-out: process separation regressed 60%, aggregation is the fix"
subtitle: "Separate registry, fanout-node, and likes-server binaries with consistent-hash routing. HTTP POST per event is 500× more expensive than an in-process channel send."
group: millionrps
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
chapter: 2
chapter_title: "Fan-out"
entry_date: 2026-07-16
status: done
tags: [SSE, fan-out, dispatcher, registry, process-separation, IPC, HTTP-push, aggregation]
summary: "Checkpoint 6: split the monolith into three binaries (likes-server, registry, fanout-node) with consistent-hash routing. likes-server resolves owning node via a local ring cache and enqueues events to a per-node buffered channel. Background goroutine drains via HTTP POST. Fire-and-forget — write path never blocks on fan-out."
result: "Events/s regressed ~60% vs CP5 at all connection counts except 64K (−5%). Root cause: HTTP POST per event costs ~50µs vs ~100ns for an in-process channel send. Research into Ably, Discord, and YouTube revealed nobody fans out individual increments — they aggregate over a 50–200ms window. At 100ms batching, 23K events/s collapses to ~10 fan-out publishes/s per post. The architecture is correct. The event shape is wrong."
---

Source code: [ikouchiha47/gothun](https://github.com/ikouchiha47/gothun) — `src/likes/`

## what checkpoints 4 and 5 proved

The in-process ceiling is ~7.5M events/s at 20K SSE connections. It doesn't matter whether fan-out uses 1 goroutine or 8 per topic — the number barely moves. The write path and the fan-out goroutines are on the same process competing for CPU. The OS scheduler doesn't know which one matters more.

The obvious move: separate them. Give the write path its own process. Give fan-out its own process. Let the OS schedule them independently. Connect them with something fast.

That's what checkpoint 6 built.

## three binaries

```
┌─────────────┐   POST /push    ┌──────────────┐   SSE stream
│ likes-server│ ─────────────── │  fanout-node  │ ─────────────▶ subscribers
│   (:8083)   │                 │    (:8084)    │
└──────┬──────┘                 └──────┬────────┘
       │ GET /node?post_id=X           │ POST /register
       │                        ┌──────▴──────┐
       └──────────────────────▶ │   registry   │
                                 │   (:8085)   │
                                 └─────────────┘
```

**`registry`** — consistent hash ring (FNV32, sorted node list). Fanout-nodes register on startup, deregister on shutdown. Persists state to a flat JSON file. HTTP API: `GET /node?post_id=X`, `POST /register`, `DELETE /register`.

**`fanout-node`** — holds SSE connections (`GET /stream/:postID`). Receives push events via `POST /push` with `{"post_id":"...","count":N}`. Calls `hub.Publish()` into the existing sharded hub, which fans to local SSE subscribers. Registers itself with the registry on startup.

**`likes-server`** — write path only (fasthttp). After incrementing the counter, resolves the owning fanout-node via a local ring cache (one FNV32 hash — no network call on the hot path). Enqueues the push to a buffered per-node channel (512 slots). A background goroutine drains the channel via HTTP POST to the fanout-node. Fire-and-forget: the write path returns before the push completes.

This is the **dispatcher pattern**: likes-server is the dispatcher, registry owns the routing map, fanout-nodes are the realtime messaging servers.

## what the code looks like

Ring cache on the write side — the registry is only consulted at startup and when a node registers or deregisters:

```go
type NodeRing struct {
    mu    sync.RWMutex
    nodes []string       // sorted FNV32 hash → address
    ring  map[uint32]string
}

func (r *NodeRing) Resolve(postID string) string {
    h := fnv32(postID)
    r.mu.RLock()
    defer r.mu.RUnlock()
    // binary search for first node >= h (wrap around)
    ...
}
```

Per-node send channels with a background drainer:

```go
type Dispatcher struct {
    queues map[string]chan PushEvent  // fanout-node addr → buffered chan
    ring   *NodeRing
    drops  atomic.Int64
}

func (d *Dispatcher) Send(postID string, count int64) {
    addr := d.ring.Resolve(postID)
    ch := d.queues[addr]
    select {
    case ch <- PushEvent{PostID: postID, Count: count}:
    default:
        d.drops.Add(1)  // push_dropped counter
    }
}

func (d *Dispatcher) drain(addr string, ch <-chan PushEvent) {
    for ev := range ch {
        httpPost(addr+"/push", ev)  // ~50µs per call
    }
}
```

The fanout-node side is the same sharded hub from CP5 — `hub.Publish()` routes to the right shard, shard goroutine iterates subscriber slice.

## results

<div class="bench-table-wrap">
<table class="bench-table">
<thead><tr><th>SSE Connections</th><th>Events/s</th><th>Delivery%</th><th>Write inc/s</th><th>Push Dropped</th><th>RSS</th><th>FDs</th></tr></thead>
<tbody>
<tr><td>2,000</td><td>1,809,297</td><td>39.3%</td><td>23,021</td><td>412,088</td><td>322 MB</td><td>2,009</td></tr>
<tr><td>10,000</td><td>2,782,320</td><td>23.0%</td><td>12,123</td><td>277,996</td><td>687 MB</td><td>10,008</td></tr>
<tr><td>20,000</td><td>2,654,385</td><td>11.0%</td><td>12,022</td><td>319,901</td><td>1,145 MB</td><td>20,008</td></tr>
<tr><td>64,000</td><td>2,457,384</td><td>3.2%</td><td>11,840</td><td>343,507</td><td>3,082 MB</td><td>64,008</td></tr>
</tbody>
</table>
</div>

500 goroutines writing to 10 posts round-robin. `push_dropped` = events dropped at likes-server because the per-node send channel (512 slots) was full.

## vs checkpoint 5

<div class="bench-table-wrap">
<table class="bench-table">
<thead><tr><th>SSE Connections</th><th>Events/s CP5</th><th>Events/s CP6</th><th>Delta</th></tr></thead>
<tbody>
<tr><td>2,000</td><td>4,452,394</td><td>1,809,297</td><td>−59%</td></tr>
<tr><td>10,000</td><td>6,682,850</td><td>2,782,320</td><td>−58%</td></tr>
<tr><td>20,000</td><td>7,543,145</td><td>2,654,385</td><td>−65%</td></tr>
<tr><td>64,000</td><td>2,599,775</td><td>2,457,384</td><td>−5%</td></tr>
</tbody>
</table>
</div>

<div class="journal-callout warning">
<strong>Warning</strong>
Process separation regressed events/s by ~60% at every connection count except 64K. The architecture is better. The numbers are worse.
</div>

## why it got slower

At 23K inc/s, the likes-server fires 23K HTTP POST requests per second to the fanout-node. Each POST carries:

- JSON encode of `{post_id, count}`
- TCP write + kernel copy
- HTTP headers (request + response)
- Response wait (even 200 OK takes ~50µs RTT on the same VPC)

**~50µs per event** vs **~100ns for an in-process channel send**. That's 500× more expensive per unit of work.

The 512-slot push channel fills because fanout-node is simultaneously trying to serve N SSE writes. When the drainer goroutine is blocked waiting on an HTTP response, events pile up on the send channel faster than they drain. `push_dropped` runs at 300–400K events per measurement phase.

There are now **two drop points** instead of one:

1. `push_dropped` at likes-server — the per-node channel is full
2. Shard channel drops at fanout-node — subscriber channels full, same failure mode as CP5

The 64K result is a near-tie (−5%) because at 64K SSE connections, CP5 was already collapsing under its own fan-out iteration time. Both checkpoints hit the same floor from different directions.

<div class="journal-callout finding">
<strong>Finding</strong>
The IPC mechanism (HTTP POST) costs ~500× more than in-process channels. Switching to gRPC streaming reduces per-call overhead but doesn't change the fundamental problem: we're still dispatching one message per increment. At 23K inc/s, even a 5µs RPC still generates 115ms of serial IPC work per second per drainer goroutine.
</div>

## what real systems actually do

After the regression, I looked at how production fan-out systems handle this. The answer is consistent across Ably, Discord, and YouTube Live.

**Nobody fans out individual increments.**

- **Ably** publishes presence/count updates on a 100–200ms aggregation window. Individual state changes within the window are collapsed — subscribers receive the final value, not every transition.
- **Discord** coalesces typing indicators and member-count updates over a 5s window before broadcasting. The websocket message carries the current count, not a delta per event.
- **YouTube Live** updates concurrent viewer counts on a 5–10s server-side ticker. The counter increments millions of times per second; the fan-out rate is once per tick per channel.

The insight: **like counts are not a reliable stream**. Viewers don't need every intermediate value. They need the current value, refreshed fast enough to feel live (~100ms is imperceptible). The semantics are "here is the count right now," not "here is every individual increment."

At a 100ms aggregation window with 10 posts:

- 23K inc/s across 10 posts = 2,300 increments/post/second
- 100ms window = 230 increments accumulated per post per flush
- Fan-out dispatches = 10 posts × 10 flushes/s = **100 publishes/s**

100 HTTP POSTs/s is trivially cheap. The drainer goroutine is idle 99% of the time. The push channel never fills. `push_dropped` goes to zero.

The 2,300x reduction in fan-out work means the IPC transport is irrelevant. HTTP, gRPC, Unix socket — it doesn't matter at 100 calls/second.

<div class="journal-callout finding">
<strong>Finding</strong>
The dispatcher→registry→fanout-node architecture is correct. The event shape is wrong. Aggregation before dispatch eliminates the IPC bottleneck without changing the transport layer.
</div>

## what comes next

Checkpoint 7: **aggregation tier inside likes-server**.

A `CountAggregator` accumulates increments per postID in memory. A ticker fires every 100ms and flushes the current snapshot — `map[postID]currentCount` — one POST per fanout-node per tick. The drainer goroutine sends one batched payload instead of one payload per increment.

Expected result: push_dropped → 0. Write throughput restores to pre-fan-out levels. Delivery% should recover to CP5 range or better, since the fanout-node is no longer saturated by incoming push load while trying to serve SSE writes.

The shard channel drop rate at fanout-node is still a question — we'll see whether the subscriber side becomes the new limit once the push side is no longer the problem.
