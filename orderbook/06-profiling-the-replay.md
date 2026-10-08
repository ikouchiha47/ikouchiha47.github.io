---
title: "Where the Time Actually Goes"
subtitle: "a stage split, a sampler, and the 75% that wasn't my code"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 6
sitemap: false
---

I had spent an embarrassing amount of time fussing over a `std::map`. Then I profiled the whole replay and discovered the map was 15% of the time and I'd been optimising noise.

This is the post that changed how I decide what to work on.

## Cheapest tool first: split the pipeline

You don't need a profiler to find the big number — you need a stopwatch and two stages. I added a `--stages` flag that times the read (`feed.next`: gunzip + framing) and the route (parse + book update), separately, per message.

```
stages: read=1.811s (85%)  route=0.319s (15%)
```

Eighty-five percent of the time is *getting* the bytes. Fifteen is *using* them. Every micro-benchmark I'd been staring at — the tree insert, the map erase — lives inside that fifteen.

One line reframed the whole project. I'd been optimising the wrong 15%.

## Second tool: prove it

macOS doesn't have `perf`, and the Homebrew gperftools didn't ship the `pprof` script I expected — so I used the built-in sampler on a live run:

```
sample <pid> 4 -file sample.txt
```

The call graph was almost funny in how blunt it was:

```
FeedReader::next → gzread → gz_read → gz_decomp → inflate_fast   ~64%
      + other inflate paths                                      ~7%
      + gz_read memmove + read(2) kernel                         ~6%
main (parse + book + loop)                                       ~13%
```

Roughly **75% of the replay is zlib's `inflate_fast`.** The decompression. Nothing I wrote. My entire order book was a rounding error next to stock zlib.

## Why that's not a shrug

My first instinct was "well, it's the gzip, nothing to do." But it's actually a decision, and a clean one:

- **The file is compressed; the live feed isn't.** A `.gz` is an artifact of *storage*, not of trading. Decompress it once to a raw `.bin` and zlib leaves the hot path entirely — `feed.next` becomes a memcpy. The 75% doesn't move somewhere else; it disappears.
- **If you must decompress on the fly,** `libdeflate`, `zlib-ng`, and `ISA-L` do it 2–3× faster than stock zlib.
- **The real target has no decompression at all.** A live feed is raw UDP multicast. The gzip only exists because I'm replaying yesterday.

## What I actually learned

Two-stage measurement is the minimum to avoid optimising a strawman:

1. Split the pipeline into stages, time each, find the big share.
2. Only *then* profile inside it.

If I'd skipped step one, I'd have spent a week building a tick ladder to make the 15% faster while the 85% sat there untouched. The micro-benchmarks weren't wrong. They were accurate, and they were pointing at the wrong problem.

I keep a note to myself now, taped to the top of the performance doc: *the profiler decides what to optimise; the benchmark only tells you if it worked.*
