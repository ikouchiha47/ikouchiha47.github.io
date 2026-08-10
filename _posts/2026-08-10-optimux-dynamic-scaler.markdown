---
active: true
featured: true
featured_order: 1
layout: post
title: "Optimux: from a worker-pool tutorial to a DynamicScaler"
subtitle: "open-sourcing an on-the-fly image/video optimizer, and why the classic dispatcher pattern didn't fit"
description: "The Job/Dispatcher worker pool from the famous '1 Million Requests' article is built for I/O-bound fan-out. Image processing is a mixed I/O+CPU pipeline, and pprof proved the difference. Here's the road from that pattern to a self-scaling worker pool."
date: 2026-08-10
background_color: linear-gradient(135deg, #0f172a 0%, #1e2937 50%, #334155 100%)
---

[optimux](https://github.com/go-batteries/optimux) is a Go service that resizes, re-encodes, and streams images and video on the fly — `/resize?image_url=...&sizes=300x0&format=webp&quality=60`, done. It's been running as an internal service for a while. I'm open-sourcing it now, AGPL-3.0, because the worker pool underneath it — the part that decides how many goroutines are doing image processing at any given moment — ended up being the most interesting thing in the codebase, and it deserves to exist somewhere other than a private repo.

This is the story of how that worker pool got there, including the part where the pattern everyone starts with turned out to be actively wrong for this workload.

## Starting point: the Job/Dispatcher pattern

Like a lot of people who've had to build a Go job queue, I started from Marcio Castilho's [Handling 1 Million Requests per Minute with Golang](https://medium.com/smsjunk/handling-1-million-requests-per-minute-with-golang-f70ac505fcaa). Worth being precise about what that article actually builds, because the mismatch with image processing turned out to matter a lot:

- A `Job` struct wraps one unit of work (there, a POST payload headed to S3).
- A buffered `JobQueue chan Job` receives incoming jobs.
- A `Dispatcher` owns a `WorkerPool chan chan Job` — a **channel of channels**. Each `Worker` has its own `chan Job`, and the moment a worker finishes a job, it pushes its *own* channel back into the shared `WorkerPool`. The dispatcher's loop just pulls one worker-channel off `WorkerPool` and hands it the next job.
- No worker ever polls for work or reports "I'm free" via a flag — availability *is* "my channel is currently sitting in the pool." `MAX_WORKERS` and `MAX_QUEUE` are env-configured, fixed for the process lifetime.

The article's numbers are genuinely good: they took a system that needed ~100 EC2 instances down to 4 `c4.Large` instances handling close to a million requests a minute, by replacing unbounded goroutine spawning with this bounded pool. But the workload is uploading JSON payloads to S3 — almost entirely I/O wait, barely any CPU. I built the same pattern, pointed it at image resizing instead, and it did not translate.

## The pattern didn't fit, and pprof proved it

I wired up the Job/Dispatcher pattern for image jobs and it was slow in a way that didn't make sense from the throughput numbers alone. So I pulled a blocking profile, and it was unambiguous:

> pprof blocking profile shows **67.99%** of total time spent waiting on `chanrecv1`.

That's workers blocked waiting for jobs, and the dispatcher blocked waiting for workers to hand their channel back — a pattern built for a workload where a worker is *cheap and fast* per unit (fire an S3 PUT, wait on the network, done) turns into mostly idle channel choreography when a unit of work is *hundreds of milliseconds of CPU-bound image processing* instead. The channel-of-channels handoff, the dispatcher loop, the per-job registration — all of that overhead is invisible when a worker's actual job takes microseconds of your attention and the rest is network wait. It stops being invisible when the job itself is the bottleneck. Target throughput was `8.6rps`; no matter what I tuned in this shape, it sat at `2.0xrps`.

So I threw it out. Not tuned, not patched — removed, and rebuilt from a synchronous baseline up, one variable at a time, so I'd actually know what each change bought me instead of tuning inside a pattern that was wrong from the start.

## Rebuilding from zero, one variable at a time

**Synchronous baseline, no workers at all** — inline resize, respond directly. `2.9rps`. Already ahead of the dispatcher pattern's `2.0x`, which was the first sign the problem wasn't "not enough workers," it was the shape of the concurrency itself.

**Single channel, single worker.** The smallest thing that still queues — one goroutine pulling off one channel, closer to a single core churning a work list than to a "pool" in any real sense. `2.1rps` — *worse* than doing nothing concurrent at all. Concurrency has a floor cost, and this workload was paying it without buying anything back yet.

**Single queue, 4 workers.** `3.15rps`, average latency `1.37s`. First real win, and a small one.

**Two queues — fetch and process, split apart — 4 workers each.** `3.07rps`, marginally *lower* throughput than the single queue, but the latency distribution across percentiles visibly smoothed out. Tracing explained why: fetching a source image from tmpfs cost `40-100ms`; processing it (libvips, resizing a 3.1MB source down to a 120×240 webp) cost `~700ms`. Those are two stages with wildly different service times sharing a queue and worker pool — an impedance mismatch, where a burst of cheap fetches can queue up behind a slow processor, or the reverse.

**Two queues, but weighted 2 fetchers / 4 processors**, leaning into the imbalance on purpose. Performed *worse* than the even split, still around `3+rps`. My read at the time: this isn't a batch pipeline where you can freely over-provision the expensive stage and let a queue absorb the mismatch — it's a real-time request path where the caller is still on the other end of the HTTP connection waiting, so over-provisioning one stage just moves the queueing, it doesn't remove it.

I also tried a demand-driven producer/consumer setup along the way — closer to Elixir's GenStage, where the consumer explicitly asks the producer for N items instead of the producer pushing whenever it has something. It didn't pan out for this workload, and honestly the specifics didn't survive in my notes — only the conclusion did: the demand/ack round-trip was adding coordination cost that a plain buffered channel already got for free, without a corresponding improvement in how work actually got scheduled.

Separately, before any dynamic scaler existed, I added something orthogonal to worker count entirely: instead of buffering the whole encoded image and writing it in one response, the handler started flushing early and streaming bytes out as the encoder produced them. That alone moved the needle independent of worker shape — `3.28rps`, latency down to `1.31s`.

## What actually generalizes, and what doesn't

Here's the actual lesson, not just the numbers: the Job/Dispatcher pattern isn't wrong, it's scoped to a specific kind of workload — one where the *external* resource (S3, a network call, a database) is the thing you're rationing, and your own CPU is basically idle waiting on it. In that world, a large fixed worker count is nearly free — you're just capping how many outstanding waits you allow. libvips-backed image processing inverts that: the constrained resource is *your own CPU and memory*, fetch and process have genuinely different cost profiles, and a fixed `MAX_WORKERS` picked once has no way to track a queue that swings between bursty and empty. `iostat` on the EC2 box backed this up directly — CPU usage swinging from 80%+ down to 40% inside the same short window, `%steal` spiking as high as 8.74% (hypervisor-stolen cycles, which no amount of worker retuning fixes). A workload like that needs the worker count itself to be a live variable, not a constant — which is what actually motivated moving off any fixed-size pool entirely, GenStage-shaped or otherwise, toward something that watches queue depth and scales.

It's worth being precise about *where* the two patterns actually diverge structurally, because it's not just "one has a scaler and one doesn't."

The dispatcher pattern's availability signal is a second layer of indirection: each worker owns a private `chan Job`, and "I'm free" is expressed by pushing that channel into a shared `WorkerPool chan chan Job`. That's `N+1` channels for `N` workers — one pool channel plus one per-worker channel — and a dispatcher goroutine whose whole job is shuttling a channel out of the pool, handing it a job, and waiting for it to come back. It's a clean pattern, but it exists to solve a problem optimux's worker pool doesn't have: every worker in `DynamicScaler` pulls directly off one shared `Queue chan T`. There's no dispatcher goroutine, no per-worker channel, no explicit "I'm free" message at all — a worker's availability *is* nothing more than "currently blocked on a receive from `Queue`," which Go's own runtime already arbitrates correctly among however many goroutines are competing to receive. The single-shared-queue shape showed up as early as the "single queue, 4 workers" experiment above, well before any scaler existed, and every version since kept it — the channel-of-channels indirection never came back, because a single channel with competing receivers gave equal or better throughput without the extra bookkeeping.

The other divergence is what each pattern treats as fixed. The article's `MAX_WORKERS` is an env var read once at startup — there's no concept of a worker ever leaving the pool short of the whole process dying, because the workload it targets doesn't need one: S3 upload capacity doesn't really shrink at 2am. `DynamicScaler` has an explicit opposite belief baked into its registry — every `WorkerSlot` can be marked `Retiring` and needs a defined, race-free way to leave the pool without dropping in-flight work, because for this workload the *right* worker count at any moment is itself the thing under contention (CPU cores, memory for concurrently-decoded images), not a constant you get to pick once.

## What DynamicScaler does

`DynamicScaler[T]` (`src/mediahose/schedulers.go`) is a generic worker pool that grows and shrinks based on queue pressure instead of running a fixed goroutine count. The type parameter is the job type, so the same scaler independently drives image jobs, video jobs, and batch jobs off different queues with different thresholds.

The registry is a single ordered slice, append-only in creation order:

```go
type WorkerSlot[T any] struct {
    Idx      int64
    Retiring bool // marked for retirement; reclaimed only on exit notify
    worker   Worker[T]
    cancel   context.CancelFunc
    retire   chan chan bool
}

type DynamicScaler[T any] struct {
    WorkerFactory      func(idx int64, done chan int64) Worker[T]
    Queue              chan T
    MinWorkers, MaxWorkers int
    ScaleUpThreshold, ScaleDownThreshold int
    CheckInterval, ScaleCooldown, RetireGrace time.Duration
    workers []*WorkerSlot[T] // tail = newest
}
```

Because the slice is append-only, the tail is always the newest worker — which makes "retire the newest worker first" (LIFO) a deterministic scan instead of a random pick. There's no separate counter tracking how many workers are active; the live count is derived on read:

```go
func countLive[T any](workers []*WorkerSlot[T]) int {
    live := 0
    for _, wsl := range workers {
        if !wsl.Retiring {
            live++
        }
    }
    return live
}
```

Nothing else exists to fall out of sync with the registry, because there's nothing else — the count is a computation over the one piece of state, not a second piece of state someone has to remember to update alongside it.

**Retirement happens at an idle boundary, not on demand.** A worker that opts in (`FetchWorker`, the image/video processing worker, does) runs a single blocking `select` over three cases — context cancellation, a retire request, and the job queue — with no `default` branch:

```go
select {
case <-ctx.Done():
    return
case retireReq := <-fw.RetireCh:
    select {
    case retireReq <- true:
    default:
    }
    return
case job := <-jobQueueChan:
    // process it
}
```

No `default` matters: the worker is genuinely parked, doing nothing, only while blocked in that select. A retire request lands the instant the worker goes idle, not after it happens to finish whatever job comes next. When the scaler decides to shrink the pool, it marks the newest slot `Retiring: true` and sends a one-shot ack request; the slot stays in the registry, still counted toward the hard `MaxWorkers` cap, until the worker actually exits and notifies the scaler on a close channel. There's a bounded grace period (default 2s) — if the worker hasn't idled out by then, the scaler cancels its context as a fallback nudge, but removal from the registry only ever happens on the real exit notification, never on the timeout itself.

**Scale decisions are cooled down, with an escape hatch.** The signal driving `scale()` is `len(ds.Queue)` — instantaneous backlog, sampled on a ticker. That's not the same thing as, say, SQS handing you `ApproximateNumberOfMessagesVisible` alongside an in-flight count, smoothed over a window before an alarm fires. A raw instantaneous queue length is noisy under bursty traffic: it can cross `ScaleUpThreshold` and `ScaleDownThreshold` within a couple of ticks without the underlying load actually having changed, and a scaler with no way to tell a real trend from a blip would happily add a worker and retire it right back. The cooldown (default 30s between scale actions) exists because that better signal doesn't exist yet — it's a blunt fix for a noisy input, not a fundamental property of dynamic pools. The one case that bypasses it entirely: if live workers ever drop below `MinWorkers`, the scaler refills immediately regardless of cooldown, so a crash storm can't leave the pool sitting empty for a full cooldown window waiting on a timer that doesn't care capacity is gone.

That's the whole mechanism: one ordered registry as the single source of truth for both "who's alive" and "who retires next," idle-boundary handshakes instead of blind cancellation, and a cooldown standing in for a smarter scaling signal that isn't built yet.

## What I didn't test: prefork

One pattern from a different corner of the same problem space I never actually tried: [Fiber's prefork mode](https://docs.gofiber.io/) — instead of one Go process handling everything under a single `GOMAXPROCS`, use `SO_REUSEPORT` to run N forked OS processes, each getting its own slice of cores, with the kernel load-balancing connections across them.

My honest guess is it wouldn't have moved the throughput numbers above. Every pool-shape experiment — single worker, 4 workers, split queues, weighted split — barely moved throughput (`2.1` to `3.15rps`), because the real cost is `~700ms` of libvips CPU work per image, not goroutine-scheduling or channel overhead. Prefork changes how many OS processes share a machine's cores, not how many cores exist; the same physical CPU is doing the same total amount of resize work whether it's one process running N goroutines or K processes each running fewer, and Go's scheduler already multiplexes goroutines across cores efficiently for CPU-bound work like this.

Where I'd actually expect it to help is somewhere none of these benchmarks were looking: tail latency and fault isolation. This worker loop allocates large image byte slices per job (there's a `byts = nil` in it as a GC hint) — a GC pause or heavy mark-assist period in one process adds jitter to *every* concurrent request in that process. With prefork, GC pressure in one fork doesn't stall requests being served by a sibling fork. Same story for a pathological input (corrupt file, huge dimensions) wedging or OOMing one process — the kernel keeps routing new connections to the survivors instead of the whole fleet going down. Neither of those is a throughput property, and neither is something `Progression.md`'s numbers (throughput, average latency) would have caught even if true. Genuinely untested — not a claim, a gap.

## What's next

Three things this codebase is deliberately waiting on or missing rather than half-building now, documented in the repo for anyone who wants to pick them up.

**Streaming instead of buffering, once govips ships it.** Every image today gets fully buffered into a `[]byte` at each stage — load, encode, respond — before the next stage starts. govips just merged native streaming support (`LoadImageFromReader`, `SaveToWriter*`, PR [davidbyttow/govips#539](https://github.com/davidbyttow/govips/pull/539)), which would let a load and an encode work directly against `io.Reader`/`io.Writer` instead of a fully materialized buffer — real memory savings for a service whose job is exactly this: dynamic compression of non-standard sizes at request time. It's not in a tagged release yet (latest tag predates the merge by months), so this is parked as `docs/ADR-003` in the repo until that lands, rather than pinned to an untagged commit in something serving production traffic.

**A real HTTP/2 cross-stream priority scheduler.** This one came out of a completely different rabbit hole: [Cloudflare's parallel-streaming-of-progressive-images](https://blog.cloudflare.com/parallel-streaming-of-progressive-images/) work, where a server multiplexing many concurrently-loading images over one HTTP/2 connection sends every image's size header first, then every preview, then remaining refinement data — instead of blasting one image's full body before starting the next. Optimux already does the single-image version of this (`StreamEncoder`/`ProgressiveStreamEncoder` chunk header→preview→remainder), but the cross-stream scheduling piece — deciding, across every concurrently open image request, whose bytes go out next — turned out to be something almost nobody exposes as a plugin point. Go's `x/net/http2.WriteScheduler` is deprecated by its own maintainers ("provides too much visibility into implementation internals, is difficult to use"); nginx has an internal RFC 7540 priority tree that's private to its core module, not reachable from third-party modules; `fasthttp/http2` parses the `PRIORITY` frame's weight and never reads it again anywhere. The real prior art turned out to be H2O (a genuine O(1) scheduler, but measurably unfair — Tempesta Tech's own simulation found only 2 of 256 streams got ideal scheduling against it), nghttp2 (correct WFQ, but O(n)), and [Tempesta FW](https://github.com/tempesta-tech/tempesta/pull/1973), who landed on WFQ backed by HAProxy's `ebtree` specifically for the 100-1000-stream range this kind of service would actually see. The plan, written up in `docs/EXPLORATION-HTTP2-Priority-Scheduler.md`, is a from-scratch server on `golang.org/x/net/http2.Framer` directly — bypassing the deprecated hook entirely — staged from a toy proving the interleaving works, up to real flow control, up to wiring in the actual image pipeline.

**A scale-up signal that knows when adding a worker won't help.** `scale()` only ever asks "is the queue long" — it has no way to tell a genuine burst apart from a backlog that's building because libvips's own thread pool is already saturated, in which case another Go worker just queues behind the same C-level pool without adding real capacity, while still paying for a decoded image buffer's worth of memory. I went looking for a way to read that saturation directly from govips and it isn't there: `ConcurrencyLevel` is write-only in practice (set once via `vips_concurrency_set`, read back only for a startup log line), and `RuntimeStats` tracks cumulative operation counts, not current thread-pool occupancy. libvips's underlying `GThreadPool` (GLib) does expose real introspection — `g_thread_pool_unprocessed()`, `g_thread_pool_get_num_threads()` — govips just never wraps it. The more practical fix doesn't need any of that: an atomic in-flight counter around each worker's `processor.Process()` call, gating `addWorkerLocked` when in-flight already matches `VipsConcurrency`. Documented as a finding, not built yet.

## Why open-source it now

The scaler is the part of this codebase I'd actually want other people to read, argue with, or reuse — a fairly small, self-contained piece of generic Go with real constraints (goroutine lifecycle, backpressure, graceful shutdown) that most worker-pool tutorials, mine included at the start, wave away. The rest of optimux — image/video transforms, S3 wiring, the HTTP surface — is useful but unremarkable by comparison.

Repo: **[github.com/go-batteries/optimux](https://github.com/go-batteries/optimux)**, AGPL-3.0.
