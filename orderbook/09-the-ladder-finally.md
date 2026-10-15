---
title: "The Ladder, Finally"
subtitle: "a bitmap that jumps gaps — and the counters that finally explained the slope"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 9
sitemap: false
---

The biggest open question in my book was the price-level container: the `std::map` I started with, or a tick ladder. The profiler post told me to decompress before optimising anything, and I took that seriously. But this was the decision I kept circling, and I wanted it settled properly — so I built the ladder and let the numbers argue it out.

Two things had to hold before I'd switch. The ladder had to survive a *sparse* book, and adopting it had to cost nothing on the real feed.

## The part an array can handle, and the part it can't

An array answers "level at this price" in O(1): a subtract and an index, contiguous memory, no allocation. The best price needs a second structure, and the bitmap is it.

One bit per price slot: set on the first order at that price, cleared when the level empties. Best bid is a single instruction:

```
best slot = 63 - countl_zero(leaf_word)     // highest set bit = best bid
```

One word gives the best price within itself. Reaching across a sparse book needs a bitmap of that bitmap — one bit per word of the level below, and a third above:

```
root_     1 bit per summary word
summary_  1 bit per leaf word
leaf_     1 bit per slot          <- the actual prices
```

A bit at one level means "the word below me is non-empty." The best price becomes a three-load descent, root → summary → leaf: bounded, contiguous, allocation-free.

## Then a sparse book bit me

Dense, the ladder was great. Two hundred levels a penny apart, and it tied the map on `add`, took `replace` and `depth` outright. Then I made the book sparse, the way a quiet stock actually looks, and depth fell off a cliff:

```
gap 100   (1 slot apart)    depth(5)    39 ns
gap 1000  (10 slots)                    57 ns
gap 5000  (50 slots)                   205 ns
```

`top()` found the best slot in O(1), then walked slot by slot, checking each for occupancy until it had collected five levels. On a dense book those slots *are* the levels. On a sparse one they sit among long stretches of empty space — fifty dead checks per level, five levels deep.

The fix asks the bitmap a sharper question: **the next occupied slot.**

```cpp
int prev_occupied(int slot) {
  uint64_t m = leaf_[slot >> 6] & ((1ull << (slot & 63)) - 1);  // keep bits below slot
  if (m) return (slot >> 6) * 64 + (63 - countl_zero(m));       // highest set bit
  // else climb one level and ask the same question about *words*
}
```

When the word has nothing below, climb a tier and ask again — same mask, same `countl_zero`, one level up. That recursion is the whole hierarchy. Afterwards:

```
gap 100  → 47 ns      gap 1000 → 41 ns      gap 5000 → 45 ns
```

Flat. Depth costs O(levels) whether prices sit adjacent or fifty cents apart.

## What the sweep says

With the walk gone I ran the full grid — levels 100 / 1k / 10k against gaps 100 / 1k / 5k:

```
add/remove a NEW level      map          ladder
  N=100                     43.7 ns      30.9 ns
  N=1000                    54.9         32.2
  N=10000                   71.4         32.5     // ladder flat
```

The map's cost climbs with N: the tree gets deeper, cache misses multiply, and every level birth and death is a `malloc`/`free`. The ladder's cost stays flat: an index and a bit flip. That gap is a slope, and it's why the structure earns its place.

## The why my laptop wouldn't give me

The slope was clear; the *reason* needed hardware counters, and macOS has no `perf`. Valgrind and Instruments were dead ends on this machine too, so I rented a Linux box — an arm64 Graviton (the closest thing AWS has to the M4) and an x86 box — built the same probe there, and ran `perf stat`.

At a million levels per side, per add-and-remove:

```
                    Graviton3    Sapphire Rapids
cycles/op           931          961
instructions/cycle  1.6          1.5
L1d misses/op       27           34
```

The map's fourfold cycle cost is **misses**. Twenty-seven cache misses per operation, instructions-per-cycle sagging to 1.5 — the machine spends its time waiting on memory. The ladder, on the same workload:

```
cycles/op           223          230
instructions/cycle  3.8          3.7
L1d misses/op       0.006        0.005
```

It touches three bitmap words and one level per operation, and misses almost never. That is the whole difference between the two books in one number: **27 misses per op, against 0.006.** Everything the dense bench hid, and everything the sweep implied, the counters turned into a mechanism.

## What the profiler added

Counters say *how much*; a flamegraph says *where*, and an allocation counter says *which* alloc. Two quick ones.

Allocations per operation, a million-level book:

```
             allocs/op   what
map          2.0         order-ref node + a tree node for the level
ladder       1.0         order-ref node only; the level is a preallocated slot
```

The map's extra allocation is exactly one tree node per operation. And the count holds flat across size — two at a thousand levels, two at a million — so allocation is a constant, and the thing that *grows* is the misses above. The two profiles interlock.

The flamegraph surfaced one more thing I hadn't noticed:

```
map      add 33%    refresh 27%
ladder   depth 24%  refresh 9%
```

`refresh` — the per-message lookup of the top-of-book *size* — is a quarter of the map's work. I had cached the best *price*; the *size* still resolved on every message, and on the map that is a tree walk.

## Closing that loop

The flamegraph said *where*: `refresh`. To find *where the improvement could be*, I read the function and broke down what it does per message:

```
refresh():
  best_bid() / best_ask()        cheap — a cached scalar / the tree edge
  find_level(best_px, side)      the lookup — a tree walk on the map
  copy into the cached top       cheap
```

`find_level` is the only real work, and it is redundant: it fetches the best level's *size*, which the book already knows at the exact moment the size changes. A value that gets recomputed every message but is known at an event is the one to cache.

So I cached the size next to the price, in both books, and moved the two together:

```cpp
// add: a better price is a new level; the same price grows it
if (px >  best_bid_) { best_bid_ = px; best_bid_sz_ = qty; }
if (px == best_bid_) { best_bid_sz_ += qty; }
// reduce/remove: subtract, and rescan the size only when the best level empties
```

`refresh` became three cached reads. A million levels, add-and-remove:

```
                 before   after
map              223 ns   163 ns    −27%
ladder            30 ns    26 ns    −15%
```

And the flamegraph afterwards:

```
map      add 38%   erase_order 31%     // refresh has left the top
ladder   depth 27% erase_order 10%
```

The function dropping out of the profile is the proof the time moved out of that code. On the real feed it moved nothing — 0.158s against 0.156s — and that fits: the probe changes the best price on every operation, while the replay changes it rarely, and this win lives inside the fifteen-percent route stage. It is waste removed, and the throughput number stays owned by gunzip.

## On the real feed

I wired the ladder in behind a flag and replayed the actual NASDAQ file, map versus ladder, on the same ten-million-message slice:

```
book=map      9.43M msgs/s   route 0.155s   best 141.0200 x 200 / 141.3900 x 200
book=ladder   9.70M msgs/s   route 0.150s   best 141.0200 x 200 / 141.3900 x 200
```

The two books land level — identical best, identical counters, both inside the noise. Gunzip owns eighty-five percent of the run, and it keeps that share.

What the ladder buys is shape. Bounded work per level, cache-friendly memory, and a worst case that stays fixed as instruments get thin — the sparse book went from 205 ns to 45 ns, and that number is the whole story. The micro-benchmarks showed the structure; the counters showed the mechanism; the replay showed adopting it costs nothing; and that structure is the thing an exchange actually cares about.

The benchmark, the profiler, and the counters finally agree.
