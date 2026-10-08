---
title: "What Jane Street's Exchange Taught Me"
subtitle: "one box, multicast, and a 30%-on-one-line punchline"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 8
sitemap: false
---

Somewhere in the middle of this project I watched Brian Nigito's talk on JX, the crossing engine Jane Street built. I expected it to be over my head. Instead it made my little book feel like the first chapter of a much longer book — and it gave me the sentence I keep coming back to.

Here's what stuck.

## They run it on one machine

The matching engine — the thing every trade in the market goes through — runs on **one commodity x86 box**, with the whole book in memory. No sharding at the core. Everything that *can* be pushed out, is: scheduled cancels, auctions, trade reporting, market data. All separate.

When they told a NASDAQ engineer this around 2002, he reportedly kept asking where the *real* system was. There wasn't one. It was that box.

## Multicast is the backbone

Every component — engine, client ports, market data — needs the *same* information at the *same* time. Sequential fan-out creates races. (He tells a great story about a naive connection list where, every morning at open, clients hammered the exchange just to be first in the list.) So they lean on **multicast**: the network replicates one packet to everyone at once.

The price is that multicast is UDP — messages drop. So they add **retransmitters** that record the sequenced stream so anything missed can be recovered.

## The locking idea I couldn't stop thinking about

Every message has a **topic** — think of it as its own lock, with its own sequence number. A port *proposes* the next transaction on its topic; if it loses the race, it rolls back, applies the winner, and retries. That's why each port keeps exactly **one unacknowledged transaction in flight**: rollback only ever has to remember one message.

The engine is the only thing that writes across topics (a trade touches both sides), and stale proposals are silently *dropped*, not rejected. The sender eventually sees reality and tries again.

## Determinism is the product

Every downstream app is written to apply the ordered stream deterministically, so any of them can be killed and rebuilt by replay in under thirty seconds. Failover is a human flicking a switch, not Paxos — consensus adds a round trip, and "I don't know of any exchanges that use it."

The payoff he keeps returning to: *"I know exactly what I knew at every point in time."* Testable, replayable, explainable. Determinism isn't a side effect of the design — it's the thing the design is *for*.

## And the punchline

Here's the bit I can't shake. He says that in a fast matching engine, roughly **30% of the time is spent on a single line** — dereferencing the order's index to find the order. It's a cache miss. The machine spends a third of its life waiting for memory.

Which is the same lesson as the tick ladder, arriving from the opposite direction. The hard part of low-latency systems isn't clever algorithms. It's arranging your data so the CPU doesn't have to go fetch it. That's why exchange engines use contiguous slots and array indices instead of pointers and trees — and why the little `std::map` in my toy book is, in miniature, exactly the thing they spent years engineering away from.

## What I take from it

I'm not building an exchange. But the direction is the same at every scale:

- index into preallocated slots, don't chase pointers,
- don't allocate in the critical path,
- make it deterministic so you can replay it,
- and understand that *speed is what buys you simplicity*, not the other way around.

I went back to my own code after the talk and understood why the next thing to build is a slab and a ladder. Not because a blog told me to. Because now I can see the cache miss.
