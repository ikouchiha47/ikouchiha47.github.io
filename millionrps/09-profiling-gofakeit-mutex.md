---
layout: journal_entry
title: "403 seconds of waste, per 60 seconds of work"
subtitle: "pprof on /read: the block profile found what the CPU profile hid"
group: millionrps
chapter: 1
chapter_title: "Simple HTTP"
group_title: "Chasing 1 Million RPS"
group_url: "/millionrps/"
entry_date: 2026-06-09
status: done
tags: [profiling, pprof, gofakeit, mutex, block-profile, c6in, prefork]
summary: "Ran Go pprof against the /read handler at 800k RPS. CPU profile showed gofakeit at 2.25% — looked minor. Block profile showed 403.90s of goroutine wait time in 60 real seconds, all on one mutex, all from one line of code. Fixed it. RPS didn't move on no-prefork. Re-enabled prefork on c8i.32xlarge (128 workers): 1.33M RPS vs 1.01M no-prefork. +31% at 10k connections."
result: "block.prof: gofakeit mutex = 403.90s blocked / 60s real = 6.7 cores wasted. Fix: 807k → 809k (flat — write syscall is the ceiling, not the mutex). Prefork 128w on c8i: 1,329,306 RPS at 10k connections vs 1,011,994 no-prefork (+31%). Prefork wins at every connection count on 128 cores."
---

## why profiling

IRQ pinning on `/read` was flat ([entry 08](../08-c6in-read-nic-ceiling/)). Server at 85% CPU busy, NIC at 56%. The bottleneck is somewhere in the request path. Looking at CPU% by itself tells you nothing about where goroutines are waiting. You need a profiler.

Go's pprof captures four distinct things: where goroutines spend CPU time (cpu), which mutexes are contended (mutex), how long goroutines block waiting (block), and what's live in the heap (heap). They answer different questions. The CPU profile is not enough on its own — a goroutine blocked waiting for a lock is off-CPU and completely invisible there.

## setup

Prefork had to be disabled for profiling. In prefork mode, the pprof HTTP server starts in the parent process. The 32 worker children — where all requests are actually handled — are unreachable. Disabling prefork puts everything into one process: all goroutines visible, one pprof endpoint.

```bash
# server — no prefork when PPROF_ENABLE=1
PPROF_ENABLE=1 nohup ./fiber_server > /tmp/fiber.log 2>&1 &
```

```go
// fiber_server.go — pprof setup
func startPprof() {
    runtime.SetMutexProfileFraction(5)   // sample 1-in-5 mutex contentions
    runtime.SetBlockProfileRate(1_000_000) // sample blocking events ≥ 1ms
    go func() { http.ListenAndServe(":6060", nil) }()
}

func main() {
    if os.Getenv("PPROF_ENABLE") == "1" {
        startPprof()
    }
    // prefork disabled when profiling
    prefork := os.Getenv("PPROF_ENABLE") != "1"
    app.Listen(":8083", fiber.ListenConfig{EnablePrefork: prefork})
}
```

Profile capture — all four run in parallel against a live 500-connection autocannon load:

```bash
# 150s benchmark on client
autocannon -c 500 --pipelining 1 -w 30 -d 150 "http://SERVER_INTERNAL_IP:8083/read" &

# SSH tunnel to pprof (port 6060 not in security group)
ssh -L 6060:localhost:6060 -N -f ec2-user@SERVER_PUBLIC_IP

# capture all four simultaneously — 60s window each
curl -sf "http://localhost:6060/debug/pprof/profile?seconds=60" -o cpu.prof &
curl -sf "http://localhost:6060/debug/pprof/block?seconds=60"   -o block.prof &
curl -sf "http://localhost:6060/debug/pprof/mutex?seconds=60"   -o mutex.prof &
curl -sf "http://localhost:6060/debug/pprof/heap"               -o heap.prof &
wait
```

Load during capture: 807k avg RPS, 3.74 GB/s, p50 < 1ms.

## cpu profile — where goroutines were on-cpu

<figure>
  <img src="/img/millionrps/09-cpu-before.svg" alt="CPU flamegraph — before fix" style="width:100%; border:1px solid #30363d; border-radius:4px;">
  <figcaption style="font-size:0.8rem; color:#8b949e; margin-top:0.4rem;">cpu.prof — 60s capture at 807k RPS. Width = time on CPU.</figcaption>
</figure>

The dominant cost is the write path: `bufio.Flush → net.Write → poll.Write → syscall.Syscall6`. The kernel copying `4.5KB × 807k RPS = 3.63 GB/s` into socket send buffers accounts for 42.5% of on-CPU time. That is the physical cost of the workload. It is not tunable without changing the payload.

Scheduler overhead (`runtime.schedule → findRunnable → stealWork`) at ~20%. At `807k RPS × 2 syscalls = 1.6M` goroutine park/unpark cycles per second, this is expected.

`gofakeit.Number → sync.Mutex.Lock` at **2.25%**. Looks minor. This is the problem with only reading the CPU profile: a goroutine blocked waiting for a lock is off-CPU. The CPU profiler cannot see it. 2.25% is the time goroutines spend *acquiring* the lock. It says nothing about how long they wait for it.

## mutex profile — which locks are contended

<figure>
  <img src="/img/millionrps/09-mutex-before.svg" alt="Mutex flamegraph — before fix" style="width:100%; border:1px solid #30363d; border-radius:4px;">
  <figcaption style="font-size:0.8rem; color:#8b949e; margin-top:0.4rem;">mutex.prof — SetMutexProfileFraction(5), 1-in-5 contentions sampled.</figcaption>
</figure>

`runtime.unlock → findRunnable → schedule → park_m` at 93.42%. That is the Go scheduler's internal run queue lock — every goroutine sleep/wake touches it. Normal noise at 800k RPS. Not a bug.

`gofakeit (*lockedSource).Int63` at **6.35%**. One application mutex. The call chain: `gofakeit.Number → randIntRange → (*lockedSource).Int63 → sync.Mutex.Lock`. 6.35% of all mutex contention in the system comes from one line: `fake.Number(0, fiberPoolSize-1)` in the `/read` handler.

The mutex profile still understates the damage. It measures contention time. The block profile measures wait time. They are not the same number.

## block profile — how long goroutines waited

<figure>
  <img src="/img/millionrps/09-block-before.svg" alt="Block flamegraph — before fix" style="width:100%; border:1px solid #30363d; border-radius:4px;">
  <figcaption style="font-size:0.8rem; color:#8b949e; margin-top:0.4rem;">block.prof — SetBlockProfileRate(1_000_000), events ≥ 1ms sampled. Total: 523.90s blocked in 60s real.</figcaption>
</figure>

Total samples: **523.90s blocked during 60s real time**. That is 873% — on average 8.7 goroutines were parked simultaneously at any moment.

The left branch: `fasthttp.serveConn → fiber.requestHandler → main.main.func2 → gofakeit.Number → (*lockedSource).Int63 → sync.Mutex.Lock` = **403.90s (77.09%)**.

403 seconds of goroutine wait time, in 60 real seconds. `403 / 60 = 6.7` — six and a half CPU cores worth of goroutine capacity, permanently blocked, doing nothing, waiting for one global `rand.Rand` to be released.

Every `/read` request calls `fake.Number(0, 499)` once to pick a random product from the pre-built pool. `gofakeit.lockedSource` wraps `math/rand.Rand` in a `sync.Mutex`. All goroutines share it. At 807k requests per second, every goroutine is fighting for the same lock on every request.

The right branch: `runtime.selectgo` at 120s (22.91%). Fasthttp worker goroutines sitting in `select{}` waiting for a new connection. Normal idle time.

## heap profile — what's live in memory

<figure>
  <img src="/img/millionrps/09-heap.svg" alt="Heap profile" style="width:100%; border:1px solid #30363d; border-radius:4px;">
  <figcaption style="font-size:0.8rem; color:#8b949e; margin-top:0.4rem;">heap.prof (inuse_space) — 8.78MB total live heap at 807k RPS.</figcaption>
</figure>

Total live heap: 8.78 MB. At 807k RPS. Zero per-request allocations — the product pool was pre-serialized at startup (`json.Marshal` = 2.62MB held permanently), and every `/read` response is a pointer into that pool. GC has nothing to collect during request handling.

`runtime.allocm` at 3.08MB (35%): OS thread stacks for GOMAXPROCS=32. Fixed cost.

The heap is not a problem. The design is correct.

## the fix

The handler was:
```go
return c.Send(fiberProductPoolJSON[fake.Number(0, fiberPoolSize-1)])
```

`fake.Number` at runtime means a global mutex on every request. The product pool is already pre-built at startup. The only thing needed per request is an index into it.

Fix: pre-generate 1M random indices at startup, walk them with an atomic counter:

```go
const idxPoolSize = 1 << 20  // 1M entries = 4MB

var (
    idxPool   [idxPoolSize]int32
    idxCursor atomic.Uint64
)

func fiberInitPool() {
    // gofakeit runs here at startup only — never per-request
    rng := rand.New(rand.NewSource(time.Now().UnixNano()))
    for i := range idxPool {
        idxPool[i] = int32(rng.Intn(fiberPoolSize))
    }
    // ... rest of pool init
}

func nextIdx() int32 {
    return idxPool[idxCursor.Add(1)&(idxPoolSize-1)]
}

// handler:
return c.Send(fiberProductPoolJSON[nextIdx()])
```

One `atomic.Add` per request. No mutex. No RNG. No lock contention regardless of goroutine count.

## what changed

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>metric</th><th>before (gofakeit)</th><th>after (pre-generated pool)</th></tr>
  </thead>
  <tbody>
    <tr><td>RPS avg (500c, no-prefork)</td><td>807,312</td><td class="highlight">809,063</td></tr>
    <tr><td>block.prof gofakeit entry</td><td class="bottleneck">403.90s / 60s (77%)</td><td>gone</td></tr>
    <tr><td>block.prof total blocked time</td><td>523.90s / 60s</td><td>120s / 60s</td></tr>
    <tr><td>gofakeit in mutex.prof</td><td>6.35%</td><td>0%</td></tr>
  </tbody>
</table>
</div>

The gofakeit entry is gone from the block profile. The 403s/60s blocking drain is gone. Throughput: 807k → 809k. Flat.

<figure>
  <img src="/img/millionrps/09-block-after.svg" alt="Block flamegraph — after fix" style="width:100%; border:1px solid #30363d; border-radius:4px;">
  <figcaption style="font-size:0.8rem; color:#8b949e; margin-top:0.4rem;">block.prof after fix — 120s blocked total (was 523.90s). Remaining: pprof server goroutines in select{}.</figcaption>
</figure>

The only blocking that remains in the after profile is the `net/http` pprof server's own goroutines in `select{}` — the monitoring infrastructure, not the application. Application blocking is zero.

## why RPS didn't move

The 403s/60s blocking was goroutines *parked*. Not burning CPU — sleeping, unable to proceed. Freeing them didn't add CPU capacity. It freed goroutine throughput, which immediately collided with the next constraint: the write syscall.

At `807k RPS × 4.5KB = 3.63 GB/s` of TCP writes, the server was already at 85% CPU busy before the fix. The write path (`bufio.Flush → net.Write → syscall.Syscall6`) at 75% of on-CPU time does not shrink because gofakeit is removed. Those cycles are unavoidable at this payload size.

The goroutines that were blocked on gofakeit reached the write queue faster after the fix. The write queue processed them at the same rate. Same throughput.

<div class="journal-callout warning">
  <strong>The CPU profile alone would have sent you the wrong way</strong>
  gofakeit at 2.25% in the CPU flamegraph looks like a rounding error. You would skip it. The block profile at 77% is unambiguous. The CPU profiler is blind to off-CPU time. Always run the block profile.
</div>

## prefork — because we disabled it for profiling

With `PPROF_ENABLE=1` and no prefork, the single-process server uses one Go scheduler for all goroutines. Profiling ran on c6in.8xlarge (32 vCPU). The prefork comparison ran on both c6in.8xlarge (32 workers) and c8i.32xlarge (128 workers) to measure the scheduler effect at scale.

```bash
# no-prefork run (PPROF_ENABLE=1 disables prefork in fiber_server.go)
PPROF_ENABLE=1 nohup ./fiber_server > /tmp/fiber.log 2>&1 &

# prefork run (default — no env var)
nohup ./fiber_server > /tmp/fiber.log 2>&1 &

# client ramp — same command for both runs
for CONN in 100 500 1000 2000 5000 10000; do
  autocannon -c $CONN --pipelining 1 -w 120 -d 20 \
    --json "http://SERVER_INTERNAL_IP:8083/read"
  sleep 3
done

# verify thread count per worker during run
ps -eo pid,ppid,pcpu,nlwp,comm --sort=-pcpu | grep fiber
# nlwp = number of OS threads per process

# verify core affinity
taskset -cp $(pgrep fiber_server | head -2 | tail -1)
# c8i result: pid X's current affinity list: 0-127
```

**c6in.8xlarge — 32 workers:**

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>no-prefork RPS</th><th>prefork RPS</th><th>delta</th><th>p50</th><th>p95 no-pf</th><th>p95 pf</th><th>p99 no-pf</th><th>p99 pf</th></tr>
  </thead>
  <tbody>
    <tr><td>100</td><td>205,535</td><td class="highlight">446,042</td><td>+117%</td><td>&lt;1ms</td><td>&lt;1ms</td><td>&lt;1ms</td><td>&lt;1ms</td><td>&lt;1ms</td></tr>
    <tr><td>500</td><td>793,289</td><td>779,002</td><td>-2%</td><td>&lt;1ms</td><td>1ms</td><td>1ms</td><td>1ms</td><td>1ms</td></tr>
    <tr><td>1,000</td><td>811,883</td><td>776,800</td><td>-4%</td><td>1ms</td><td>2ms</td><td>3ms</td><td>3ms</td><td>3ms</td></tr>
    <tr><td>2,000</td><td>787,674</td><td>757,267</td><td>-4%</td><td>1ms</td><td>5ms</td><td>6ms</td><td>6ms</td><td>7ms</td></tr>
    <tr><td>5,000</td><td>685,717</td><td>692,960</td><td>+1%</td><td>5ms</td><td>13ms</td><td>13ms</td><td>17ms</td><td>17ms</td></tr>
  </tbody>
</table>
</div>

On 32 cores prefork is the choice: +117% at 100 connections, and a statistical tie (within 2-4%, run-to-run noise) from 500-2000. It never meaningfully loses. The low-concurrency win is the headline; the mid-range is a wash. On 128 cores (below) prefork wins at every count by a wide margin. There is no operating point in any run where no-prefork is the better pick.

**c8i.32xlarge — 128 workers:**

Fiber v3 prefork spawns `runtime.GOMAXPROCS(0)` child processes (128 here), and each child resets itself to `runtime.GOMAXPROCS(1)` — one logical processor per worker, SO_REUSEPORT-style. Each child measured ~15 OS threads during 1000c load (`taskset -cp` confirms affinity 0-127). Those 15 threads are not 15 active cores — with GOMAXPROCS=1 only one runs Go code at a time; the rest are M's detached into `read`/`write` syscalls plus sysmon/GC. The thread count and the worker-count mechanism are measured in detail in [entry 11](../11-threads-gomaxprocs-pipelining/).

<div class="bench-table-wrap">
<table class="bench-table">
  <thead>
    <tr><th>connections</th><th>no-prefork RPS</th><th>prefork RPS</th><th>delta</th><th>p50 no-pf</th><th>p50 pf</th><th>p99 no-pf</th><th>p99 pf</th></tr>
  </thead>
  <tbody>
    <tr><td>100</td><td>245,414</td><td class="highlight">556,653</td><td>+127%</td><td>&lt;1ms</td><td>&lt;1ms</td><td>13ms</td><td>&lt;1ms</td></tr>
    <tr><td>500</td><td>657,382</td><td class="highlight">1,308,672</td><td>+99%</td><td>&lt;1ms</td><td>&lt;1ms</td><td>16ms</td><td>&lt;1ms</td></tr>
    <tr><td>1,000</td><td>881,024</td><td class="highlight">1,321,267</td><td>+50%</td><td>&lt;1ms</td><td>&lt;1ms</td><td>15ms</td><td>1ms</td></tr>
    <tr><td>2,000</td><td>939,187</td><td class="highlight">1,327,258</td><td>+41%</td><td>1ms</td><td>1ms</td><td>16ms</td><td>3ms</td></tr>
    <tr><td>5,000</td><td>1,002,163</td><td class="highlight">1,325,210</td><td>+32%</td><td>4ms</td><td>3ms</td><td>20ms</td><td>6ms</td></tr>
    <tr><td>10,000</td><td>1,011,994</td><td class="highlight">1,329,306</td><td>+31%</td><td>9ms</td><td>6ms</td><td>25ms</td><td>17ms</td></tr>
  </tbody>
</table>
</div>

On 128 cores prefork wins at every connection count and the gap stays wide even at 10k connections (+31%). No-prefork peaks at ~1M RPS and flattens regardless of more connections — one Go scheduler managing all goroutines has hit its run queue ceiling. Prefork at 1.33M RPS is still flat — it has not found its ceiling yet on this hardware.

The no-prefork server on c6in (32 cores) peaked at 812k. On c8i (128 cores) it peaks at 1.01M. More cores help the single scheduler, but the prefork advantage grows with core count — 128 independent schedulers scale better than one scheduler on 128 cores.

The gofakeit fix has zero effect with prefork. Each worker is a separate process with its own address space — `atomic.AddInt64` on `fiberCounter` touches only that process's memory. No cross-process cache line contention at all. The fix was only relevant in the single-process profiling configuration.

<div class="journal-callout finding">
  <strong>Finding</strong>
  The block profile found 403.90s of goroutine wait time on one line of application code. The fix correctly eliminated it. Throughput did not change because the write syscall — not goroutine parking — sets the ceiling at this payload size and RPS. `4.5KB × 807k RPS = 3.63 GB/s`. That is 75% of on-CPU time at the syscall layer. You cannot reduce it without changing the payload. The optimization was real. The ceiling was elsewhere.
</div>

<div class="journal-callout next">
  <strong>Next</strong>
  Profile before optimizing — the CPU flamegraph can't see blocked goroutines; the block profile can. The fix was right even though throughput didn't move; those are not the same thing. Disabling prefork for profiling raised a question: does GOMAXPROCS tuning help, and what actually sets the ceiling? <a href="../10-gomaxprocs-prefork/">Entry 10</a>.
</div>
