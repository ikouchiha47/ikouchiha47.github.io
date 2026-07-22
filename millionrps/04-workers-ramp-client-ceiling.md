---
layout: journal_entry
title: "2.3M RPS: the --workers flag, connection ramp, and finding the real ceiling"
subtitle: "c6i.8xlarge client, 30 workers, 1000→5000 connections — server at 2%, client at 67%"
group: millionrps
chapter: 1
chapter_title: "Simple HTTP"
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
entry_date: 2026-06-04
status: done
tags: [autocannon, workers, pipelining, c8i, c6i, ramp, client-ceiling]
summary: "Discovered --workers flag in autocannon. Upgraded client to c6i.8xlarge. Ran connection ramp 1000→2000→5000. Hit 2.3M RPS at p50 38ms. Proved server has 98% CPU headroom — client is the ceiling at 67% avg CPU across 32 cores."
result: "2,299,162 RPS avg. Server: 2.25% CPU, 236 MB/s TX (3.8% of 6250 MB/s ceiling). Client: 67% avg CPU, 28.2/32 cores consumed. Client is the wall."
---

## what changed from last run

Last run used autocannon without `--workers`. The command was:

```bash
autocannon --connections 1000 --pipelining 100 --duration 30 \
  "http://SERVER_INTERNAL_IP:8083/simple"
```

One Node.js event loop, one thread. At 1000 connections it managed 200k RPS, then hit 4.9M at 2000 connections — but at **p50 1225ms**. A response with 1225ms latency at "4.9M RPS" means requests were sitting in the pipeline for over a second before being counted. The event loop was batching and counting a backlog flush, not measuring steady-state throughput.

The correct command — visible in reference benchmarks — uses `--workers`:

```bash
autocannon --connections 1000 --pipelining 100 --workers 120 --duration 30 \
  "http://SERVER_INTERNAL_IP:8083/simple"
```

`--workers N` spawns N Node.js worker threads, each with its own event loop. Each thread manages `connections/N` TCP connections independently. Less batching overhead, proper per-request accounting, honest latency numbers.

The difference:

| approach | connections | RPS | p50 latency |
|----------|-------------|-----|-------------|
| no workers | 2000 | 4,913,152 | 1225ms |
| 30 workers | 1000 | 2,299,162 | 38ms |

The 4.9M number was a measurement artifact. The 2.3M with p50 38ms is the real server throughput.

## setup

| Role | Instance | vCPU | RAM | Network | Interface |
|------|----------|------|-----|---------|-----------|
| Server | c8i.32xlarge | 128 | 256 GB | 50 Gbps | enp95s0 |
| Client | c6i.8xlarge | 32 | 64 GB | 25 Gbps | ens5 |

Server: fiber v3, prefork, 128 workers.

**Server prep — applied once at boot via `server_setup.sh`:**

```bash
# stop irqbalance — it continuously reassigns NIC IRQs and will undo any manual affinity
sudo systemctl stop irqbalance
sudo systemctl disable irqbalance

# RPS/RFS — distribute softirq processing across all 128 cores
NIC=$(ip route show default | awk '/default/{print $5}')  # enp95s0 on c8i

for f in /sys/class/net/$NIC/queues/rx-*/rps_cpus; do
    echo "ffffffff,ffffffff,ffffffff,ffffffff" | sudo tee $f > /dev/null
done

echo 32768 | sudo tee /proc/sys/net/core/rps_sock_flow_entries > /dev/null

for f in /sys/class/net/$NIC/queues/rx-*/rps_flow_cnt; do
    echo 2048 | sudo tee $f > /dev/null
done
```

**Build and start the server:**

```bash
export PATH=$PATH:/usr/local/go/bin
cd /opt/millionrps/src/http
go build -o fiber_server fiber_server.go
nohup ./fiber_server > /tmp/fiber.log 2>&1 &
```

**Run benchmark from client (`autocannon_bench.sh`):**

```bash
# ./autocannon_bench.sh <server-ip> [pipelining] [duration_sec] [workers] [route]
./autocannon_bench.sh SERVER_INTERNAL_IP 100 30 30 simple
```

The script runs three connection points (1000 → 2000 → 5000) in sequence. Workers default to `$(nproc) - 2` — on c6i.8xlarge that's 30.

Workers auto-detected on client: `nproc - 2 = 30`.

## results

Connection ramp — 30 workers, pipelining 100, 30s per point, `/simple` endpoint:

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>in-flight</th><th>workers</th><th>RPS</th><th>p50 ms</th><th>p99 ms</th><th>throughput MB/s</th></tr>
  </thead>
  <tbody>
    <tr class="highlight"><td>1000</td><td>100,000</td><td>30</td><td>2,299,162</td><td>38</td><td>89</td><td>285</td></tr>
    <tr><td>2000</td><td>200,000</td><td>30</td><td>2,073,538</td><td>94</td><td>193</td><td>257</td></tr>
    <tr><td>5000</td><td>500,000</td><td>30</td><td>2,229,002</td><td>240</td><td>527</td><td>276</td></tr>
  </tbody>
</table>
</div>

Wide ramp to confirm ceiling (20s per point):

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>RPS</th><th>p50 ms</th><th>p99 ms</th></tr>
  </thead>
  <tbody>
    <tr><td>100</td><td>2,502,131</td><td>3</td><td>8</td></tr>
    <tr><td>500</td><td>2,480,602</td><td>17</td><td>43</td></tr>
    <tr class="highlight"><td>1000</td><td>2,324,877</td><td>38</td><td>97</td></tr>
    <tr><td>2000</td><td>2,026,159</td><td>95</td><td>229</td></tr>
    <tr><td>5000</td><td>2,187,676</td><td>241</td><td>697</td></tr>
    <tr><td>10000</td><td>2,490,096</td><td>485</td><td>1532</td></tr>
  </tbody>
</table>
</div>

RPS is flat across a 100× range of connections — 2.3–2.5M regardless of whether the client opens 100 or 10,000 connections. The server scales fine; the client has hit its own ceiling.

## where the server actually is

Metrics captured live during the 2000c benchmark point:

```
Server CPU (mpstat -P ALL 1 1):
  AVG  usr: 2.25%  sys: 2.27%  idle: 93.75%
  ~80 of 128 cores active at 1-8% each

Server NIC:
  TX: 236 MB/s  (3.8% of 6250 MB/s ceiling)
  RX: 138 MB/s

TCP established on :8083:
  ~2000 connections

Softirq drops: 0
```

The server is using 6% of its CPU and 4% of its NIC. It has not been loaded at all.

## NIC interrupt distribution

After irqbalance was stopped, the ENA driver's default IRQ affinity placed the 16 queues on two CPU clusters:

```
enp95s0-Tx-Rx-0   → CPU91   (3,113,306 interrupts)
enp95s0-Tx-Rx-1   → CPU92   (3,092,195 interrupts)
enp95s0-Tx-Rx-2   → CPU93   (3,070,023 interrupts)
enp95s0-Tx-Rx-3   → CPU94   (3,058,050 interrupts)
enp95s0-Tx-Rx-4   → CPU95   (3,100,314 interrupts)
enp95s0-Tx-Rx-5   → CPU96   (3,102,083 interrupts)
enp95s0-Tx-Rx-6   → CPU1    (3,113,160 interrupts)
enp95s0-Tx-Rx-7   → CPU2    (3,080,034 interrupts)
enp95s0-Tx-Rx-8   → CPU3    (3,133,334 interrupts)
enp95s0-Tx-Rx-9   → CPU4    (3,157,158 interrupts)
enp95s0-Tx-Rx-10  → CPU5    (3,115,349 interrupts)
enp95s0-Tx-Rx-11  → CPU6    (3,180,217 interrupts)
enp95s0-Tx-Rx-12  → CPU7    (3,134,267 interrupts)
enp95s0-Tx-Rx-13  → CPU8    (3,085,940 interrupts)
enp95s0-Tx-Rx-14  → CPU9    (3,072,699 interrupts)
enp95s0-Tx-Rx-15  → CPU10   (3,125,071 interrupts)
```

Interrupt counts are equal across all queues — the kernel is distributing connections evenly via SO_REUSEPORT. Hardware interrupts are confined to 16 cores (1-10 and 91-96). RPS/RFS distributes packet processing to the remaining 112 cores in software.

This is the state IRQ pinning will improve: we will explicitly assign these 16 queues to cores 112-127, leaving 0-111 clean for fiber workers.

## where the client actually is

Metrics during the same 2000c point:

```
Client CPU (mpstat -P ALL 1 1):
  AVG  usr: 67.57%  sys: 8.63%  idle: 16.50%
  All 32 cores: 48–79% usr each

Client processes:
  node: SUM_CPU 2823%  (~28.2 cores consumed)

Client NIC:
  RX: 233 MB/s  (7.5% of 3125 MB/s ceiling)
```

67% avg CPU, 28 out of 32 cores fully consumed. The NIC has 92% headroom. The bottleneck is pure CPU — the 30 Node.js worker threads are burning cores.

Testing 60 workers confirmed this: more workers on the same 32 cores caused context switching overhead and RPS dropped to 1.7M at 2000c.

<div class="journal-callout finding">
  <strong>Finding</strong>
  With 30 workers on 32 cores the client hits its CPU ceiling at ~2.3M RPS. The server at this point is at 2.25% CPU and 3.8% NIC. The c6i.8xlarge client cannot measure the server's actual capacity. Every number in this entry is a client measurement, not a server measurement.
</div>

<div class="journal-callout warning">
  <strong>Note on worker count vs core count</strong>
  autocannon workers are I/O-bound, not CPU-bound — they spend most time waiting for responses. But at high connection counts the event loop overhead and epoll syscalls consume enough CPU that 30 workers across 32 cores saturates the machine. Adding more workers beyond core count caused degradation. The right ratio depends on the workload; for this benchmark on c6i.8xlarge, 30 workers was the effective ceiling.
</div>

<div class="journal-callout next">
  <strong>Next</strong>
  Upgrade both machines to c8i.32xlarge (128 cores each). Run 120 workers. Hit 18M RPS on /simple, 1.7M on /compute. Server saturates for the first time — <a href="../05-matched-c8i-18m-rps/">entry 05</a>.
</div>
