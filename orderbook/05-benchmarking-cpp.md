---
title: "Benchmarking C++ Without Lying to Yourself"
subtitle: "the compiler told me 0.98 nanoseconds and I believed it"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 5
sitemap: false
---

I almost shipped a benchmark that said parsing a NASDAQ message takes **0.98 nanoseconds**. That's about three CPU cycles. For decoding sixteen bytes across three fields.

I was proud of it for about ten minutes, which is exactly how long it took a friend to ask "why is it faster than a memory access?" Then I got suspicious, and then I got annoyed, because the compiler had been lying to me with a perfectly straight face and I'd been the one holding the pen.

## The trap is that the answer looks plausible

Google Benchmark works like Go's `testing.B`. You write a loop, it decides how many iterations to run until it has enough samples. Mine ran ~163 million iterations and reported 0.98 ns.

The number is wrong for a boring reason: **the compiler deleted my parser.**

I had written `DoNotOptimize(parse_A(d, out))`. That pins the *return value* — a `bool`. It says nothing about the struct the function filled in. So the compiler looked at the writes to `out`, saw nobody ever read them, and quietly removed the whole decode. I was benchmarking an empty loop.

The fix is to pin the thing that matters — the output:

```cpp
parsers::nasdaq::parse_A(d, out);
benchmark::DoNotOptimize(out);
```

Now the fields have to actually be computed. The number went up to a bizarrely large... 1.77 ns. Still fast. Still *real*.

## And then a second lie

Even with the output pinned, `d` was the same bytes every iteration, so the compiler computed the result once and reused it. Loop-invariant hoisting — the benchmark measured a register read.

So I made the input move:

```cpp
d[19] ^= 1;   // flip the side byte each iteration
```

Now it can't cache the answer. Honest number: **1.77 ns.** I trust it now, and honestly it's *more* impressive than the fake one, because it's true.

## Read the right number

Here's the shape of the output once you turn on repetitions:

```
BM_BookReduce_median   3.42 ns
BM_BookReduce_stddev   0.037 ns
BM_BookReduce_cv       1.07 %
```

- Use the **median**, not the mean. Tails don't move a median.
- Watch the **cv** — under ~2% is stable, over ~5% means the machine was noisy and the number is fiction.
- Compare **Time** and **CPU**. Equal means pure compute. If Time is much bigger, you're waiting on I/O or a lock, and you're measuring the wrong thing.

## The part that actually humbled me

I had a beautiful table of micro-benchmarks:

| op | ns |
|---|---|
| parse A/F/X | 1.7–2.0 |
| best() | 0.32 |
| reduce | 3.3 |
| add / remove | 14 / 18 |
| depth(5) | 42 |

And none of it was the point. When I profiled the *whole* replay, it ran at **11 million messages per second** — about 90 ns per message — and ~75% of that was gzip decompression. The order book I'd been micro-optimising was a rounding error in the real workload.

That's the lesson I keep failing to internalise: micro-benchmarks make the thing you measured look important. Only the macro run and a profiler tell you whether it actually is. The micro numbers are accurate. Accurate and irrelevant is the most expensive kind of result, because it's so easy to act on.
