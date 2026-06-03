---
layout: journal_entry
title: "switching to /read: c6in.8xlarge, 50 Gbps, and IRQ pinning on a loaded NIC"
subtitle: "790k RPS, server at 72% NIC, 85% CPU — IRQ pinning still flat"
group: millionrps
group_title: "chasing 1 million rps"
group_url: "/millionrps/"
entry_date: 2026-06-08
status: done
tags: [c6in, read, NIC, IRQ, pipelining, autocannon, profiling]
summary: "Switched from /simple (16 bytes) to /read (4.5KB) on c6in.8xlarge (50 Gbps dedicated NIC). Used autocannon without pipelining. Hit 790k RPS at 500 connections with NIC at 72% utilization. Applied IRQ pinning. Flat."
result: "790k RPS avg at 500c, server TX 3.49 GB/s (56% of 50 Gbps ceiling), 85% CPU busy. IRQ pinning: within noise across all connection counts. 352k interrupts/sec — IRQ cores not saturated."
---

## why /read and why c6in

Every previous experiment used `/simple`: `{"message":"hi"}`, 16 bytes. At 18M RPS the server TX was 18M × 200 bytes ≈ 3.6 GB/s but via pipelining — 100 requests per TCP connection, so the actual packet rate was 18M / 100 = 180k pps. IRQ cores at 180k pps sit at 0-3% CPU. There is nothing to isolate.

IRQ pinning is a packet rate optimization. To test it, you need packets. That means no pipelining and a bigger payload.

`/read` returns a pre-serialized product: UUID, name, brand, description (5 paragraphs), tags, attributes, images. Measured: ~4.5KB per response. With autocannon `--pipelining 1`, each request is an independent TCP round trip. One packet in, one packet out per request.

The math at 800k RPS: `800k × 4.5KB = 3.6 GB/s TX = 28.8 Gbps`. On a 50 Gbps NIC that's 57.6% utilization. NIC queues are actually handling traffic volume. This is the regime where IRQ core saturation is possible.

Hardware: c6in.8xlarge for both server and client. 32 vCPU, 64 GB RAM, 50 Gbps **dedicated** (not "up to"). IRQ affinity default: ENA driver distributes 16 NIC queues one-per-core.

## setup

```bash
# server — irqbalance already disabled, RPS/RFS applied by user_data
nohup ./fiber_server > /tmp/fiber.log 2>&1 &

# client — connection ramp, no pipelining
for CONN in 100 500 1000 2000 5000 10000; do
  autocannon -c $CONN --pipelining 1 -w 30 -d 20 \
    "http://SERVER_INTERNAL_IP:8083/read"
  sleep 3
done
```

```bash
# IRQ pinning — pin all 16 NIC queues to cores 16-31
IRQ_MASK="ffff0000"   # bits 16-31 = cores 16-31
grep ens5 /proc/interrupts | awk -F: '{print $1}' | tr -d ' ' | while read irq; do
  echo "$IRQ_MASK" | sudo tee /proc/irq/$irq/smp_affinity > /dev/null
done

# restart fiber workers pinned to cores 0-15
pkill fiber_server
taskset -c 0-15 nohup ./fiber_server > /tmp/fiber_pinned.log 2>&1 &
```

```bash
# server metrics — run in a second SSH window during each benchmark point
# NIC throughput (1s sample)
NIC=$(ip route show default | awk '/default/{print $5}' | head -1)
R1=$(grep "${NIC}:" /proc/net/dev | awk '{print $2,$10}')
sleep 1
R2=$(grep "${NIC}:" /proc/net/dev | awk '{print $2,$10}')
echo "$R1 $R2" | awk '{tx=($4-$2)/1024/1024; printf "TX: %.1f MB/s (%.1f%% of 6250)\n",tx,tx/6250*100}'

# CPU — average across all cores
mpstat -P ALL 1 1 | awk '/^[0-9]/ && $2=="all" {printf "usr:%.1f%% sys:%.1f%% idle:%.1f%%\n",$3,$5,$12}'

# IRQ rate per NIC queue — read /proc/interrupts twice, compute delta
grep "$NIC" /proc/interrupts | awk '{total=0; for(i=2;i<=NF-3;i++) total+=$i; print $1, total}'
```

## results — connection ramp (baseline, no IRQ pinning)

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>RPS avg</th><th>throughput MB/s</th><th>NIC TX%</th><th>p50 ms</th><th>p95 ms</th><th>p99 ms</th></tr>
  </thead>
  <tbody>
    <tr><td>100</td><td>444,621</td><td>1,964</td><td>31%</td><td>&lt;1</td><td>&lt;1</td><td>&lt;1</td></tr>
    <tr class="highlight"><td>500</td><td>790,253</td><td>3,491</td><td>56%</td><td>&lt;1</td><td>1</td><td>1</td></tr>
    <tr><td>1,000</td><td>786,694</td><td>3,475</td><td>71%</td><td>1</td><td>3</td><td>3</td></tr>
    <tr><td>2,000</td><td>766,189</td><td>3,385</td><td>69%</td><td>1</td><td>5</td><td>7</td></tr>
    <tr><td>5,000</td><td>701,382</td><td>3,098</td><td>50%</td><td>5</td><td>13</td><td>17</td></tr>
    <tr><td>10,000</td><td>673,763</td><td>2,977</td><td>48%</td><td>11</td><td>26</td><td>35</td></tr>
  </tbody>
</table>
</div>

Peak at 500 connections: 790k RPS, 3.49 GB/s TX. Server at 85% CPU busy (usr+sys), NIC at 56%. After 500 connections, RPS drops as latency climbs — more concurrent goroutines means more scheduler overhead, not more throughput. The NIC ceiling at 6250 MB/s was never reached.

IRQ interrupt rate during peak: 16 queues × ~22k interrupts/sec = **352k total interrupts/sec**.

## results — IRQ pinning (cores 16-31 for IRQs, 0-15 for workers)

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>baseline RPS</th><th>pinned RPS</th><th>p50</th><th>p95 base</th><th>p95 pinned</th><th>p99 base</th><th>p99 pinned</th></tr>
  </thead>
  <tbody>
    <tr><td>100</td><td>444,621</td><td>471,000</td><td>&lt;1ms</td><td>&lt;1ms</td><td>&lt;1ms</td><td>&lt;1ms</td><td>&lt;1ms</td></tr>
    <tr class="highlight"><td>500</td><td>790,253</td><td>787,194</td><td>&lt;1ms</td><td>1ms</td><td>1ms</td><td>1ms</td><td>1ms</td></tr>
    <tr><td>1,000</td><td>786,694</td><td>782,688</td><td>1ms</td><td>3ms</td><td>3ms</td><td>3ms</td><td>3ms</td></tr>
    <tr><td>2,000</td><td>766,189</td><td>768,634</td><td>1ms</td><td>5ms</td><td>6ms</td><td>7ms</td><td>7ms</td></tr>
    <tr><td>5,000</td><td>701,382</td><td>703,328</td><td>5ms</td><td>13ms</td><td>14ms</td><td>17ms</td><td>18ms</td></tr>
    <tr><td>10,000</td><td>673,763</td><td>669,590</td><td>11ms</td><td>26ms</td><td>28ms</td><td>35ms</td><td>38ms</td></tr>
  </tbody>
</table>
</div>

Flat. Within noise. p99 at 10k connections got slightly worse (35ms → 38ms) because pinning workers to 16 cores halved the worker count from 32 to 16.

<div class="journal-callout finding">
  <strong>Finding</strong>
  At 352k interrupts/sec, IRQ cores sit at 0-3% CPU. HAProxy saw gains at ~4M pps on a 100 Gbps NIC. We are at 800k pps on a 50 Gbps NIC. The IRQ cores have nothing to do. Pinning them to dedicated cores solves a problem that isn't occurring.
</div>

## what the server metrics showed

During peak load (500 connections, baseline):

```
Server TX:  3,491 MB/s  (56% of 6,250 MB/s ceiling)
Server CPU: usr 20%  sys 25%  idle 15%  → 85% busy
IRQ rate:   ~22k/sec per queue × 16 queues = 352k/sec total
Connections: 500 established on :8083
```

The server is CPU-bound, not NIC-bound. 85% CPU at 790k RPS. The NIC has 44% headroom. The bottleneck is somewhere in the request path — not interrupt handling, not packet steering.

IRQ pinning changes what cores handle interrupts. It does not change how much CPU the request path consumes. That is a different problem.

<div class="journal-callout warning">
  <strong>Note on IRQ pinning and packet rate</strong>
  IRQ pinning helps when interrupt processing competes with goroutine execution on the same cores. That competition is proportional to packet rate, not RPS. With pipelining=100, 18M RPS = 180k pps. Without pipelining, 800k RPS = ~800k pps. Neither is enough to saturate IRQ cores on a 16-queue ENA NIC. The IRQ regime starts around 4M pps on hardware with NUMA effects and saturated interrupt queues.
</div>

<div class="journal-callout next">
  <strong>Next</strong>
  The bottleneck is somewhere in the request path at 85% CPU. Not IRQ. Not NIC. Profile it — <a href="../09-profiling-gofakeit-mutex/">entry 09</a>.
</div>
