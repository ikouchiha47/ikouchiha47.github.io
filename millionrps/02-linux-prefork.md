---
layout: journal_entry
title: "linux confirms it: SO_REUSEPORT actually works"
subtitle: "c6i.2xlarge, cross-machine, P99 drops from 22ms to 1.4ms"
group: millionrps
group_title: "chasing 1 million rps"
group_url: "/millionrps/"
entry_date: 2026-06-01
status: done
tags: [linux, aws, c6i, SO_REUSEPORT, prefork, vegeta, terraform]
summary: "Two c6i.2xlarge on AWS. Server: fiber+prefork 8 workers. Client: vegeta. Confirm SO_REUSEPORT distributes connections across all 8 workers on Linux. Compare P99 against macOS."
result: "P99: 22ms (macOS) → 1.4ms (Linux). All 8 workers active. Still bandwidth-bound at 8-13k RPS with 48KB payloads. /read-only hits 49k RPS — server at 3% CPU, client NIC is the ceiling."
---

## setup

Two `c6i.2xlarge` (8 vCPU Intel Ice Lake, 16GB RAM, 12.5 Gbps NIC) in the same subnet (`ap-south-2c`). Provisioned via Terraform.

Server kernel tuning applied via `user_data` on boot:

```bash
# /etc/sysctl.conf
net.core.somaxconn=65535
net.core.netdev_max_backlog=65535
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
```

```bash
# file descriptor limit
echo '* soft nofile 1048576' >> /etc/security/limits.conf
echo '* hard nofile 1048576' >> /etc/security/limits.conf
```

Server: fiber v3, `EnablePrefork: true` → 8 child workers.

Client tool: vegeta v12.11.1.

```bash
# vegeta targets file (60% /read, 40% /list)
GET http://SERVER_INTERNAL_IP:8083/read
GET http://SERVER_INTERNAL_IP:8083/read
GET http://SERVER_INTERNAL_IP:8083/read
GET http://SERVER_INTERNAL_IP:8083/read
GET http://SERVER_INTERNAL_IP:8083/read
GET http://SERVER_INTERNAL_IP:8083/read
GET http://SERVER_INTERNAL_IP:8083/list
GET http://SERVER_INTERNAL_IP:8083/list
GET http://SERVER_INTERNAL_IP:8083/list
GET http://SERVER_INTERNAL_IP:8083/list

# attack
vegeta attack \
  -rate=100000 \
  -duration=30s \
  -targets=targets.txt \
  -workers=100 \
  -max-workers=500 \
  | tee >(vegeta report -type=json > results.json) \
  | vegeta report
```

Note: binary `.bin` files written to `/tmp` and deleted after each run to avoid filling disk. At 1M RPS target × 30s = 30M result entries = ~3GB per binary.

## SO_REUSEPORT confirmed working

On macOS: all 10 workers at 0% CPU, parent handling everything.

On Linux: **all 8 workers showing activity**. Connections distributed by the kernel.

```
# htop during benchmark — Linux (fiber prefork, 8 workers)
PID    CPU%
15876  14.1%  ← parent
15878   0.0%  ← worker (on macOS, all workers look like this)
...

# Linux: workers are actually active
PID    CPU%
worker1  12.5%
worker2  12.5%
worker3  18.8%
...all 8 workers 6-19% CPU
```

<table class="bench-table">
  <thead><tr><th>Platform</th><th>Active workers</th><th>P50</th><th>P99</th><th>Avg RPS</th></tr></thead>
  <tbody>
    <tr><td>macOS (prefork)</td><td class="bottleneck">1 of 10</td><td>5.5ms</td><td>22ms</td><td>~13k</td></tr>
    <tr><td class="highlight">Linux (prefork)</td><td class="highlight">8 of 8</td><td class="highlight">0.24ms</td><td class="highlight">1.4ms</td><td>~8.4k</td></tr>
  </tbody>
</table>

Same payload (48KB avg), different latency. The macOS 22ms P99 was 10 goroutines serialized through one process. Linux has genuine parallelism.

## actual vegeta results (48KB mixed workload, c6i.xlarge client)

```
# from fiber-linux/metrics.csv
target_rps, actual_rps, p50_ms, p90_ms, p95_ms, p99_ms
100000,      8271,       0.2422, 0.4285, 0.5961, 1.4332
200000,      8481,       0.2412, 0.4208, 0.5728, 1.4389
500000,      8448,       0.2398, 0.4248, 0.5792, 1.4274
1000000,     8350,       0.2416, 0.4202, 0.5696, 1.3683
1500000,     8257,       0.2419, 0.4274, 0.5893, 1.4615
```

Flat at ~8.4k RPS regardless of target (100k through 1.5M). The server never saturates — the ceiling is the **client NIC**:

```
8,400 RPS × 48KB avg response = 403 MB/s = 3.2 Gbps
c6i.xlarge NIC capacity: 4.7 Gbps
→ 68% of client NIC saturated
```

## /read only — removing the bandwidth bottleneck

Switching to `/read` only (~4KB response, single product):

```bash
echo "GET http://SERVER_INTERNAL_IP:8083/read" | \
  vegeta attack -rate=500000 -duration=30s -workers=500 | \
  vegeta report
```

```
Requests/sec: 49,092
Mean response: 4,522 bytes
P50: 0.25ms   P99: 3.6ms
Throughput: ~213 MB/s
```

3.7× more RPS. Server CPU avg: **3% across all 8 cores**. The server has huge headroom.

The c6i.2xlarge (second run, both machines upgraded) with 48KB:

```
# from fiber-prefork/metrics.csv (c6i.2xlarge client)
actual_rps: 10,982 - 14,945 (varies by target)
p50_ms: 4.9 - 8.6
p99_ms: 20 - 23ms
```

Higher than c6i.xlarge client because 12.5 Gbps > 4.7 Gbps NIC. Still client-bound.

<div class="journal-callout finding">
  <strong>Finding</strong>
  At 49k RPS on /read, server CPU is 3% avg. The rate-controlled vegeta benchmark measures the client's bandwidth ceiling, not the server's compute ceiling. Cross-machine benchmarks need the client to be at least as fast as the server you're testing.
</div>

## what we learned about the benchmark tool

vegeta sends one request per worker slot and waits for the response — classic request/response. This is rate-controlled and measures latency distributions accurately.

There's a different mode of operation: **HTTP pipelining** — sending N requests on the same TCP connection before waiting for responses. With `autocannon --pipelining 100` and 1000 connections, you have **100,000 requests in flight simultaneously**. That's a throughput test — the latency numbers are bulk averages across the pipeline, not individual request latency.

These are different measurements. vegeta at 100k target = 100k requests per second with clean latency histograms. autocannon at pipelining 100 = maximum throughput with the server never idle.

## what needs to be seen next

The server is barely loaded. To find its actual ceiling:

1. A client that can generate more requests than the server can handle — currently the client saturates first
2. autocannon with pipelining to push raw throughput
3. A bigger server (more cores) — c8i.32xlarge with 128 vCPU and 50 Gbps NIC
