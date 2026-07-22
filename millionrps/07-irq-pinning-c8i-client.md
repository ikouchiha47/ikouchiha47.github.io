---
layout: journal_entry
title: "planned: IRQ pinning + matched hardware"
subtitle: "stop irqbalance, isolate cores, c8i.32xlarge vs c8i.32xlarge"
group: millionrps
chapter: 1
chapter_title: "Simple HTTP"
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
entry_date: 2026-06-15
status: pending
tags: [IRQ, irqbalance, isolcpus, c8i, kernel, planned]
summary: "Apply proper IRQ isolation as described in the HAProxy blog. Stop irqbalance and crond. Pin 16 NIC IRQs to dedicated cores. Run fiber workers on clean cores only. Upgrade client to c8i.32xlarge. Waiting for AWS quota increase to 320 vCPU."
result: "pending"
---

*This entry will be written once the AWS vCPU quota increase is approved and the experiment runs. The plan below is what we intend to do — nothing here has been executed yet.*

## what we learned from the HAProxy blog

The [HAProxy 2M+ RPS post](https://www.haproxy.com/blog/haproxy-forwards-over-2-million-http-requests-per-second-on-a-single-aws-arm-instance) describes a key observation:

> It took me a while to figure out how to completely stabilize the platform because while virtualized, there are still 32 interrupts (aka IRQs) assigned to the network queues, delivered to 32 cores. This could possibly explain the lower performance with a lower number of cores... Moving the interrupts to the 32 upper cores left the 32 lower ones unused and simplified the setup a lot.

In our last run, NIC IRQs were concentrated on 7 cores (CPU5, CPU7, CPU9, CPU11, CPU18, CPU21, CPU28) — assigned randomly by `irqbalance`. Fiber workers ran on all 128 cores including those 7. Result: NIC interrupt processing competed with request handling on the same cores.

## what we plan to do

### 1. stop parasitic services

```bash
# irqbalance continuously reassigns NIC IRQs — undoes manual pinning
sudo systemctl stop irqbalance

# crond wakes every 60s — causes latency spikes (documented in HAProxy blog)
sudo systemctl stop crond
```

### 2. check NIC IRQ numbers

```bash
# server
grep enp95s0 /proc/interrupts | awk -F: '{print $1}' | tr -d ' '
# gives IRQ numbers (143-158 in our last run)

# client
grep ens5 /proc/interrupts | awk -F: '{print $1}' | tr -d ' '
# gives IRQ numbers (28-35 in our last run)
```

### 3. pin NIC IRQs to dedicated cores

Pin all 16 NIC IRQs on the server to cores 112-127 (upper 16 cores).

```bash
# smp_affinity is a hex bitmask
# cores 112-127 = bits 112-127 set
# = 0xffff000000000000000000000000 (128-bit, comma-separated 32-bit groups)

for irq in $(grep enp95s0 /proc/interrupts | awk -F: '{print $1}' | tr -d ' '); do
  echo ffff0000,00000000,00000000,00000000 | sudo tee /proc/irq/$irq/smp_affinity
done
```

This frees cores 0-111 from ever receiving NIC hardware interrupts.

### 4. run fiber workers on clean cores only

```bash
# pin fiber_server to cores 0-111
# (needs to be set before starting the server, or use taskset on the binary)
taskset -c 0-111 ./fiber_server
```

### 5. upgrade client to c8i.32xlarge

Current client: c6i.4xlarge, 16 vCPU, 12.5 Gbps — saturated at 82% CPU.

Planned: c8i.32xlarge, 128 vCPU, 50 Gbps.

```bash
# same autocannon command, matched hardware
taskset -c 0-111 autocannon -m GET \
  --connections 5000 \
  --duration 30 \
  --pipelining 100 \
  --workers 120 \
  "http://SERVER_PRIVATE_IP:8083/simple"

# --connections 5000: 5× previous run → 500k simultaneous in-flight requests
# ramp: 1000 → 2000 → 5000 to observe scaling behaviour
```

### 6. keep RPS + RFS

RPS and RFS remain active — they operate at the software layer after the hardware IRQ fires. IRQ pinning and RPS/RFS are complementary, not conflicting.

## what we expect to see

With NIC IRQs on dedicated cores (112-127) and fiber workers on isolated cores (0-111):
- No random preemption of goroutines by NIC interrupts
- Lower latency variance (P99/P50 ratio should tighten)
- Whether total RPS improves depends on whether interrupt interference was a meaningful ceiling

With matched c8i.32xlarge client:
- 128 cores running 120 autocannon workers = near 1:1 core-to-worker ratio
- 50 Gbps NIC eliminates client bandwidth ceiling
- Server's actual CPU ceiling becomes measurable for the first time

## what we want to validate

1. Does IRQ isolation improve P99 or just make the numbers cleaner?
2. With the client no longer bottlenecked, where does the server saturate?
3. Can Go/fiber match or exceed the Node.js/PM2 6.5M RPS number with identical hardware and tooling?

*Entry will be updated with actual results after the experiment runs.*
