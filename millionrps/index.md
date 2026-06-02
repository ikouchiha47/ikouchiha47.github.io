---
layout: journal_index
title: "chasing 1 million rps"
subtitle: "a journal of hardware, kernel tuning, and diminishing returns"
group: millionrps
is_index: true
background_color: "#0d1117"
---

## yes, this is clickbait. kind of.

"1 million requests per second" sounds like a headline from a conference talk where someone demoed a ping endpoint on a 96-core bare metal box and called it a day. This is not that.

What this actually is: a running journal of someone trying to understand what happens between *a request leaving a client* and *a response arriving back* — at scale. The hardware layer, the kernel layer, the network stack, the Go runtime, the HTTP framework. Where does time go? Who's waiting on whom? What does "bottleneck" actually mean when you're staring at 128 CPU cores all showing 1% utilization?

The 1M RPS target is a useful north star. It forces real decisions — you can't paper over bad architecture with clever code when latency budgets are microseconds. But the number itself is almost beside the point. The interesting stuff is what you learn chasing it.

## what we're testing

- **HTTP servers in Go** — net/http, fasthttp, fiber — with different workloads (tiny JSON, large payloads, CPU-bound computation)
- **Kernel network stack tuning** — IRQ affinity, RPS, RFS, SO_REUSEPORT, socket options
- **Infrastructure** — single machine vs cross-machine, AWS instance families, NIC limitations
- **Load generation** — vegeta, autocannon, wrk — and why the tool matters as much as the server
- **Tradeoffs** — prefork vs single process, pipelining vs independent requests, throughput vs latency

## the setup

All benchmarks run on AWS (ap-south-2, Hyderabad) unless otherwise noted. Server code is Go + Fiber v3. Load generation uses autocannon (for pipelining tests) or vegeta (for rate-controlled tests).

Source code: [ikouchiha47/millionrps](https://github.com/ikouchiha47/millionrps)

## journal

*Entries below are in chronological order. Green = done, orange = in progress, grey = planned.*
