---

active: true
featured: false
layout: group_index
title: "Building an Order Book"
subtitle: "an unglamorous journal about binary feeds, lying benchmarks, and one very patient std::map"
date: 2026-10-08 00:00:00
background_color: 'linear-gradient(135deg, #0b1220 0%, #132033 55%, #1f3350 100%)'
group: orderbook
hidden: false
sitemap: true
permalink: /orderbook/
---

I wanted a reason to write C++ that wasn't a leetcode problem.

The vague goal was "get good enough at low-latency systems to be taken seriously." The concrete version was: take a real NASDAQ order feed, rebuild its order book, and understand every byte and every nanosecond along the way. No tutorial. No framework. Just the feed and the code.

This is the journal of that. It's not a tutorial — I don't know enough yet to write one, and half of these posts are me getting things wrong and finding out. It's the stuff I'd want to remember: the byte that broke my parser, the benchmark that lied to me with a straight face, the afternoon I profiled my own code and found out 75% of the time wasn't my code at all.

The best part hasn't been the code. It's been the moment things snap into place — realising an order book is just millions of short biographies, or that the whole low-latency data-structure story reduces to one cache miss on one line. I wrote these down mostly so I don't forget them.

If you're doing the same thing, this is the order I'd read them in. If you're not, the one about the benchmark that said "0.98 nanoseconds" is a decent place to start.
