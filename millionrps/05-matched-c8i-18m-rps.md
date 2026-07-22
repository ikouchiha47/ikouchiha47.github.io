---
layout: journal_entry
title: "18M RPS on /simple, 1.7M on /compute: matched c8i hardware"
subtitle: "c8i.32xlarge × 2, 120 autocannon workers — server at 26% on simple, 94% on compute"
group: millionrps
chapter: 1
chapter_title: "Simple HTTP"
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
entry_date: 2026-06-05
status: done
tags: [c8i, autocannon, workers, compute, simple, client-ceiling, Little's-Law]
summary: "Upgrade both server and client to c8i.32xlarge (128 vCPU, 50 Gbps). Run autocannon with 120 workers. Hit 18M RPS on /simple and 1.7M on /compute. Discover the client is the ceiling for /simple, server is the ceiling for /compute."
result: "18,164,736 RPS on /simple (server 26% CPU). 1,744,862 RPS on /compute (server 94% CPU). For /simple the client is always the wall regardless of hardware."
---

## setup

| Role | Instance | vCPU | RAM | Network |
|------|----------|------|-----|---------|
| Server | c8i.32xlarge | 128 | 256 GB | 50 Gbps |
| Client | c8i.32xlarge | 128 | 256 GB | 50 Gbps |

Server: fiber v3, prefork, 128 workers. RPS/RFS off, irqbalance inactive. No tuning — raw baseline.

Client: autocannon with `--workers 120`. One worker per available core minus a few for system overhead.

## benchmark commands

```bash
# server — build and start
export PATH=$PATH:/usr/local/go/bin
cd /opt/millionrps/src/http
go build -o fiber_server fiber_server.go
nohup ./fiber_server > /tmp/fiber.log 2>&1 &

# client — connection ramp, pipelining 100, 30s per point
autocannon \
  --connections 1000 \
  --pipelining 100 \
  --workers 120 \
  --duration 30 \
  "http://SERVER_INTERNAL_IP:8083/simple"

# full ramp script (1000 → 2000 → 5000 connections)
./autocannon_bench.sh SERVER_INTERNAL_IP 100 30 120 simple
```

## /simple results

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>in-flight</th><th>RPS</th><th>p50 ms</th><th>p99 ms</th><th>throughput MB/s</th></tr>
  </thead>
  <tbody>
    <tr class="highlight"><td>1000</td><td>100,000</td><td>18,164,736</td><td>4</td><td>13</td><td>2252</td></tr>
    <tr><td>2000</td><td>200,000</td><td>17,426,227</td><td>9</td><td>30</td><td>2160</td></tr>
    <tr><td>5000</td><td>500,000</td><td>6,659,743</td><td>69</td><td>211</td><td>825</td></tr>
  </tbody>
</table>
</div>

Live metrics during 1000c point:

```
SERVER (mpstat -P ALL 1 1):
  AVG  usr: 26%   sys: 12%   idle: 56%

SERVER NIC (enp95s0):
  TX: 2252 MB/s   (36% of 6250 MB/s ceiling)

CLIENT:
  AVG  usr: 82%   sys: 9%    idle: 4%
```

## the 5000c drop — Little's Law

RPS drops from 17M at 2000c to 6.6M at 5000c. The server didn't slow down — latency increased.

Little's Law: **RPS = in-flight ÷ latency**

```
1000c:  100k ÷   4ms = 25M theoretical   (actual 18M)
2000c:  200k ÷   9ms = 22M theoretical   (actual 17M)
5000c:  500k ÷  69ms =  7.2M theoretical  (actual 6.6M)  ✓
```

At 5000c, 500k requests are simultaneously queued across 128 workers. Each worker handles ~3900 pipelined requests. The Go runtime scheduler churns, goroutine wake latency grows, TCP buffers fill. p50 jumps from 9ms to 69ms — 8× — which directly explains the RPS drop.

## /compute results

`/compute` builds 100 products from the pool and JSON-serialises them per request — pure CPU work.

```bash
./autocannon_bench.sh SERVER_INTERNAL_IP 100 30 120 compute
```

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>in-flight</th><th>RPS</th><th>p50 ms</th><th>p99 ms</th><th>throughput MB/s</th></tr>
  </thead>
  <tbody>
    <tr><td>1000</td><td>100,000</td><td>1,662,225</td><td>7</td><td>248</td><td>870</td></tr>
    <tr><td>2000</td><td>200,000</td><td>1,686,562</td><td>6</td><td>439</td><td>883</td></tr>
    <tr class="highlight"><td>5000</td><td>500,000</td><td>1,744,862</td><td>6</td><td>1000</td><td>914</td></tr>
  </tbody>
</table>
</div>

Live metrics during 2000c point:

```
SERVER (mpstat -P ALL 1 1):
  AVG  usr: 86%   sys: 1%    idle: 12%
  All 128 cores at 85-100% usr

CLIENT:
  AVG  usr: 7%    sys: 1%    idle: 90%
```

Server saturated, client barely loaded. Opposite of /simple.

## the client ceiling problem

For `/simple`, the server processes a request in ~1-2µs. The client must schedule a goroutine, format the request, send it, receive the response, measure latency, and record stats — ~10-20µs total. The client does 5-10× more work per request than the server.

```
Server ceiling:  ~1µs/req × 128 cores = theoretical ~128M req/s
Client ceiling:  ~15µs/req × 120 workers = ~8M req/s
```

The client ceiling is always lower. No amount of client hardware tuning fixes this for cheap endpoints — you need multiple client machines, or run client and server on the same box (HAProxy approach).

For `/compute`, the balance flips: server spends ~600µs on CPU work, client just waits. Server saturates first.

<div class="journal-callout finding">
  <strong>Finding</strong>
  For network-bound endpoints like <code>/simple</code>, the benchmark client is the bottleneck, not the server. The c8i.32xlarge server at 18M RPS is using 26% CPU and 36% of its NIC. It has not been loaded. For CPU-bound endpoints like <code>/compute</code>, the server saturates first and client metrics become irrelevant.
</div>

<div class="journal-callout next">
  <strong>Next</strong>
  IRQ pinning experiment: pin 16 NIC queues to dedicated cores, run fiber on clean cores, measure whether interrupt isolation changes anything at these load levels.
</div>
