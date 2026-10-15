---
title: "Reading the Feed"
subtitle: "two freads per message, a 1 MiB block, and a benchmark that kept changing its mind"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 10
sitemap: false
---

The profiler post ended with a promise: decompress once, then compare. This is what happened when I did it. The interesting part turned out to be the reader, and then a benchmark I trusted too early.

## Get gunzip out of the way

The trace made this easy — about 75% of the replay was zlib's `inflate_fast`. A `.gz` is an artifact of storage, and a live feed has none, so decompress it once and be done:

```
gunzip -c 07302019.NASDAQ_ITCH50.gz > 07302019.bin
```

8.66 GB of raw, length-prefixed ITCH. I'd first put a decompressor inside the C++ tool; a `gunzip -c` line does the same job and keeps the binary out of the storage business, so it moved to the shell. With the `.bin` in place, zlib left the hot path and throughput went from 11.16M to 15.6M messages/second — the first time the book's own cost was visible at all.

## Then reading became the bottleneck

I re-measured the split and "read" was *still* 74% of the run — with no decompression in it. That made no sense until I compared it to `cat`:

```
cat 07302019.bin > /dev/null   →   8.66 GB in 3.3 s
```

The disk hands over the bytes in three seconds; the replay spent thirteen. So "read" was CPU, and the CPU was the framing: every message cost **two `fread` calls** — one for the 2-byte length prefix, one for the payload.

```
282,000,000 messages × 2 = ~564,000,000 fread calls
```

`fread` is buffered, so none of those reach the disk — but each still costs a call's worth of overhead, and half a billion of them add up. The fix is the oldest trick in the book: read a **1 MiB block** at once, then hand out messages from that block in memory. One change: 18.08 s → 6.40 s.

## Making the reader honest

With the block buffer in, the reader had grown a mode flag and a branch inside `next()`. The source — gzip stream or raw file — is a detail the framing code should never ask about, so I split it:

```cpp
GZSource        // gzip, via zlib
RawSource       // the .bin, via ifstream
FeedReader<Buf> // frames messages; knows only the buffer
```

`FeedReader` is a template, the same shape as `NasdaqBookParser<Book>`. It calls `buf_.want(2)`, `buf_.data()`, `buf_.consume(n)`, and whichever concrete buffer sits underneath resolves at compile time. No branch, no base class, no runtime dispatch.

## Two buffers, one answer

Then I built the buffer twice, to see whether the shape mattered:

- `BlockBuf` — a real `std::streambuf`, cursor as the get-area pointers (`gptr`/`egptr`);
- `LinearBuf` — a plain class: a 1 MiB vector and two integers, `pos_` and `avail_`.

Same five methods on both. The result:

```
per-field reads (read() per message)   ~29.6M msgs/s
either block buffer                    ~40M msgs/s
```

The two block buffers matched each other. Which is the useful part: **the win is reading in blocks and framing in memory**; the buffer's implementation shape sits inside the error bars. `std::streambuf` earns its keep through API compatibility, and a framed reader that pulls its own bytes has no use for that.

## The benchmark kept changing its mind

Here's the honest bit. My single runs gave 44M, then 40M, then 33M, then 29M for the *same build*. I spent a while explaining a 9% gap between the two buffers before doing the thing I should have done first — run it eight times and look at the spread:

```
mean 6.918 s ± 0.060 s   (8 runs)
```

Spread under 1%, and the two buffers inside it. The 9% "gap" was noise, and I had written a paragraph of mechanism to explain it. The rule from the profiling post holds: find the big number first, then measure the change with repeats and read σ. A single run tells you which way the wind blew that minute.

## What I kept

The source split and `LinearBuf`. `BlockBuf` is committed but commented out — the "standard library" version, kept with a note. So the reader reads in blocks, frames in memory, and the gzip-or-file question lives in one small type. The buffer shape is a detail; the block read is the win.
