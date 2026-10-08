---
title: "An Order Book Is a Biography"
subtitle: "the day the abstraction finally clicked"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 3
sitemap: false
---

For a week I understood the messages and still couldn't picture the book. Then one evening it clicked, and the sentence I wrote in my notes was: *the file is millions of little biographies, and the order book is the sum of every unfinished one.*

I've built a lot of features in my life that I can't remember. I'll remember that one.

## One order, four telegrams

Someone posts "buy 100 at $10.50." The exchange narrates that order's whole life in short messages:

```
A  ref7  B  100 @ 105000   → bid 10.50 shows 100   (born, resting)
E  ref7  30sh              → bid 10.50 shows 70    (30 sold into it)
X  ref7  20sh              → bid 10.50 shows 50    (20 cancelled)
D  ref7                    → bid 10.50 gone        (pulled)
```

`A` and `F` are births (`F` just signs the firm's name). `E` and `C` are bites taken by a stranger. `X` is the owner trimming. `D` is the owner giving up. `U` is a reincarnation — kill the old id, mint a new one, lose your place in the queue.

The bit that took me far too long: **only the birth carries the side and the price.** Every later message references the order by an 8-byte **ref** and nothing else. `E ref=539 shares=200` — that's it. No price, no side, no idea what it is unless the book *remembers*.

## Two maps, one truth

That constraint forces two views of the same money:

```cpp
std::unordered_map<uint64_t, Order> orders;   // by ref  → "what is order 8617?"
std::map<int64_t, Level> bids, asks;          // by price → the quoted rows
```

- `orders` is the only way to handle a bare `E ref=8617`. It's memory. It's how the book knows *what that ref was*.
- `bids`/`asks` hold the visible rows. A `Level` is the sum of everyone at one price: `total` shares across `count` orders.

They update together, every message:

```cpp
orders[7].qty -= 30;
bids[105000].total -= 30;
```

Update one and not the other and the book lies. There's no cleverness here, just discipline.

## A price level is a crowd

The thing I had to unlearn was thinking a "price level" is one order. It isn't — it's a **crowd**:

```
bids[10.50] = { total 175, count 3 }   →  "three orders, 175 shares"
```

Three different people, three different refs, same price. The level counts them. That's why `count` exists alongside `total`: one says *how much*, the other says *how many*. And it's why "same price" and "same ref" are completely different things — a mistake I'd been making in my head for days.

## Why the map is ordered

The two sides are separate maps on purpose. "Best bid" means the *highest* price with orders; "best ask" the *lowest*. If the container is ordered by price, best is a single peek at the edge — no scanning, ever. That one sentence is the entire reason to pay for a sorted structure instead of dumping everything in a hash map. It took me a while to see that the ordering *was* the feature.

The book stopped being a mystery the night I started reading it as biographies. Every message is one line in someone's order's life, and the book is whoever's still breathing.
