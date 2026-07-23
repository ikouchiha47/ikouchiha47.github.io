---
layout: journal_entry
title: "CP6 vs CP6+agg vs CP7: local benchmark on Colima (2000 SSE connections)"
subtitle: "Aggregation alone eliminates all drops and doubles write throughput. The popserver architecture adds another 21% on top."
group: millionrps
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
chapter: 2
chapter_title: "Fan-out"
entry_date: 2026-07-23
status: published
tags: [SSE, fan-out, aggregation, popserver, CP6, CP7, benchmark, local]
summary: "Three-way comparison: CP6 (consistent-hash, per-event) vs CP6+agg (consistent-hash, 100ms window) vs CP7 (popserver K-V, 100ms window). Run locally on Colima 4 vCPU, 16 GB, 1M open-file limit. Aggregation alone eliminates drops and doubles write/s. CP7 popserver adds a further 21%."
result: "CP6: 17,200 write/s, 96.8% drops. CP6+agg: 38,600 write/s, 0% drops. CP7: 46,860 write/s, 0% drops."
---

Source code: [ikouchiha47/gothun](https://github.com/ikouchiha47/gothun) — `src/likes/`

## context

Entry 16 ended with the implementation complete but no numbers — AWS was shut down. This entry runs the benchmark locally to get directional data. Local results aren't AWS-comparable (4 vCPU vs 32, shared resources, virtualization overhead) but they're enough to confirm the architecture works and to quantify the relative gains between checkpoints.

## local test environment

All three checkpoints run on the same machine and the same Colima VM.

**Host:** Apple Silicon (aarch64), macOS  
**Colima config:**

```yaml
cpu: 4
memory: 16   # GiB
arch: aarch64
vmType: vz
docker:
  default-ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
```

**docker-compose per-service:**

```yaml
ulimits:
  nofile:
    soft: 1048576
    hard: 1048576
sysctls:
  net.core.somaxconn: 65535
  net.ipv4.tcp_tw_reuse: 1
```

The 1M file-descriptor limit is necessary — at 2000 SSE connections plus 100 like-writer connections, the default container limit of 1024 causes immediate crashes.

**Load:**
- SSE connections: 2000 (100 per post × 10 posts, all on one fanout-node)
- Like-writers: 100 goroutines hitting `/like/:postID` across 10 posts
- Duration: 20 seconds per phase

**Binaries:**  
- CP6: `cmd/likes-server-cp6`, `cmd/fanout-node-cp6`, `cmd/registry-cp6`  
- CP7: `cmd/likes-server`, `cmd/fanout-node`, `cmd/registry`

CP6 and CP7 live in separate cmd dirs so they can be compared without touching each other's code.

## the three checkpoints

**CP6 (no aggregation):** consistent-hash ring maps `postID → fixed fanout-node`. `likes-server` fires one HTTP POST per increment directly to the owning node. At 17K inc/s, that's 17,000 push operations per second — each contending for a 512-slot buffered channel per node.

**CP6+agg:** same consistent-hash architecture, same binary, but with `-agg-interval 100ms`. The `aggregator` accumulates `postID → latestCount` in a mutex-guarded map and swaps it every 100ms, pushing once per post per tick instead of once per increment.

**CP7 (popserver):** the architecture changes. `fanout-node` registers itself with a K-V registry (`postID → set<nodeAddr>`) when a subscriber connects, and unregisters when they disconnect. `likes-server` at each 100ms flush queries the registry for the live node set per postID and fans out only to those nodes. No static ring; routing is always fresh.

## results

### three-way comparison at 2000 SSE connections

| Checkpoint | arch | agg | write/s | events/s | drop% | flush/s |
|---|---|---|---|---|---|---|
| CP6 | consistent-hash | none | ~17,200 | ~108,700 | **96.8%** | 0 |
| CP6+agg | consistent-hash | 100ms | ~38,600 | 20,000 | **0%** | 10 |
| CP7 | popserver K-V | 100ms | ~46,860 | 20,000 | **0%** | 10 |

### CP6 baseline raw stats

```
increments_total: 342,885
push_dropped:     331,796
flushes_total:    0

like-writer: rps ≈ 17,200/s  (peak 18,524)
sse-client:  events/s ≈ 108,700  delivery: 3.1%
```

The delivery% here is misleading — 108K events/s sounds high but it represents 3.1% of what should have been delivered. 96.8% of pushes were dropped before they reached SSE subscribers.

### CP6+agg raw stats

```
increments_total: 785,573
push_dropped:     0
flushes_total:    200   (200 / 20s = 10/s)

like-writer: rps ≈ 38,600/s  (peak 40,656)
sse-client:  events/s = 20,000  delivery: 0.3%
```

Zero drops. The 200 flushes over 20 seconds is exactly what the math predicts: 10 posts × 100ms interval = 10 flushes/s.

Delivery% of 0.3% reflects the aggregation itself — 785K writes collapsed into 400K SSE events. Each window sends the _latest_ count once; intermediate values are intentionally discarded. Subscribers get the current count at 100ms granularity.

### CP7 reference

```
increments_total: (from cp7_local_bench_20260723.md)
push_dropped:     0
flushes_total:    10/s

like-writer: rps ≈ 46,860/s
sse-client:  events/s = 20,000  delivery: 0.3%
```

Same delivery shape as CP6+agg (zero drops, 100ms granularity), higher write throughput.

## what the numbers tell us

**Aggregation is the load-shaping lever, not the architecture.** The move from CP6 → CP6+agg is the dramatic one:

- Drops: 96.8% → 0%  
- Write throughput: 17,200 → 38,600 (+124%)  
- Push volume to fanout-node: ~17K/s → ~100/s (170× reduction)

This works because like counts are monotonically increasing and subscribers only need the _current_ value, not every intermediate value. Collapsing a 100ms window from 3,800 individual increments per post into a single push is semantically lossless from the subscriber's perspective.

**The popserver architecture then adds 21% on top.** CP6+agg → CP7 brings write/s from ~38,600 to ~46,860. Both flush at the same rate. The difference comes from how the dispatcher routes at flush time:

- CP6+agg: consistent-hash picks a fixed node for each postID regardless of who's watching. Even if no subscribers are connected to that node, a push is sent.
- CP7: the registry query returns only the nodes that have active SSE connections for that postID. If nobody's watching, nothing is sent. The push channel stays empty.

At 2000 SSE connections across 10 posts on a single node, the routing difference is small — the popserver benefit grows as the number of fanout-nodes scales, because most posts will have zero subscribers on most nodes. On AWS with multiple nodes this gap would widen significantly.

## what's still local-only

These numbers confirm direction, not magnitude. Limitations:

- **4 vCPU Colima VM vs 32 vCPU c6in.8xlarge** — everything is CPU-bound sooner
- **Single fanout-node** — the popserver's routing advantage is understated; a multi-node deployment would show a larger gap
- **No NIC saturation testing** — local loopback has no bandwidth ceiling
- **2000 SSE vs 64K SSE** — CP5 showed the shard-channel ceiling at 64K connections; we haven't hit that locally

The open question from entry 16 — whether the hub's shard channel becomes the new ceiling after aggregation removes the push bottleneck — still needs an AWS run to answer.

## code structure

Both checkpoints live in the same repo under separate cmd dirs:

```
src/likes/cmd/
  likes-server-cp6/    # consistent-hash, -agg-interval flag (0=per-event)
  fanout-node-cp6/     # plain SSE hub, no registry integration
  registry-cp6/        # static node list, -nodes flag
  likes-server/        # CP7: popserver dispatcher, 100ms agg
  fanout-node/         # CP7: subTracker ref-counts, auto-register with registry
  registry/            # CP7: postID→set<nodeAddr> K-V store
```

CP6 binaries also use a `/tmp/gothun-cp6` git worktree (detached HEAD at `d40ef17`) which was used during development, but the canonical source is now the `cmd/likes-server-cp6` directory in main.

<div class="journal-callout info">
<strong>Financial constraint — still active</strong>
AWS benchmarking remains paused. The local numbers validate the approach. A proper AWS run (c6in.8xlarge, 32 vCPU, 50 Gbps NIC, 64K SSE connections) would confirm whether CP7's popserver advantage scales up with node count and whether the shard-channel ceiling from CP5 has moved.
</div>
