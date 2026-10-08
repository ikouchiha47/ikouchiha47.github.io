---
title: "Reading ITCH Bytes"
subtitle: "what 3.6 GB of NASDAQ data actually looks like"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 1
sitemap: false
---

The first thing I did was download a full day of NASDAQ data: `07302019.NASDAQ_ITCH50.gz`. Three and a half gigabytes, compressed. I opened it expecting to learn something about markets.

I learned that I had no idea what a market feed looks like on disk.

## I expected something I could read

Some part of me assumed there'd be lines. Maybe JSON, maybe CSV, maybe some neat tab-separated thing I could `less` through. I opened it in a hex viewer and got a wall of bytes that meant nothing to me.

Decompressed, it's one flat stream:

```
[2 bytes length][N bytes payload][2 bytes length][N bytes payload]...
```

No newlines. No commas. No keys. Just a length, then that many bytes, over and over, hundreds of millions of times. The honest thought in my head was: *where do I even start.*

## You start at the first bytes

I wrote a tiny reader — open the gzip, read two bytes, decode them as a length, read that many bytes — and printed the first twenty messages. That's all. No book, no strategy, just a dump.

```
#0 len=12 type=S locate=0
#1 len=39 type=R locate=1
#2 len=39 type=R locate=2
#3 len=39 type=R locate=3
```

It felt like finding a light switch. There *was* structure. The day opens with an `S` — a system event — and then a long run of `R`, thirty-nine bytes each. The exchange is publishing its symbol table before anyone trades.

## The shape of every message

Each payload turns out to have the same skeleton. First byte: the **type** — a letter, `S` for system event, `R` for a stock directory entry. Next two bytes: a **locate**, which is the exchange's per-day index for a stock. Then a timestamp and whatever fields that type needs.

I dumped one `R` with its bytes annotated:

```
52 | 00 01 | 00 00 | 0A 39 2D 5F 03 8C | 41 20 20 20 20 20 20 20 | ...
'R'  loc=1   track     timestamp            "A       "
```

`0x52` is `'R'`. Locate 1. And there, at byte 11, is the stock symbol — `"A"`, padded to eight bytes with spaces. I remember staring at that `41 20 20 20 20 20 20 20` for a while. It's just the letter A and seven spaces. It's been sitting in this file for years.

## Why it's built this way

Two choices that made no sense until they suddenly did:

- **Binary, fixed layout.** There are tens of millions of messages in a day. Parsing text costs more than the strategy. So fields sit at known offsets, and you never scan or escape anything.
- **Length-prefixed, not delimited.** You split the stream by reading a count and pulling that many bytes. There's no delimiter character because *any* byte can be part of a price — so a delimiter would need escaping, and a length prefix avoids the whole problem.

That second one is the kind of thing I'd never have designed on my own. It's obvious once you see it, and invisible until you do.

## What it actually gave me

By the end of an afternoon of just dumping bytes, I had the mental model that everything else would hang off:

- two bytes that say *how much*,
- one byte that says *what*,
- a locate that says *which stock*,
- and a tail that says *the details*.

I didn't write a parser that day. I just looked. And that turned out to be the right first move — because the data isn't the hard part. Figuring out what each byte is *for* is.
