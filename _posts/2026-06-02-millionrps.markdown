---
active: true
layout: journal_index
title: "Chasing 1 Million RPS"
subtitle: "a journal of hardware, kernel tuning, and diminishing returns"
date: 2026-06-02 00:00:00
background: /img/millionrps.jpg
background_color: "#0d1117"
boxed_heading: true
group: millionrps
is_index: true
permalink: /millionrps/
---

_yes, this is clickbait. kind of._

## What "1 Million RPS" Actually Means

"1 million RPS" is not a single number. It depends entirely on what the server is doing per request.

A handler that returns `{"status":"ok"}` with no I/O can hit 10-20M RPS on a single machine. A handler that does a primary-key SELECT on a warm Postgres index might do 50k-200k RPS before the database becomes the ceiling. A write with fsync — maybe 5k-20k. An aggregation query with a table scan: 500. These are not the same problem and should not share a headline.

The breakdown matters:

**Read-heavy (cache or memory):** latency is microseconds, bottleneck is the network stack and CPU cycles in the request path — TCP, kernel syscalls, HTTP parsing, serialization. This is where IRQ pinning, prefork, and buffer tuning show up. This is the regime we're in for `/simple`.

**Compute-intensive (CPU-bound, no I/O):** bottleneck is CPU cores. Throughput scales linearly with cores until you hit scheduling overhead. `/compute` in this journal is this case — 128 cores saturated, 1.7M RPS.

**Read with DB (SELECT):** you now have a latency floor set by the database round-trip (0.2ms local, 1-5ms over network). At 1ms average, Little's Law says you need 1000 concurrent connections to drive 1M RPS from a single DB connection pool. Connection limits, query planning, index hits, buffer pool size — all of these cap you before the HTTP layer does.

**Write with DB (INSERT/UPDATE):** add write amplification, WAL flushes, lock contention, replication lag. fsync at 10ms latency means 100 RPS per write path, not 1M. Batching and async writes push this up but introduce consistency trade-offs.

**Failure handling:** a server doing retries, circuit breaking, or fallback logic on each request burns CPU per failure. At high RPS, even 0.1% error rate with a retry doubles load on a degraded downstream. Failure handling changes the per-request cost model entirely.

**Consistency:** a linearizable key-value write (single-node, synchronous) is fast. A distributed write requiring quorum adds network round-trips per request. Eventual consistency lets you write to a single replica and replicate async — throughput goes up, guarantees go down.

The 1M RPS target is a lens, not a finish line. It forces you to be precise about what work the server is actually doing, because vague claims collapse immediately when you try to reproduce them. What workload? What latency? What hardware? What was the client doing?

This journal documents those questions, not the headline number.

## What We're Testing

- **HTTP servers in Go** — net/http, fasthttp, fiber — with different workloads (tiny JSON, large payloads, CPU-bound computation)
- **Kernel network stack tuning** — IRQ affinity, RPS, RFS, SO_REUSEPORT, socket options
- **Infrastructure** — single machine vs cross-machine, AWS instance families, NIC limitations
- **Load generation** — vegeta, autocannon, wrk — and why the tool matters as much as the server
- **Tradeoffs** — prefork vs single process, pipelining vs independent requests, throughput vs latency

## The Setup

All benchmarks run on AWS (ap-south-2, Hyderabad) unless otherwise noted. Server code is Go + Fiber v3. Load generation uses autocannon (for pipelining tests) or vegeta (for rate-controlled tests).

Source code: [ikouchiha47/millionrps](https://github.com/ikouchiha47/millionrps)

## Chapters

Each chapter is a different class of high-throughput problem. Same hardware, same Go, different bottlenecks.

**Chapter 1 — Simple HTTP:** a handler returning a large JSON payload. No I/O, no computation. Ceiling is the network stack: IRQ affinity, prefork, NIC bandwidth, compression.

**Chapter 2 — Fan-out (SSE likes):** one write → N subscribers. The metric shifts from RPS to events delivered per second. Bottlenecks are goroutine contention, IPC overhead, and the cost of fanning a single event to 64K open connections.

**Chapter 3 — Metrics ingestion** *(planned)*: write-heavy, time-series, aggregation at ingestion. Different shape again.

## Journal

*Entries below are in chronological order. Green = done, orange = in progress, grey = planned.*
