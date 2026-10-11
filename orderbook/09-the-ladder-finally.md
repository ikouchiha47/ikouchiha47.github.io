---
title: "The Ladder, Finally"
subtitle: "a bitmap that jumps gaps, and the experiment that settled tree versus ladder"
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

## On the real feed

I wired the ladder in behind a flag and replayed the actual NASDAQ file, map versus ladder, on the same ten-million-message slice:

```
book=map      9.43M msgs/s   route 0.155s   best 141.0200 x 200 / 141.3900 x 200
book=ladder   9.70M msgs/s   route 0.150s   best 141.0200 x 200 / 141.3900 x 200
```

The two books land level — identical best, identical counters, both inside the noise. Gunzip owns eighty-five percent of the run, and it keeps that share.

What the ladder buys is shape. Bounded work per level, cache-friendly memory, and a worst case that stays fixed as instruments get thin — the sparse book went from 205 ns to 45 ns, and that number is the whole story. The micro-benchmarks showed the structure; the replay showed adopting it costs nothing; and that structure is the thing an exchange actually cares about.

The benchmark and the profiler finally agree.
