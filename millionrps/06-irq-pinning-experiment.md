---
layout: journal_entry
title: "IRQ pinning: when it matters and when it doesn't"
subtitle: "three-step experiment on c6i.2xlarge — baseline, IRQ only, IRQ + RPS/RFS"
group: millionrps
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
entry_date: 2026-06-06
status: done
tags: [IRQ, irqbalance, taskset, RPS, RFS, c6i, pipelining, packet-rate, haproxy]
summary: "Full IRQ pinning experiment on c6i.2xlarge (8 vCPU) as server. Three steps: baseline, IRQ pinning only, IRQ + RPS/RFS. Run on /simple and /compute. Read the HAProxy blog. Understand why packet rate — not RPS — is what makes IRQ pinning matter."
result: "IRQ pinning had no meaningful effect on /simple (+1%). Hurt /compute (-9%) due to taskset reducing compute cores. Root cause: packet rate at our load level is too low to saturate IRQ cores. The HAProxy regime requires millions of packets/sec, not millions of RPS."
---

## why a smaller server

The c8i.32xlarge experiment showed the server at 26% CPU even at 18M RPS. IRQ interference can't matter when the server is idle. We downsized to c6i.2xlarge (8 vCPU) to let the client saturate the server and create conditions where interference would be visible.

```
Server: c6i.2xlarge  (8 vCPU,  6.25 Gbps)
Client: c6i.8xlarge  (32 vCPU, 25 Gbps)
```

## what irqbalance does and why we stopped it

`irqbalance` is a daemon that continuously reassigns NIC IRQs to different cores. Every time it runs it undoes any manual affinity settings. Stop it before any IRQ experiment:

```bash
sudo systemctl stop irqbalance
sudo systemctl disable irqbalance

# verify
systemctl is-active irqbalance
# inactive
```

## checking NIC queues and IRQ numbers

```bash
# how many hardware queues does the NIC have?
sudo ethtool -l ens5
# Combined: 8  (c6i.2xlarge)

# which IRQ numbers belong to this NIC?
grep "ens5" /proc/interrupts | awk -F: '{print $1}' | tr -d ' '
# 28 29 30 31 32 33 34 35

# which CPU is currently handling each queue?
NIC=ens5
awk "NR==1{for(i=2;i<=NF;i++)cpu[i]=\$i} \$NF~/ens5/{q=\$NF;for(i=2;i<=NF-3;i++){if(\$i+0>0)printf \"%-28s -> %-8s (%d)\n\",q,cpu[i],\$i}}" /proc/interrupts

# output (default, before pinning):
# ens5-Tx-Rx-0   -> CPU0   (3500418)
# ens5-Tx-Rx-1   -> CPU1   (3675033)
# ...one queue per core, all mixed with fiber workers
```

## step 1: baseline

Server state: no IRQ pinning, no RPS/RFS, fiber on all 8 cores.

```bash
# start fiber normally — no taskset, no pinning
pkill fiber_server 2>/dev/null
nohup ./fiber_server > /tmp/fiber.log 2>&1 &

# verify RPS/RFS is off
cat /sys/class/net/ens5/queues/rx-0/rps_cpus
# 00

cat /proc/sys/net/core/rps_sock_flow_entries
# 0
```

```bash
# benchmark — 30 workers, pipelining 100
./autocannon_bench.sh SERVER_INTERNAL_IP 100 30 30 simple
```

<div class="bench-table-wrap">
<table class="bench-table">
  <thead><tr><th>connections</th><th>RPS</th><th>p50 ms</th><th>p99 ms</th><th>throughput MB/s</th></tr></thead>
  <tbody>
    <tr><td>1000</td><td>2,473,242</td><td>37</td><td>85</td><td>306</td></tr>
    <tr><td>2000</td><td>2,152,192</td><td>91</td><td>195</td><td>266</td></tr>
    <tr><td>5000</td><td>2,318,061</td><td>231</td><td>505</td><td>287</td></tr>
  </tbody>
</table>
</div>

```
SERVER: AVG usr: 62%   sys: 14%   idle: 11%   — all 8 cores hot
CLIENT: AVG usr: 81%   sys: 7.7%  idle: 6%

NIC interrupts: 8 queues on CPUs 0-7 — one per core, all mixed with fiber workers
```

## step 2: IRQ pinning only

Pin all 8 NIC IRQs to cores 6-7. Restart fiber on cores 0-5 with `taskset`.

```bash
# cores 6-7 on an 8-core system = bits 6+7 = 0xc0
MASK="c0"

for irq in $(seq 28 35); do
    echo $MASK | sudo tee /proc/irq/$irq/smp_affinity > /dev/null
done

# verify
cat /proc/irq/28/smp_affinity_list
# 6-7

# restart fiber restricted to cores 0-5
pkill fiber_server 2>/dev/null; sleep 1
nohup taskset -c 0-5 ./fiber_server > /tmp/fiber.log 2>&1 &
```

```bash
./autocannon_bench.sh SERVER_INTERNAL_IP 100 30 30 simple
```

<div class="bench-table-wrap">
<table class="bench-table">
  <thead><tr><th>connections</th><th>RPS</th><th>p50 ms</th><th>p99 ms</th><th>throughput MB/s</th></tr></thead>
  <tbody>
    <tr><td>1000</td><td>2,489,660</td><td>35</td><td>95</td><td>308</td></tr>
    <tr><td>2000</td><td>2,165,822</td><td>90</td><td>195</td><td>268</td></tr>
    <tr><td>5000</td><td>2,300,485</td><td>232</td><td>525</td><td>285</td></tr>
  </tbody>
</table>
</div>

```
CPU0-5 (fiber cores):   usr 72-85%  sys 6-16%   — doing real work, no interrupts
CPU6-7 (IRQ cores):     usr 0-1%    sys 0-1%    idle 57%  — mostly sleeping
```

IRQ pinning is **working** — the separation is visible in per-core CPU. But RPS is essentially unchanged (+0.7%).

## step 3: IRQ + RPS/RFS

Apply RPS/RFS on top of the IRQ pinning already in place.

```bash
NIC=ens5

# RPS: allow all 8 cores to process softirqs
for f in /sys/class/net/$NIC/queues/rx-*/rps_cpus; do
    echo ff | sudo tee $f > /dev/null
done

# RFS: steer packets to the CPU that last ran the socket's goroutine
echo 32768 | sudo tee /proc/sys/net/core/rps_sock_flow_entries > /dev/null
for f in /sys/class/net/$NIC/queues/rx-*/rps_flow_cnt; do
    echo 4096 | sudo tee $f > /dev/null
done

# verify
cat /sys/class/net/$NIC/queues/rx-0/rps_cpus
# ff
cat /proc/sys/net/core/rps_sock_flow_entries
# 32768
```

<div class="bench-table-wrap">
<table class="bench-table">
  <thead><tr><th>connections</th><th>RPS</th><th>p50 ms</th><th>p99 ms</th><th>throughput MB/s</th></tr></thead>
  <tbody>
    <tr class="highlight"><td>1000</td><td>2,542,891</td><td>32</td><td>90</td><td>315</td></tr>
    <tr><td>2000</td><td>2,226,432</td><td>87</td><td>202</td><td>276</td></tr>
    <tr><td>5000</td><td>2,304,654</td><td>231</td><td>537</td><td>285</td></tr>
  </tbody>
</table>
</div>

## full comparison

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th></th><th>baseline</th><th>IRQ only</th><th>IRQ + RPS/RFS</th></tr>
  </thead>
  <tbody>
    <tr><td>1000c RPS</td><td>2,473,242</td><td>2,489,660</td><td>2,542,891 (+2.8%)</td></tr>
    <tr><td>1000c p50</td><td>37ms</td><td>35ms</td><td>32ms</td></tr>
    <tr><td>2000c RPS</td><td>2,152,192</td><td>2,165,822</td><td>2,226,432 (+3.5%)</td></tr>
    <tr><td>5000c RPS</td><td>2,318,061</td><td>2,300,485</td><td>2,304,654 (~flat)</td></tr>
  </tbody>
</table>
</div>

~3% improvement. Within noise for most practical purposes.

## /compute on c6i — where it actually hurts

`/compute` saturates the server CPU. At 97% server CPU, IRQ interference on fiber cores should be more visible.

```bash
./autocannon_bench.sh SERVER_INTERNAL_IP 100 30 30 compute
```

<div class="bench-table-wrap">
<table class="bench-table">
  <thead><tr><th>config</th><th>1000c RPS</th><th>p99 ms</th></tr></thead>
  <tbody>
    <tr><td>baseline (8 cores)</td><td>69,060</td><td>5430</td></tr>
    <tr><td>IRQ + RPS/RFS (6 cores)</td><td>69,849</td><td>6852</td></tr>
  </tbody>
</table>
</div>

Near-identical RPS. But p99 got **worse** with tuning (+26%). Why: restricting fiber to 6 cores with `taskset` lost 2 compute cores. For CPU-bound work, fewer cores = fewer parallel goroutines = higher queueing latency at the tail.

## the mistake: taskset and IRQ pinning were combined

We applied both simultaneously:
```bash
echo c0 | sudo tee /proc/irq/28/smp_affinity   # IRQs on cores 6-7
taskset -c 0-5 ./fiber_server                   # fiber on cores 0-5
```

These are independent knobs:
- **IRQ pinning** controls which cores receive hardware NIC interrupts
- **`taskset`** controls which cores a process is allowed to run on

The correct experiment would have tested them separately:
```
Step 1: baseline              (8 cores, IRQs anywhere)
Step 2: IRQ pin only          (8 cores for fiber, IRQs on 6-7)   ← we skipped this
Step 3: taskset only          (fiber on 0-5, IRQs anywhere)
Step 4: IRQ + taskset         (fiber on 0-5, IRQs on 6-7)
```

Step 2 — IRQ pinning without restricting fiber cores — would have zero compute cost and shown the pure effect of interrupt isolation.

## why nothing made a difference: the HAProxy blog

The [HAProxy 2M+ RPS post](https://www.haproxy.com/blog/haproxy-forwards-over-2-million-http-requests-per-second-on-a-single-aws-arm-instance) describes pinning 32 NIC IRQs to 16 dedicated cores. It worked because:

> the network saturates at around 4.15 million packets per second... the network-dedicated cores regularly appear at 100%

Their IRQ cores were at **100% CPU**. Ours were at **0-3%**. The IRQ cores are almost sleeping at our packet rate.

The reason: **pipelining**. With `--pipelining 100` and 1000 connections:

```
1000 TCP connections × pipelining 100 = 100k requests in-flight
but actual packet rate ≈ 97,000 packets/sec   (much lower than RPS)
÷ 8 NIC queues = ~12,000 interrupts/sec per IRQ core
= one interrupt every 83 microseconds
```

HAProxy was generating 4.15M packets/sec — 40× more interrupt pressure — because they used no pipelining. At their packet rate, dedicating cores to interrupt handling was necessary to prevent constant goroutine preemption.

IRQ pinning is a **packet rate** optimisation, not an RPS optimisation. Pipelining gives high RPS at low packet rates. Our IRQ cores never got loaded enough for isolation to matter.

## what would make it matter

To reach the HAProxy regime on our setup:
1. Use vegeta (no pipelining) — each request = one packet
2. At 2M actual RPS without pipelining → 4M packets/sec → IRQ cores load up
3. At that point, isolating NIC cores from fiber cores would show real gains

<div class="journal-callout finding">
  <strong>Finding</strong>
  IRQ pinning is a packet rate optimisation, not an RPS optimisation. At our load levels (97k pps despite 2.5M RPS), the IRQ cores sit at 0-3% CPU. There is no interference to isolate. The HAProxy result requires millions of actual distinct packets per second — only achievable without HTTP pipelining.
</div>

<div class="journal-callout warning">
  <strong>What we got wrong</strong>
  Combining <code>taskset</code> and IRQ pinning in the same step. For CPU-bound workloads, restricting fiber to fewer cores costs more RPS than interrupt isolation saves. These should always be tested independently.
</div>

<div class="journal-callout next">
  <strong>Next</strong>
  Switch to vegeta (no pipelining) to generate realistic packet rates. Use c6n instances (100 Gbps NIC) to approach the packet rate where IRQ pinning shows meaningful gains.
</div>
