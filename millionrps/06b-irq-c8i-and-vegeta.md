---
layout: journal_entry
title: "IRQ on c8i + vegeta without pipelining: still the client"
subtitle: "18M RPS stays flat with tuning. 580k vegeta ceiling. The tool is always the wall."
group: millionrps
group_title: "chasing 1 million rps"
group_url: "/millionrps/"
entry_date: 2026-06-02
status: done
tags: [c8i, IRQ, vegeta, pipelining, packet-rate, client-ceiling]
summary: "Ran the IRQ experiment on matched c8i hardware. Then switched to vegeta (no pipelining) to generate realistic packet rates. Both hit client ceiling regardless of tuning."
result: "c8i IRQ+RPS/RFS: 18M RPS, flat vs baseline. Vegeta 8 parallel processes: 580k actual RPS ceiling. Server at 5% CPU in both cases."
---

## c8i IRQ pinning — same experiment, bigger hardware

After the c6i.2xlarge showed no effect, we ran the same three-step experiment on matched c8i.32xlarge hardware (128 cores each) to see if scale changed the result.

### IRQ pinning on c8i

c8i.32xlarge has 16 NIC queues (IRQs 143-158) on interface `enp95s0`. Pin to cores 112-127:

```bash
# cores 112-127 in 128-core mask
# 4 × 32-bit groups: [bits127-96] [bits95-64] [bits63-32] [bits31-0]
# cores 112-127 = bits 16-31 of the leftmost group = ffff0000
MASK="ffff0000,00000000,00000000,00000000"

for irq in $(seq 143 158); do
    echo $MASK | sudo tee /proc/irq/$irq/smp_affinity > /dev/null
done

# verify
cat /proc/irq/143/smp_affinity_list
# 112-127

# restart fiber on cores 0-111
pkill fiber_server; sleep 1
nohup taskset -c 0-111 ./fiber_server > /tmp/fiber.log 2>&1 &
```

### RPS/RFS on c8i

```bash
NIC=enp95s0   # c8i uses enp95s0, not ens5

# 128-core bitmask
for f in /sys/class/net/$NIC/queues/rx-*/rps_cpus; do
    echo "ffffffff,ffffffff,ffffffff,ffffffff" | sudo tee $f > /dev/null
done

echo 32768 | sudo tee /proc/sys/net/core/rps_sock_flow_entries > /dev/null

# 32768 total / 16 queues = 2048 per queue
for f in /sys/class/net/$NIC/queues/rx-*/rps_flow_cnt; do
    echo 2048 | sudo tee $f > /dev/null
done
```

### c8i /simple results — all three steps

<table class="bench-table">
  <thead>
    <tr><th>config</th><th>1000c RPS</th><th>p50</th><th>2000c RPS</th><th>p50</th><th>5000c RPS</th><th>p50</th></tr>
  </thead>
  <tbody>
    <tr><td>baseline</td><td>18,164,736</td><td>4ms</td><td>17,426,227</td><td>9ms</td><td>6,659,743</td><td>69ms</td></tr>
    <tr><td>IRQ only</td><td>17,898,223</td><td>4ms</td><td>17,434,283</td><td>9ms</td><td>6,624,715</td><td>70ms</td></tr>
    <tr><td>IRQ + RPS/RFS</td><td>18,097,698</td><td>4ms</td><td>17,437,150</td><td>9ms</td><td>6,294,493</td><td>76ms</td></tr>
  </tbody>
</table>

Flat. Server still at 26% CPU across all three configurations. No tuning moves the needle when the server is idle.

### c8i /compute results

<table class="bench-table">
  <thead>
    <tr><th>config</th><th>cores</th><th>1000c RPS</th><th>p99 ms</th><th>5000c RPS</th><th>p99 ms</th></tr>
  </thead>
  <tbody>
    <tr><td>baseline</td><td>128</td><td>1,662,225</td><td>248</td><td>1,744,862</td><td>1000</td></tr>
    <tr><td>RPS/RFS only</td><td>128</td><td>1,663,727</td><td>251</td><td>1,735,578</td><td>976</td></tr>
    <tr><td>IRQ+RPS/RFS (taskset 0-111)</td><td>112</td><td>1,515,554</td><td>304</td><td>1,595,767</td><td>1161</td></tr>
    <tr><td>IRQ+RPS/RFS (taskset 0-123)</td><td>124</td><td>1,625,600</td><td>259</td><td>1,715,439</td><td>1102</td></tr>
  </tbody>
</table>

The taskset penalty is directly proportional to cores lost:
```
128 cores → 1,744,862 RPS  (baseline)
124 cores → 1,715,439 RPS  (-1.7%)   = 4/128 = 3.1% fewer cores
112 cores → 1,595,767 RPS  (-8.6%)   = 16/128 = 12.5% fewer cores
```

RPS/RFS alone (no taskset) matched baseline exactly — zero cost, zero gain at this load.

## switching to vegeta: removing pipelining

Autocannon pipelining batches many requests into few TCP segments. High RPS, low packet rate. To generate realistic packet rates we need vegeta — one request per connection slot, no pipelining.

### vegeta parallel script

Single vegeta process caps at ~55-80k RPS (goroutine scheduler limit). Run 8 in parallel, each at rate/8, merge results via `vegeta encode`:

```bash
PARALLEL=8
TARGET=1000000
PER_PROC=$(( TARGET / PARALLEL ))   # 125000 each
WORKERS=$(( PER_PROC / 100 ))       # 1250 workers per process

for i in $(seq 1 $PARALLEL); do
    echo "GET http://SERVER_INTERNAL_IP:8083/simple" | vegeta attack \
        -rate=$PER_PROC \
        -duration=20s \
        -workers=$WORKERS \
        -keepalive=true \
        | vegeta encode > run_${i}.jsonl &
done
wait

# merge JSON lines (NOT binary — gob streams can't be naively cat'd)
cat run_*.jsonl | vegeta report -type=json > results.json
cat run_*.jsonl | vegeta report
```

### vegeta results — /simple, 8 parallel processes

<table class="bench-table">
  <thead>
    <tr><th>target RPS</th><th>actual RPS</th><th>p50 ms</th><th>p95 ms</th><th>p99 ms</th><th>success</th></tr>
  </thead>
  <tbody>
    <tr><td>100,000</td><td>99,982</td><td>0.17</td><td>4.1</td><td>11.4</td><td>100%</td></tr>
    <tr><td>200,000</td><td>199,914</td><td>0.22</td><td>10.4</td><td>19.6</td><td>100%</td></tr>
    <tr><td>500,000</td><td>409,269</td><td>6.3</td><td>29.5</td><td>42.3</td><td>100%</td></tr>
    <tr><td>1,000,000</td><td>522,820</td><td>8.5</td><td>44.4</td><td>59.7</td><td>100%</td></tr>
    <tr><td>1,500,000</td><td>588,883</td><td>12.6</td><td>59.0</td><td>78.6</td><td>100%</td></tr>
    <tr class="highlight"><td>2,000,000</td><td>580,209</td><td>17.2</td><td>75.8</td><td>105</td><td>100%</td></tr>
    <tr><td>3,000,000</td><td>558,839</td><td>26.4</td><td>110</td><td>160</td><td>100%</td></tr>
  </tbody>
</table>

Client hits ~580k actual RPS and plateaus. Server at 5% CPU. No errors, 100% success rate throughout.

Metric during 2M target run:
```
CLIENT: usr: 67%   sys: 18%   idle: 12%   — approaching client ceiling
SERVER: usr:  5%   sys:  7%   idle: 86%   — barely loaded
```

Without pipelining, even 8 parallel vegeta processes on a 128-core machine can only drive ~580k RPS to this server. The client overhead per request (goroutine scheduling, TCP stack, stat recording) costs more than the server's response.

## what would actually stress the server

The only thing that consistently made the server the bottleneck was `/compute`:
- Server at 94% CPU, client at 7%
- 1.7M RPS, p50 6ms

For `/simple` on any endpoint configuration, the client hits its ceiling first. To remove this limitation:
1. Multiple client machines simultaneously
2. Client and server on same machine (HAProxy approach — client overhead is free on loopback)
3. c6n instances with 100 Gbps NIC — at that bandwidth, packet rates approach the HAProxy regime

<div class="journal-callout finding">
  <strong>Finding</strong>
  Removing pipelining did not help — it made things worse for client throughput while also lowering packet rates significantly. The client ceiling exists regardless of benchmark tool. The only reproducible way to stress this server is via CPU-bound routes like <code>/compute</code>.
</div>

<div class="journal-callout next">
  <strong>Next</strong>
  c6n two-box setup with 100 Gbps NIC. Without pipelining at 100 Gbps, packet rates approach 10M pps — the regime where IRQ core dedication becomes necessary.
</div>
