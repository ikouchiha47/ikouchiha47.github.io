---
layout: journal_entry
title: "128 cores, NIC queues, RPS and RFS"
subtitle: "c8i.32xlarge + autocannon pipelining — server at 1% CPU, client at 82%"
group: millionrps
group_title: "chasing 1 million rps"
group_url: "/millionrps/"
entry_date: 2026-06-02
status: done
tags: [c8i, aws, RPS, RFS, IRQ, autocannon, pipelining, kernel]
summary: "Upgrade server to c8i.32xlarge (128 vCPU). Switch to autocannon with --pipelining 100. Apply RPS and RFS. Capture live metrics during benchmark."
result: "634k avg RPS, peaked 1.2M. Server: 1.14% avg CPU, 96% idle. Client (c6i.4xlarge, 16 cores): 82.93% usr CPU, 0% idle. We also used --connections 1000 — the correct value is 5000. Next run will fix this."
---

## why this run

vegeta sends one request per worker and waits for the response. To measure raw throughput we need requests pipelined — multiple in-flight on the same TCP connection without waiting. That's what autocannon's `--pipelining` does.

With pipelining 100 and 1000 connections: 100,000 requests in flight simultaneously. The server never sits idle waiting for the next request to arrive.

```bash
autocannon -m GET \
  --connections 1000 \
  --duration 30 \
  --pipelining 100 \
  --workers 120 \
  "http://SERVER_INTERNAL_IP:8083/simple"

# --connections 1000  : 1000 concurrent TCP connections
# --pipelining 100    : 100 requests in flight per connection = 100k simultaneous
# --workers 120       : 120 autocannon worker threads
# /simple             : returns {"message":"hi"}, fixed []byte, zero allocation
```

**What we should have done**: ramped connections — 1000 → 2000 → 5000 — to find where the server stops scaling with more in-flight requests. 1000 connections is an arbitrary starting point. With 5000 connections and pipelining 100, you have 500,000 simultaneous in-flight requests — 5× the pressure on the server's accept queue and connection handling. That ramp is the next experiment.

## setup

| Role | Instance | vCPU | RAM | Network | Interface |
|------|----------|------|-----|---------|-----------|
| Server | c8i.32xlarge | 128 | 256GB | 50 Gbps | enp95s0 |
| Client | c6i.4xlarge | 16 | 32GB | 12.5 Gbps | ens5 |

Note: c8i uses `enp95s0`, not `ens5`. This matters for every NIC-related command.

Server: fiber v3, prefork → **128 child workers**. Confirmed:

```bash
grep -E 'Total process|Child PIDs' /tmp/fiber.log

INFO Total process count:  128
INFO Child PIDs:           15819, 15820, 15821, ...
```

## the NIC queue problem

c8i.32xlarge has 128 cores but the ENA NIC supports a maximum of **16 hardware queues**:

```bash
sudo ethtool -l enp95s0

Channel parameters for enp95s0:
Pre-set maximums:
  Combined: 16
Current hardware settings:
  Combined: 16
```

Each queue fires a hardware IRQ on a specific core. Without tuning, only those 16 cores process TCP/IP packets. The other 112 cores handle fiber workers but never see network traffic directly.

## RPS — Receive Packet Steering

```bash
# 128 cores = four 32-bit groups
# Wrong: echo ffffffffffffffffffffffffffffffff (32 chars as one value — kernel rejects it)
# Correct: comma-separated 32-bit groups
for i in /sys/class/net/enp95s0/queues/rx-*/rps_cpus; do
  echo ffffffff,ffffffff,ffffffff,ffffffff | sudo tee $i
done
```

**What it does:** After a hardware IRQ fires on one of the 16 NIC cores, the kernel hashes the packet's flow (src IP + dst IP + src port + dst port) and sends a software interrupt (IPI) to a target core from the bitmask. That core does the TCP/IP processing.

**Result:** All 128 cores can now process TCP packets, not just 16.

**Limitation:** The target core is chosen by hash. It has no knowledge of where the Go goroutine owning that socket is running. Packet processing and goroutine execution may be on different cores → cache miss.

Verify:

```bash
cat /sys/class/net/enp95s0/queues/rx-0/rps_cpus
# ffffffff,ffffffff,ffffffff,ffffffff
```

## RFS — Receive Flow Steering

```bash
# global flow table: track up to 32768 concurrent flows
echo 32768 | sudo tee /proc/sys/net/core/rps_sock_flow_entries

# per-queue: 32768 / 16 queues = 2048 per queue
for i in /sys/class/net/enp95s0/queues/rx-*/rps_flow_cnt; do
  echo 2048 | sudo tee $i
done
```

**What it does:** The kernel maintains a table of (flow hash → last CPU that ran the owning process). When a packet arrives, instead of hashing to a random CPU, it looks up which CPU last ran the goroutine handling that socket and steers there.

**Result:** Packet processing and goroutine execution happen on the same core → hot L1/L2 cache → lower latency.

`rps_sock_flow_entries=32768`: global table size — set to at least your expected concurrent connections.
`rps_flow_cnt=2048`: per-queue entries. Total = `rps_sock_flow_entries`. Here: 2048 × 16 = 32768.

Verify:

```bash
cat /sys/class/net/enp95s0/queues/rx-0/rps_flow_cnt
# 2048

cat /proc/sys/net/core/rps_sock_flow_entries
# 32768
```

## RPS vs RFS: the relationship

They operate at different levels and stack:

```
NIC hardware interrupt → fires on 1 of 16 IRQ cores
    ↓
RPS: hash flow → pick target CPU from bitmask
    ↓
RFS: override with "where did this socket's goroutine last run?"
    ↓
Target CPU processes TCP/IP stack
    ↓
Goroutine wakes up (already on this CPU if RFS worked)
```

IRQ affinity controls the first step — which cores receive hardware NIC interrupts. RPS/RFS control what happens after. These are independent knobs.

## what we did NOT do

We did **not** apply IRQ pinning. `irqbalance` was still running on both machines, randomly reassigning NIC IRQs to different cores. This means our measurements have noise from irqbalance interfering with the manual RPS/RFS configuration.

Stopping irqbalance and pinning NIC IRQs to dedicated cores is the next experiment.

## results

<table class="bench-table">
  <thead><tr><th>Run</th><th>Config</th><th>Avg RPS</th><th>Peak RPS</th><th>P50 latency</th><th>Server CPU avg</th></tr></thead>
  <tbody>
    <tr><td>1</td><td>No RPS/RFS</td><td>542,904</td><td>1,050,623</td><td>163ms</td><td>0.81% usr</td></tr>
    <tr><td>2</td><td>RPS only</td><td>601,234</td><td>1,214,463</td><td>155ms</td><td>1.14% usr</td></tr>
    <tr><td class="highlight">3</td><td class="highlight">RPS + RFS</td><td class="highlight">634,823</td><td class="highlight">1,210,367</td><td class="highlight">147ms</td><td class="highlight">1.14% usr</td></tr>
  </tbody>
</table>

Actual autocannon output (run 3, RPS + RFS):

```
Running 30s test @ http://SERVER_INTERNAL_IP:8083/simple
1000 connections with 100 pipelining factor
120 workers

┌─────────┬──────┬────────┬────────┬────────┬───────────┬───────────┬─────────┐
│ Latency │ 8 ms │ 147 ms │ 377 ms │ 430 ms │ 148.65 ms │ 105.63 ms │ 2277 ms │
└─────────┴──────┴────────┴────────┴────────┴───────────┴───────────┴─────────┘

│ Req/Sec  │ 397,567 │ 608,255 │ 1,204,223 │ Avg: 634,823 │ Stdev: 210,113 │

19765k requests in 30.12s, 2.44 GB read
```

## live server metrics during benchmark (RPS + RFS run)

```bash
# CPU — mpstat -P ALL 1 3 | grep Average
AVG usr:1.14%  sys:1.55%  soft:0.00%  idle:96.12%

# ~85 of 128 cores active (>1% usr)
# NIC IRQ distribution — irqbalance concentrated on 7 cores:
CPU5:  2,411,834 interrupts
CPU7:  2,372,565 interrupts
CPU9:  2,347,442 interrupts
CPU11: 2,428,453 interrupts
CPU18: 2,426,630 interrupts
CPU21: 2,499,716 interrupts
CPU28: 2,380,168 interrupts

# connections on :8083
961 established

# network throughput
RX: 31.4 MB/s   TX: 52.2 MB/s   (50 Gbps NIC = 6250 MB/s capacity)

# softirq drops — zero on all cores
CPU0 total:0000e32c  dropped:00000000
# ...
```

## live client metrics during benchmark

```bash
# CPU — fully saturated
AVG usr:82.93%  sys:5.02%  soft:0.00%  idle:0.00%

# network
RX: 67.1 MB/s   TX: 42.8 MB/s   (12.5 Gbps NIC = 1562 MB/s capacity)
```

<div class="journal-callout finding">
  <strong>Finding</strong>
  Server TX is 52 MB/s out of 6250 MB/s capacity (0.8%). Server CPU is 1.14% avg. The c8i.32xlarge server is trivially loaded. The c6i.4xlarge client with 120 workers across 16 cores is at 82% usr CPU and 0% idle — it is the hard ceiling. Every RPS number in this entry measures the client's limit, not the server's.
</div>

<div class="journal-callout warning">
  <strong>What we should have done</strong>
  Ramped <code>--connections</code> from 1000 → 2000 → 5000 to observe how the server scales with more in-flight requests. 1000 was an arbitrary starting point — at 5000 connections × pipelining 100 = 500,000 simultaneous requests, the server's accept queue and goroutine scheduling face a different pressure profile entirely. That experiment is next.
</div>

<div class="journal-callout next">
  <strong>Next</strong>
  Stop irqbalance. Pin NIC IRQs to dedicated cores. Upgrade client to c8i.32xlarge. Use --connections 5000. Waiting for AWS quota increase to 320 vCPU.
</div>
