---
title: "Parsing Binary ITCH Without Lying to Yourself"
subtitle: "endianness, offsets, and the day my own notes were wrong"
layout: group_page
group: orderbook
group_title: "Building an Order Book"
group_url: "/orderbook/"
nav_order: 2
sitemap: false
---

A parser is either provably correct or quietly wrong. There is no middle. This is the post where I learned that the hard way — and where I learned to stop trusting my own documentation.

## The byte-swap that doesn't crash

The feed is big-endian. My laptop is not. The lazy way to read a two-byte length is to reinterpret the bytes as a `uint16_t` — which, on a little-endian machine, silently flips them. No crash. Just a wrong number, forever.

The right way is arithmetic:

```cpp
inline uint16_t be16(const uint8_t* p) {
  return (uint16_t(p[0]) << 8) | uint16_t(p[1]);
}
```

High byte's value, shifted up, OR the low byte. It works on any machine because it operates on byte *values*, not on how memory happens to be laid out. I now do this by reflex for every multi-byte field, and prices too — `$140.99` is stored as the integer `1409900`, and it never becomes a float.

## I wrote the tests against the actual file

The single best decision of this whole project was refusing to test with made-up bytes. I dumped real payloads from the `.gz`, pasted them into the test, and asserted the decoded fields:

```cpp
EXPECT_EQ(add.ref, 8617u);
EXPECT_EQ(add.side, 'B');
EXPECT_EQ(add.shares, 600u);
EXPECT_EQ(add.price_ticks, 1409900u);
```

Parsing bugs don't throw. They produce numbers that look fine. A test against real bytes is the only thing between you and a book that quietly lies to you for a whole trading day.

## Then my notes were wrong

Here's the part that humbled me. I have this `C` message — "executed with price." My own notes said the price lived at bytes `31..34` and the printable flag at `35`. I wrote a test expecting `65900` (that's `$6.59`).

It failed. The parser produced `1308623105`.

That is not a stock price. That's a price of thirteen million dollars, or a garbage read. So I dumped six real `C` messages and looked at byte 31 by hand:

```
byte31 = 'N'      ← the printable flag
price (32..35) = 65900   ($6.59)   ← sane
```

Every single sample agreed. **Printable is at 31. Price is at 32..35.** My table had been off by one, and the old offsets had been reading the printable flag as the top byte of the price.

The spec I'd written — the thing I was treating as ground truth — was simply wrong. The file was right.

## What I actually took from it

Three habits, ranked by how much pain they saved me:

1. **Decode with arithmetic, not casts.** A misinterpreted pointer never tells you it's wrong.
2. **Test against real bytes.** Crafted inputs pass for the wrong reasons all day long.
3. **Assert sane values, not just equal values.** `$6.59` versus `$130,862,310` — the second one points at the bug before you even know the correct offset. It's the difference between a test that confirms a guess and a test that catches a mistake.

I stopped trusting my notes after that, and started trusting the bytes. Which, in hindsight, is the whole job.
