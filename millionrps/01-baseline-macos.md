---
layout: journal_entry
title: "baseline: mac mini, localhost, three servers"
subtitle: "net/http vs fasthttp vs fiber — what does Go give you out of the box?"
group: millionrps
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
entry_date: 2026-05-15
status: done
tags: [go, fiber, fasthttp, net/http, macos, localhost, wrk]
summary: "Establish a baseline on a Mac mini M2 (10 cores). Compare net/http, fasthttp, and fiber with and without prefork. Measure /read (pool lookup), /list (large payload), and /compute (CPU-bound aggregation)."
result: "fiber+prefork: 201k RPS, P50 0.49ms, P99 0.68ms. /compute: 33k RPS, P50 2.88ms. Payload size — not the server — is the real ceiling."
---

## machine

Mac mini M2, 10 cores (8P + 2E), 16GB RAM, macOS. Benchmark and server on the same machine via loopback.

## what we built

Three servers serving the same routes. All responses come from an in-memory pool generated at startup — no database, no disk, no allocations on the hot path.

**Routes:**
- `/read` — returns one random pre-serialized `Product` JSON from a pool of 500. ~4KB.
- `/list` — returns a pre-serialized batch of 20-30 products. ~100KB.
- `/compute` — takes 100 random products, sorts by price, computes avg/stddev/histogram/top brands, returns aggregated JSON. CPU-bound per request.
- `/simple` — returns `{"message":"hi"}` from a package-level `[]byte`. Zero allocation.

**Product struct** is realistic: UUID, name, brand, category, price, rating, review count, a 5-paragraph description, 5-15 tags, 7 attributes, 3-8 image URLs. One product serializes to ~3-5KB.

## benchmark command

```bash
# wrk with a Lua script mixing /read and /list
wrk -t4 -c100 -d90s --latency --script script_rw.lua http://localhost:8083

# script_rw.lua — 100% /read (used for server comparison)
wrk.method = "GET"
request = function()
  return wrk.format(nil, "/read")
end
```

`-t4` = 4 threads, `-c100` = 100 connections, `-d90s` = 90 second duration.

## server comparison on `/read`

All numbers from `run8.txt`:

```
wrk -t4 -c100 -d90s --latency --script script_rw.lua http://localhost:8083
```

<div class="bench-table-wrap">
<table class="bench-table">
  <thead><tr><th>Server</th><th>RPS</th><th>P50</th><th>P75</th><th>P90</th><th>P99</th></tr></thead>
  <tbody>
    <tr><td>net/http</td><td>93k</td><td>1.02ms</td><td>—</td><td>—</td><td>1.64ms</td></tr>
    <tr><td>fasthttp</td><td>174k</td><td>0.38ms</td><td>—</td><td>—</td><td>1.37ms</td></tr>
    <tr><td>fiber (no prefork)</td><td>175k</td><td>0.40ms</td><td>—</td><td>—</td><td>1.28ms</td></tr>
    <tr><td class="highlight">fiber + prefork (10 workers)</td><td class="highlight">201,777</td><td class="highlight">490µs</td><td>567µs</td><td>617µs</td><td class="highlight">683µs</td></tr>
  </tbody>
</table>
</div>

Actual wrk output for fiber+prefork:

```
Thread Stats   Avg      Stdev     Max   +/- Stdev
  Latency   493.28us  113.56us   8.46ms   72.51%
  Req/Sec    50.70k     2.36k   53.99k    94.53%

18180192 requests in 1.50m, 78.39GB read
Requests/sec: 201777.96
Transfer/sec:      0.87GB
```

prefork's P99 (683µs) is lower than single-process fiber's P99 (1.28ms) despite a slightly higher P50. Load distributed across 10 workers reduces tail spikes from GC pauses.

## `/compute` vs `/read`

```bash
wrk -t4 -c100 -d90s --latency --script script_compute.lua http://localhost:8083
```

Actual wrk output (`run10.txt`):

```
Thread Stats   Avg      Stdev     Max   +/- Stdev
  Latency     2.95ms  785.40us   8.25ms   63.39%
  Req/Sec     8.52k   183.60     9.56k    71.34%

3054303 requests in 1.50m, 1.49GB read
Requests/sec:  33897.44
```

<div class="bench-table-wrap">
<table class="bench-table">
  <thead><tr><th>Route</th><th>RPS</th><th>P50</th><th>P99</th><th>P99/P50 ratio</th></tr></thead>
  <tbody>
    <tr><td>/read (pool lookup)</td><td>175k</td><td>0.40ms</td><td>1.28ms</td><td class="bottleneck">3.2×</td></tr>
    <tr><td>/compute (sort + aggregate 100 items)</td><td>33,897</td><td>2.88ms</td><td>4.68ms</td><td class="highlight">1.6×</td></tr>
  </tbody>
</table>
</div>

`/compute` is 5× slower in RPS but has a **tighter latency distribution** — P99 is only 1.6× P50 vs 3.2× for `/read`. CPU-bound work is predictable: every request does the same sort + aggregation. Near-zero work like `/read` exposes GC pauses and goroutine scheduler jitter that push P99 disproportionately high.

## the payload problem

When we added `/list` (50-100 products, ~350KB per response) to the benchmark mix:

```bash
# 60% /read, 40% /list
vegeta attack -rate=100000 -duration=30s -targets=targets.txt | vegeta report
```

```
# vegeta result at 100k target RPS
Requests/sec:  2,529
Mean response: 48,266 bytes
Throughput:    ~350 MB/s
```

2,529 actual RPS against a 100k target. Not a server problem — the average 48KB response × 2,529 = ~350 MB/s through the loopback. Reducing `/list` to 20-30 products (~48KB avg weighted):

```
# after reducing list batch size
Requests/sec: 8,601
Mean response: 48,266 bytes  
P50: 3.6ms  P99: 20.3ms
```

3.4× more RPS from a config change with no server code changes.

<div class="journal-callout finding">
  <strong>Finding</strong>
  Payload size dominates throughput benchmarks. The server isn't the variable — bandwidth is. At 48KB avg response, the loopback saturates around 8-13k RPS depending on client capacity. Measuring server throughput with large payloads measures network, not compute.
</div>

## prefork on macOS is broken

htop during the vegeta benchmark showed all 10 child workers at **0.0% CPU**. Only the parent process was active (14.1% CPU). `SO_REUSEPORT` on macOS does not distribute TCP connections across prefork workers — all connections go to the parent process, which uses Go's goroutine scheduler to spread across all 10 cores. The children are decorative.

This means the 201k RPS number above is a **single Go process** result, not 10 workers. Linux tests this correctly.

<div class="journal-callout warning">
  <strong>macOS caveat</strong>
  <code>SO_REUSEPORT</code> on macOS was designed for UDP multicast (BSD origin), not TCP load balancing. Any prefork benchmark on macOS is a single-process benchmark in disguise. Confirmed via htop showing 0% CPU on all 10 child processes during load.
</div>
