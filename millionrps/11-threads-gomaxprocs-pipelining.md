---
layout: journal_entry
title: "Three things that don't move /read past the NIC"
subtitle: "Thread count is flat across 50× load. 32 workers tie 128. Pipelining does nothing. The NIC is the wall."
group: millionrps
chapter: 1
chapter_title: "Simple HTTP"
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
entry_date: 2026-06-11
status: done
tags: [threads, netpoller, GOMAXPROCS, pipelining, NIC, bandwidth, c8i, c6in]
summary: "/read at 4.5KB hits 1.32M RPS = 6.1 GB/s = 98% of the 50 Gbps NIC. Three things that should plausibly raise it, don't: per-worker thread count is flat across 100c-5000c (epoll), 32 workers match 128 workers (NIC-bound), and pipelining 1→50 stays flat. The same pipelining sweep on /simple (16B) goes 4.4M → 17M, because that endpoint is packet-bound, not bandwidth-bound."
result: "Per-worker threads: ~10 (c6in) / ~15 (c8i), flat across 50× connection range. 32 vs 128 workers on c8i /read: 1,322,240 vs 1,322,291 RPS — identical. Pipelining 1→50 on /read: flat ~1.33M. On /simple: 4.4M → 16.9M. The /read ceiling is NIC bandwidth at every angle."
---

## the setup for all three

`/read` returns a pre-serialized 4.5KB product. On c8i.32xlarge (128 cores, 50 Gbps) it peaks at 1.32M RPS. Check the bandwidth: `1.32M × 4.5KB = 5.94 GB/s`. The NIC ceiling is `50 Gbps = 6.25 GB/s`. We are at **95% of line rate** at the peak operating point.

That number reframes everything. If the NIC is the wall, then anything that doesn't add bandwidth can't add RPS. Three plausible-sounding levers, measured against that wall.

## 1. thread count is independent of connection load

Measured per-worker OS thread count (`nlwp`) during live benchmarks at increasing connection counts, c6in.8xlarge, 32 prefork workers:

```bash
# during each benchmark point, on the server:
ps -eo nlwp,comm | awk '/fiber_server/{sum+=$1;n++} END{printf "avg %.1f threads/worker\n",sum/n}'
```

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>conn/worker</th><th>workers</th><th>threads/worker (avg)</th></tr>
  </thead>
  <tbody>
    <tr><td>100</td><td>~3</td><td>32</td><td>10.1</td></tr>
    <tr><td>500</td><td>~16</td><td>32</td><td>10.1</td></tr>
    <tr><td>1,000</td><td>~31</td><td>32</td><td>10.1</td></tr>
    <tr><td>5,000</td><td>~156</td><td>32</td><td>10.1</td></tr>
  </tbody>
</table>
</div>

3 connections per worker or 156 — the thread count does not move. A 50× change in load, flat at 10.1.

Connections are goroutines, not threads. A goroutine waiting on network I/O is parked in the netpoller (epoll) and consumes zero threads — the runtime hands its OS thread back to run other work. One `epoll_wait` watches all 156 fds at once. A thread is only consumed by a goroutine actually executing or stuck in a blocking syscall right now.

With `--pipelining 1`, each connection is idle almost the whole time — one request, wait for the round trip, repeat. Little's Law on a worker at 5000c:

```
~686k RPS / 32 workers           = 21,400 RPS/worker
service time per request         ≈ 34µs  (85% CPU × 32 cores / 800k RPS)
in-flight, actually on a thread  = 21,400 × 34µs = 0.73 requests
```

Less than one request per worker is on a thread at any instant. The other ~155 connections sit in epoll for free. Open ≠ active. That is why 3 and 156 connections give the identical thread count — the parked majority costs nothing.

The 10 threads break down as ~1 running the handler, plus sysmon, GC workers, finalizer, and a few M's lingering from bursts. Not connection-driven, not a tuning surface.

## 2. 32 workers tie 128 workers

[Entry 10](../10-gomaxprocs-prefork/) established that fiber's worker count equals `GOMAXPROCS`. So `GOMAXPROCS=32` on the 128-core c8i spawns 32 workers; the default spawns 128. Same hardware, same `/read`, 1000 connections:

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>config</th><th>workers</th><th>threads/worker</th><th>RPS (1000c)</th></tr>
  </thead>
  <tbody>
    <tr><td>GOMAXPROCS=128</td><td>128</td><td>~15</td><td>1,322,291</td></tr>
    <tr><td>GOMAXPROCS=32</td><td>32</td><td>~11</td><td>1,322,240</td></tr>
  </tbody>
</table>
</div>

Identical. 51 RPS apart on 1.32M — noise. 96 fewer workers, same throughput, because `/read` is NIC-bound. 32 workers already push 6.1 GB/s; the NIC has nothing left for the other 96 to do. They are idle capacity.

This also kills the "thread count tracks GOMAXPROCS" idea from a hasty earlier read. Both configs run children at `GOMAXPROCS(1)` (fiber forces it — [entry 10](../10-gomaxprocs-prefork/)). The ~15 vs ~11 difference is sampling noise on syscall-blocked M's, not a GOMAXPROCS effect. The c6in value (~10) lands in the same band. Per-worker threads are the GOMAXPROCS=1 runtime floor on all three.

## 3. pipelining does nothing for /read, everything for /simple

`--pipelining N` sends N requests per connection without waiting between them, amortizing per-request packet and syscall overhead. c8i, 128 workers, 1000 connections:

**/read (4.5KB):**

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>pipelining</th><th>RPS</th><th>throughput</th><th>NIC %</th></tr>
  </thead>
  <tbody>
    <tr><td>1</td><td>1,322,291</td><td>6.13 GB/s</td><td>98%</td></tr>
    <tr><td>10</td><td>1,349,120</td><td>6.25 GB/s</td><td>100%</td></tr>
    <tr><td>20</td><td>1,339,289</td><td>6.21 GB/s</td><td>99%</td></tr>
    <tr><td>50</td><td>1,340,654</td><td>6.21 GB/s</td><td>99%</td></tr>
  </tbody>
</table>
</div>

Flat. +2% from pipelining 1 to 50, noise. Pipelining reduces per-request packet overhead — but the wall here is bytes, not packets. At pipelining=1 the NIC is already at 98% of line rate. There is no bandwidth to amortize into. You cannot pipeline past the physical bit rate of the wire.

**/simple (16B):**

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>pipelining</th><th>RPS</th><th>throughput</th><th>NIC %</th></tr>
  </thead>
  <tbody>
    <tr><td>1</td><td>4,401,493</td><td>0.55 GB/s</td><td>9%</td></tr>
    <tr><td>10</td><td>14,898,653</td><td>1.85 GB/s</td><td>30%</td></tr>
    <tr><td>20</td><td>16,133,324</td><td>2.00 GB/s</td><td>32%</td></tr>
    <tr><td>50</td><td>16,947,473</td><td>2.10 GB/s</td><td>34%</td></tr>
  </tbody>
</table>
</div>

3.8×. Same machine, same pipelining sweep, opposite result. `/simple` is 16 bytes — at 17M RPS the NIC is still only 34% used. Bandwidth is irrelevant; the ceiling is packet rate and syscall count. At pipelining=1 every request is its own packet and its own `read`/`write` pair. At pipelining=50, fifty 16-byte requests arrive in one TCP segment and the responses batch out together — the per-request syscall cost is amortized ~50×. RPS climbs until CPU or the client becomes the wall around 17M.

## the rule

Pipelining helps when you are packet-bound. It does nothing when you are bandwidth-bound. The crossover is payload size:

```
/read   : 4.5KB × 1.32M RPS = 5.94 GB/s ≈ NIC ceiling  → bandwidth-bound → pipelining flat
/simple : 16B   × 17M  RPS  = 2.1 GB/s  = 34% of NIC    → packet-bound    → pipelining 3.8×
```

<div class="journal-callout finding">
  <strong>Finding</strong>
  /read on c8i.32xlarge is NIC-bandwidth-bound at 1.32M RPS (98% of 50 Gbps). Three independent levers confirm it: thread count is flat across 50× load (epoll multiplexes idle connections), 32 workers match 128 (no bandwidth left for extra workers), and pipelining 1→50 is flat (no bytes left to amortize). The same pipelining sweep on the 16-byte /simple endpoint goes 4.4M → 17M — proof that pipelining works, just not against a bandwidth wall.
</div>

<div class="journal-callout warning">
  <strong>Why the early "18M RPS" numbers mean nothing for a real API</strong>
  Entries 01-06 hit millions of RPS on /simple with pipelining=100. That is a 16-byte payload, packet-bound, with 50× syscall amortization. A real 4.5KB API response is bandwidth-bound and tops out at ~1.3M on this exact hardware no matter what you do with pipelining, workers, or GOMAXPROCS. The headline number is a function of payload size, not server capability.
</div>

<div class="journal-callout next">
  <strong>What this closes</strong>
  For a 4.5KB response, the 50 Gbps NIC is the ceiling and we are at 98% of it. To go higher you change the bytes on the wire (smaller payload, compression, HTTP/2 header compression) or add NICs (100 Gbps c6in.16xlarge, or multiple instances behind a load balancer). Tuning the server — threads, workers, GOMAXPROCS, pipelining, IRQ pinning — is finished. The wall is physics now, not software.
</div>
