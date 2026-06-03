---
layout: journal_entry
title: "GOMAXPROCS sets fiber's worker count, not the thread count"
subtitle: "129 workers became 2. I assumed I broke the fork loop. The source says I asked for 1 worker."
group: millionrps
group_title: "chasing 1 million rps"
group_url: "/millionrps/"
entry_date: 2026-06-10
status: done
tags: [GOMAXPROCS, prefork, threads, fiber, source]
summary: "Hypothesis: setting GOMAXPROCS=1 per prefork worker would cut its ~15 OS threads and improve cache locality. Result: only 2 processes started. I assumed the fork machinery broke. It didn't — the fiber v3 source spawns runtime.GOMAXPROCS(0) children, so GOMAXPROCS=1 means one worker. Each child already runs GOMAXPROCS(1) regardless."
result: "GOMAXPROCS=128: 129 processes (1 master + 128 workers), 1,333,453 RPS at 10k connections. GOMAXPROCS=1: 2 processes (1 master + 1 worker), 110,627 RPS at 100c declining to 87,856 at 10k. The env var controls worker count, not per-worker threading — each child overrides to GOMAXPROCS(1) in the source."
---

## why we tried this

Each prefork worker on c8i.32xlarge runs ~15 OS threads under load ([entry 09](../09-profiling-gofakeit-mutex/)). 128 workers × 15 threads = ~1,900 OS threads on 128 cores. The hypothesis: that's overhead, and setting `GOMAXPROCS=1` per worker would cut each worker to ~1 thread, reduce kernel scheduling, improve L1/L2 locality. This is how PM2-cluster and Node.js workers run — one event loop per process.

The hypothesis was built on a wrong mental model. Two of them, actually.

## setup

```bash
# run 1 — prefork, GOMAXPROCS inherits the machine (128 on c8i)
nohup ./fiber_server > /tmp/fiber.log 2>&1 &
sleep 4
echo "processes: $(pgrep -c fiber_server)"

# run 2 — prefork, GOMAXPROCS=1
GOMAXPROCS=1 nohup ./fiber_server > /tmp/fiber_gmp1.log 2>&1 &
sleep 4
echo "processes: $(pgrep -c fiber_server)"

# benchmark — same for both, c8i client
for CONN in 100 500 1000 2000 5000 10000; do
  autocannon -c $CONN --pipelining 1 -w 120 -d 20 \
    --json "http://SERVER_INTERNAL_IP:8083/read"
  sleep 3
done
```

## results

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>GOMAXPROCS=128 RPS</th><th>GOMAXPROCS=1 RPS</th><th>p50 (128 / 1)</th><th>p99 (128 / 1)</th></tr>
  </thead>
  <tbody>
    <tr><td>100</td><td class="highlight">555,642</td><td class="bottleneck">110,627</td><td>&lt;1ms / 1ms</td><td>&lt;1ms / 2ms</td></tr>
    <tr><td>500</td><td class="highlight">1,304,986</td><td class="bottleneck">105,005</td><td>&lt;1ms / 4ms</td><td>&lt;1ms / 5ms</td></tr>
    <tr><td>1,000</td><td class="highlight">1,319,936</td><td class="bottleneck">104,205</td><td>&lt;1ms / 9ms</td><td>1ms / 10ms</td></tr>
    <tr><td>2,000</td><td class="highlight">1,326,029</td><td class="bottleneck">97,088</td><td>1ms / 20ms</td><td>3ms / 22ms</td></tr>
    <tr><td>5,000</td><td class="highlight">1,320,653</td><td class="bottleneck">90,659</td><td>3ms / 55ms</td><td>6ms / 63ms</td></tr>
    <tr><td>10,000</td><td class="highlight">1,333,453</td><td class="bottleneck">87,856</td><td>6ms / 115ms</td><td>17ms / 138ms</td></tr>
  </tbody>
</table>
</div>

Process count:

```
GOMAXPROCS=128 : 129 processes  (1 master + 128 workers)
GOMAXPROCS=1   :   2 processes  (1 master +   1 worker)
```

**GOMAXPROCS=1 produced one worker, not 128 broken ones.** My first instinct was that the fork loop crashed. It didn't. I had to read the source to see I asked for exactly this.

## what the source actually says

`fiber/v3.1.0/prefork.go`:

```go
// 👶 child process 👶
if IsChild() {
    // use 1 cpu core per child process
    runtime.GOMAXPROCS(1)        // every child resets itself to 1
    ...
    return app.server.Serve(ln)  // SO_REUSEPORT listener
}

// 👮 master process 👮
maxProcs := runtime.GOMAXPROCS(0)   // master reads the env value
for range maxProcs {                 // spawns exactly that many children
    cmd := exec.Command(os.Args[0], os.Args[1:]...)
    ...
}
```

Two facts, both the opposite of what I assumed:

**1. The master spawns `runtime.GOMAXPROCS(0)` children.** Not `runtime.NumCPU()`. The env `GOMAXPROCS` directly sets the worker count. 128 → 128 workers, 32 → 32 workers, 1 → 1 worker. The "2 processes" was 1 master + 1 worker. Working as written.

**2. Every child overrides to `runtime.GOMAXPROCS(1)`.** The comment says it outright: *use 1 cpu core per child process*. So my entire premise — "cut each worker from GOMAXPROCS=128 down to 1" — was nonsense. The workers were already GOMAXPROCS=1. The env var never touched their internal scheduling. It only ever controlled how many of them exist.

## then why ~15 threads per worker, if GOMAXPROCS=1?

Because GOMAXPROCS caps the number of goroutines running Go code simultaneously (the P count), not the number of OS threads (M count). A GOMAXPROCS=1 process still spawns threads:

- 1 thread running Go code at a time (the single P)
- one M per goroutine currently blocked inside a `read`/`write` syscall — these detach from the P and sit in the kernel
- fixed runtime threads: sysmon, GC workers, finalizer

A network server constantly has goroutines mid-syscall, so the M pool sits around 10-15 even though only one runs Go at any instant. The thread count is the syscall-concurrency floor, not a GOMAXPROCS knob. You can't tune it down with the env var, and the GOMAXPROCS=1 experiment never could have — the workers were always there.

## why 1 worker = 110k RPS

One worker, GOMAXPROCS=1, one P. One goroutine runs Go code at a time. At 100 connections it manages 110k RPS; at 10k connections it degrades to 88k as the single P thrashes between more goroutines. This is the same single-threaded ceiling autocannon hits as a client. 128 workers at 1.33M is just this number × the workers that actually exist.

<div class="journal-callout warning">
  <strong>The mistake</strong>
  I reasoned about fiber's threading model from the outside — counted threads, assumed GOMAXPROCS controlled them, predicted a tuning win. Every step was wrong, and the benchmark "confirming" a problem (2 workers, low RPS) reinforced the wrong story. The source settled it in four lines. Read the source before theorising about what a library does internally.
</div>

<div class="journal-callout finding">
  <strong>Finding</strong>
  Fiber v3 prefork: master spawns <code>runtime.GOMAXPROCS(0)</code> workers, each worker runs <code>runtime.GOMAXPROCS(1)</code>. The env <code>GOMAXPROCS</code> is a worker-count dial. Its default (NumCPU) gives one worker per core, which is correct — SO_REUSEPORT distributes connections across them. Don't set it to 1.
</div>

<div class="journal-callout next">
  <strong>Next</strong>
  If GOMAXPROCS only changes worker count, does 32 workers vs 128 workers change /read throughput? And does the per-worker thread count actually depend on anything? Measured against the real ceiling — the NIC — in <a href="../11-threads-gomaxprocs-pipelining/">entry 11</a>.
</div>
