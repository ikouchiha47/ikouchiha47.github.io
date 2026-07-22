---
layout: journal_entry
title: "gzip moved the wall, and exposed a lie"
subtitle: "Same gzip cut RPS in half on one client and raised it 32% on another. The 790k 'CPU-bound' ceiling was never real."
group: millionrps
chapter: 1
chapter_title: "Simple HTTP"
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
entry_date: 2026-06-12
status: done
tags: [gzip, compression, bandwidth, NIC, MTU, jumbo-frames, c6in, c8i, client-ceiling]
summary: "Pre-gzipped the /read pool (4520B → 2289B, 1.97x) to cut bytes on a CPU-bound box. With a c6in client gzip HALVED RPS (794k → 418k) — the client was the bottleneck and decompression overloaded it. Swapped to a c8i.32xlarge client and the real /read ceiling appeared: 1.31M RPS, NIC-bound at 90%, not the 790k 'CPU-bound' from entry 08. At that real ceiling gzip raised RPS 32% (1.31M → 1.73M) by halving NIC load and shifting the wall to CPU. MTU was already 9001, so both payloads are a single packet — the gzip win is bytes copied, not syscalls saved."
result: "Compression: 4520B → 2289B (1.97x). c6in client: /read 794,310 vs /read-gz 417,619 — gzip halved it. c8i client: /read 1,311,710 @ 90% NIC (NIC-bound), /read-gz 1,731,000 @ 80% CPU (CPU-bound), +32%. Per-request server CPU: raw 20.1µs, gz 14.8µs. The 'c6in /read = 790k, CPU-bound' from entry 08 was a client-bound artifact."
---

## why this

[Entry 11](../11-threads-gomaxprocs-pipelining/) closed `/read` on c8i as NIC-bandwidth-bound: 4.5KB × 1.32M = 6.1 GB/s ≈ line rate. To go faster you change the bytes on the wire. Three ways to do that on the cost-efficient c6in.8xlarge: bigger frames (fewer header bytes per packet), huge pages (less CPU per request, not bytes), and compression (fewer bytes per response).

One of them was already done for us. `ip link show ens5`: **MTU 9001**. AWS ENA defaults to jumbo frames inside a VPC. Nothing to tune. Remember that number — it decides how much the third lever is worth.

That leaves compression. Pre-gzip the static pool once at startup, serve the bytes with `Content-Encoding: gzip`, zero per-request compression cost.

## setup

```go
var fiberProductPoolGz [fiberPoolSize][]byte
// at startup, alongside the raw JSON pool:
var buf bytes.Buffer
gw, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
gw.Write(fiberProductPoolJSON[i]); gw.Close()
fiberProductPoolGz[i] = append([]byte(nil), buf.Bytes()...)
```

```go
app.Get("/read-gz", func(c fiber.Ctx) error {
    c.Set("Content-Type", "application/json")
    c.Set("Content-Encoding", "gzip")
    return c.Send(fiberProductPoolGz[nextIdx()])
})
```

`/read` (raw) and `/read-gz` (pre-gzipped) live on the same server, same data. A/B at a fixed client config. The startup log prints the ratio:

```
pool: raw avg 4520B  gz avg 2289B  ratio 1.97x
```

1.97x, not the 3x you'd hope. The descriptions are random word salad and the UUIDs and image URLs are high-entropy. gzip halves it. That's all there is.

## first run: gzip made it slower

c6in.8xlarge client, `autocannon -w 32 --pipelining 1`, 500 connections, 20s.

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>endpoint</th><th>RPS</th><th>server CPU</th><th>NIC</th></tr>
  </thead>
  <tbody>
    <tr><td>/read</td><td class="highlight">794,310</td><td>75.4%</td><td>55%</td></tr>
    <tr><td>/read-gz</td><td class="bottleneck">417,619</td><td>39.7%</td><td>15%</td></tr>
  </tbody>
</table>
</div>

Half the throughput. The bytes got smaller and RPS fell off a cliff.

The server CPU also fell — 75% to 40%. That looks like gzip *worked*: less server CPU. It didn't. The server CPU fell because **fewer requests reached it**. Look at where the work went: `Content-Encoding: gzip` means the client decompresses every response. autocannon was already the bottleneck at 794k — the server sat at 75% CPU with the NIC half-empty, waiting on the client. Add decompression to the client's job and it chokes sooner. 418k.

gzip didn't make the server slower. It made the *client* slower, and the client was the wall.

## the lie that surfaced

If the c6in client is the wall at 794k, then 794k was never the server's ceiling. And [entry 08](../08-c6in-read-nic-ceiling/) called c6in `/read` "790k, CPU-bound at 85%." That was the same weak client. We measured the load generator, not the server.

Swap the client for a c8i.32xlarge — 128 vCPU, four times the cores. Ramp `/read` (raw), `-w 64`:

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>RPS</th><th>server CPU</th><th>NIC</th></tr>
  </thead>
  <tbody>
    <tr><td>200</td><td>817,852</td><td>69.7%</td><td>53%</td></tr>
    <tr><td>350</td><td>1,128,260</td><td>80.3%</td><td>78%</td></tr>
    <tr><td>500</td><td>1,309,321</td><td>83.1%</td><td>89%</td></tr>
    <tr><td>1000</td><td class="highlight">1,326,524</td><td>83.4%</td><td>90%</td></tr>
  </tbody>
</table>
</div>

c6in `/read` does **1.33M**, not 790k. And the wall is the NIC at 90% — `1.33M × 4520B = 6.0 GB/s ≈ 50 Gbps`. Same bandwidth wall c8i hit in [entry 11](../11-threads-gomaxprocs-pipelining/). The "CPU-bound" story was a client-bound artifact. The 32-core box is bandwidth-bound on `/read`, same as the 128-core box, because the payload and the NIC are the same on both.

## then gzip does the thing it is for

Now the wall is bandwidth, and gzip halves the bandwidth. c8i client, `-w 96`, 1000 connections, reproduced:

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>endpoint</th><th>RPS</th><th>server CPU</th><th>NIC</th><th>bound by</th></tr>
  </thead>
  <tbody>
    <tr><td>/read</td><td>1,311,710</td><td>82.5%</td><td class="bottleneck">90.1%</td><td>NIC</td></tr>
    <tr><td>/read-gz</td><td class="highlight">1,721,105</td><td>79.9%</td><td>60.8%</td><td>CPU</td></tr>
    <tr><td>/read-gz</td><td class="highlight">1,741,517</td><td>80.5%</td><td>61.7%</td><td>CPU</td></tr>
  </tbody>
</table>
</div>

**+32%.** 1.31M → 1.73M. gzip halved the bytes, the NIC load dropped from 90% to 61%, the bandwidth wall is gone, and RPS climbs until it hits the next wall — CPU at 80%. gzip didn't make the server faster. It **moved the bottleneck from the NIC to the CPU**, and the CPU sits higher.

(Same gzip, opposite of the first run. There the client was the wall and gzip overloaded it. Here the client has 128 cores to spare and the wall is bandwidth, which gzip relieves. Whether gzip helps or hurts is decided entirely by *what the bottleneck is* and *whether the client can afford to decompress*.)

## why 32% and not 2x

The bytes halved. RPS rose 32%. The gap is two things.

**The NIC was not the only thing near its limit.** At the raw ceiling the NIC was at 90% but CPU was already at 82%. gzip removed the NIC wall; CPU was right behind it. You only get back the headroom between the old wall and the next one.

**MTU 9001 means both payloads are one packet.** The raw response is ~4.7KB, the gz response ~2.4KB, and the MSS is ~8949. Both fit in a single TCP segment. gzip removed *zero* packets and *zero* `write` syscalls. The per-request server saving is only the bytes copied through the write path:

```
per-request server CPU at the ceiling:
  /read     0.825 × 32 cores / 1.31M = 20.1µs
  /read-gz  0.80  × 32 cores / 1.73M = 14.8µs   → 26% cheaper
```

26% less CPU per request — copying 2KB fewer bytes, not skipping a syscall. If the MTU were 1500, the raw response would be 4 packets and gz would be 2, and gzip would have cut packet rate and syscall count too. At 9001 it can't. The jumbo frames that came for free capped the size of this win.

<div class="journal-callout finding">
  <strong>Finding</strong>
  c6in.8xlarge /read is NIC-bandwidth-bound at 1.31M RPS (90% of 50 Gbps), not CPU-bound — the earlier 790k was the load generator's ceiling. Pre-gzip (1.97x) raises the ceiling to 1.73M (+32%) by halving NIC load and shifting the wall to CPU at 80%. Per-request server CPU drops 26% (20.1µs → 14.8µs), all from fewer bytes copied — at MTU 9001 both payloads are a single packet, so no syscalls are saved.
</div>

<div class="journal-callout warning">
  <strong>Two mistakes, one cause</strong>
  Entry 08 called c6in /read "CPU-bound at 790k." It was client-bound — measured with a 32-core c6in client that couldn't generate more load. And the first gzip run "showed" gzip cutting server CPU; it only cut the requests reaching the server, because the same weak client choked on decompression. Both errors come from the same blind spot: not checking who the bottleneck is before reading the result. A benchmark where the client is the wall tells you about the client.
</div>

<div class="journal-callout next">
  <strong>Next</strong>
  /read-gz is now CPU-bound at 1.73M with the NIC at 61% — back in the regime where CPU-per-request tuning pays. The remaining lever from the top of this entry is huge pages: cut TLB misses on the pool, lower CPU per request. The catch — virtualized EC2 reports <code>&lt;not supported&gt;</code> for hardware TLB counters, so the mechanism can't be measured directly, only the RPS that comes out the other end.
</div>
