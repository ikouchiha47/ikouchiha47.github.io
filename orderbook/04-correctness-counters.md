---
title: "The Counters That Save You"
subtitle: "or: how I learned to be paranoid about a book that runs fine"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 4
sitemap: false
---

My book was reconstructing a full trading day correctly and I was proud of it. Then I spent an afternoon trying to break it on purpose, and built the three counters I now consider the most valuable lines in the project.

A book can be wrong without ever crashing. That's the scary part.

## Three things that shouldn't happen, but do

**Unknown refs.** An execution or cancel naming an order I never saw. This is real — hidden liquidity, a symbol I filtered out, or a message that arrived late. And here's the trap: an `E` message carries no price. So when the ref is unknown, there is *no level to subtract from*. The only correct move is to count it and skip. Guess, and you corrupt a real level.

**Over-takes.** A reduce asking for more shares than are resting. Quantities are `uint32`, and subtracting past zero doesn't go negative — it wraps to four billion. So you floor at zero and count it. I found this one by staring at a `uint32` and thinking "what happens if I subtract 50 from 25?" Nothing good.

**Crossed books.** Best bid ≥ best ask. This is impossible in a real market — the exchange would have matched those orders the instant they crossed. So if *my* reconstruction shows it, *my* view is wrong. Out-of-order messages, a dropped add, or a bug. It's a transient, usually healed by the next message. Count it, don't panic.

## Why I count instead of ignore

Because "silent" is what kills you. An unknown ref I ignore is a hole I'll never see again. A wrapped quantity is a level claiming four billion shares. A crossed book means every quote I hand downstream is nonsense.

The counter turns "invisible" into "a number I can watch." And the number is the whole verdict:

```
counters: unknown_ref=0  clamped=0  crossed=0
```

Over a full day, one symbol, that line says the reconstruction held. That's a sentence I can actually stand behind.

## The duplicate that double-counts

This one is nasty because it *looks* fine. A duplicate add — same ref, twice. The obvious code is:

```cpp
orders[ref] = new_order;   // overwrite: looks fine
bids[price].total += qty;  // ...but the OLD qty is still summed in here
```

Overwriting the order entry is fine. The *level* is a separate sum, and it never got told the old order left. So it silently double-counts:

```
add(ref7, 100)  → bids[10.50] = {100, 1}
add(ref7,  50)  → orders[7] = {...50}, bids[10.50] = {150, 1}   ← ghost 100
```

The fix is to subtract the old contribution *before* filing the new. I went and checked how the open-source books handle this. Most of them don't. Only `nautilus_trader` unwinds the old level. That was weirdly reassuring — the bug is easy, and ignoring it is the default.

## Prove the hot path doesn't allocate

The last counter isn't a market condition, it's about my own code. I wanted "no allocation on the hot path" to be a *test*, not a comment. So I overrode `operator new` to count, warmed the book, snapshotted the count, ran a batch of reduce/best, and asserted the count hadn't moved:

```cpp
const uint64_t before = g_allocs.load();
book.reduce(ref, 10);
benchmark::DoNotOptimize(book.best());
const uint64_t after = g_allocs.load();
EXPECT_EQ(after - before, 0u);
```

The honest caveat: adding a *new* price level does allocate a node. So the assertion is about the read/reduce path, not everything. Which is exactly the point — a test that says precisely what it proves is worth ten that wave in a general direction.

My favourite kind of correctness work is the kind that catches nothing, because the alternative is the kind that catches something at 3am.
