---
title: "std::map vs a Tick Ladder"
subtitle: "why an order book isn't a tree (and why I still haven't switched)"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 7
sitemap: false
---

My book stores prices in a `std::map`. It's correct, it's tested, and it is — by my own benchmarks — the most expensive thing I own. `add` is 14 ns, `remove` 18, `replace` 36. Every one of those nanoseconds is a red-black tree allocating a node and chasing a pointer to find a price.

Every serious order book I've read avoids this. I finally understood why, and then made the slightly annoying decision not to switch yet.

## The idea: index by price, don't search for it

A tick ladder is just an array where the index *is* the price:

```cpp
std::vector<Level> levels;   // levels[(price - base) / increment]
```

If prices are small integers and the range is bounded, lookup becomes a subtract and an array access. No node. No pointer chase. Contiguous memory, so a cache line holds several levels at once. That's the entire pitch.

Two numbers make it work:

- **base** — the lowest price in your window, so the index never goes negative.
- **increment** — the smallest price step. For a stock over a dollar, that's a penny.

Concretely, for a $141 stock with a ±10% window:

```
base      = $126.90  (1,269,000 in raw units)
upper     = $155.10  (1,551,000)
increment = $0.01    (100 raw units)
slots     = 2,820
memory    = 2,820 × 8 bytes ≈ 22 KB
```

Twenty-two kilobytes. It fits in cache. The tree's thousands of little heap nodes never will.

## The catch, and it's a real one

An array can't answer "what's the best price" in O(1) the way an ordered tree can. You fix that with a bitmap (a bit per price; best bid is one `countlZero`, best ask one `countTrailingZero`) or just a cursor you nudge on insert and rescan when the top empties.

And you have to pick a window. Prices leave it — a stock can fall 25% in a day. The usual answers: size with headroom, keep a cold `std::map` for the out-of-band tail (that's what `itchbook` does), or page the array so the range is effectively unbounded.

When I explained this to a friend who works on exchange software, he didn't even blink. "Yeah, that's the whole game," he said. Then he told me the number I haven't been able to stop thinking about: in a real matching engine, about **30% of the time is spent on one line** — dereferencing the order's index, because it's a cache miss. The cost isn't computation. It's memory access.

## So why haven't I switched?

Because I profiled first. The book is 15% of my replay; gzip is 75%. A faster tree swap is *invisible* in the macro number until the decompression is out of the way. I'd be optimising the 15% again, just more cleverly.

The order that makes sense: **decompress once, then ladder versus `std::map`**, and let the end-to-end run decide — not the micro-benchmark. It's the next experiment. I've written the ADR; I know the design; I'm just doing it in the order the profile told me to.

It's the least exciting conclusion and the most useful one: the right data structure at the wrong time is still the wrong thing to do.
