---
active: true
layout: post
title: "Bench & Perf"
subtitle: "Part 1: Journey to understanding system performance"
description: "understanding how to look for system performance"
date: 2024-11-07 00:00:00
background: 'purple'
---

# Part 1: Getting to know the tools

Hit that pause on the golang pprof tool, and look at perf  (on gentoo its dev-utils/perf , not sure about your 2 bit os)

## Premise

Reversing a slice. If we take a look at golang's source on slice.Reverse.

```go

func Reverse[S ~[]E, E any](s S) {
	for i, j := 0, len(s)-1; i < j; i, j = i+1, j-1 {
		s[i], s[j] = s[j], s[i]
	}
}
```

[Source](https://cs.opensource.google/go/go/+/refs/tags/go1.23.2:src/slices/slices.go;l=466)

*Vs.*

Another common implementation

```go
func Reverse[E any](elements []E) []E {
        n := len(elements)

        // Stripped of some of the code

        half := n / 2

        for i := 0; i < half; i++ {
                j := n - i - 1
                elements[i], elements[j] = elements[j], elements[i]
        }

        return elements
}
```

[Source](https://github.com/go-batteries/slicendice/blob/main/combine_permute.go#L183-L202)

We are gonna run some benchmarks.

```go
package main

import (
	"testing"
)

// Reverse by looping half the array
func reverseHalf(arr []int) {
	n := len(arr)
	for i := 0; i < n/2; i++ {
		j := n - i - 1
		arr[i], arr[j] = arr[j], arr[i]
	}
}

// Reverse by looping the entire array
func reverseFull(s []int) {
	for i, j := 0, len(s)-1; i < j; i, j = i+1, j-1 {
		s[i], s[j] = s[j], s[i]
	}
}

// Benchmark function
func BenchmarkReverseHalf(b *testing.B) {
	arr := make([]int, 10000)
	for i := 0; i < b.N; i++ {
		reverseHalf(arr)
	}
}

func BenchmarkReverseFull(b *testing.B) {
	arr := make([]int, 10000)
	for i := 0; i < b.N; i++ {
		reverseFull(arr)
	}
}
```

## Doing the thang

Makefile:

```Makefile
bench:
        go test -bench=.

gen:
        go test -c -o reverse_bench

perf.all: gen
        perf stat -e cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses,branch-misses,branches,L1-icache-load-misses,cycles,instructions ./reverse_bench -test.bench=BenchmarkReverseFull > result_full.txt 2>&1
        perf stat -e cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses,branch-misses,branches,L1-icache-load-misses,cycles,instructions ./reverse_bench -test.bench=BenchmarkReverseHalf > result_half.txt 2>&1
```

*zooming in a bit, because even i can't look at it.*

```shell
perf stat -e \
  cache-references\
 ,cache-misses\
 ,L1-dcache-loads\
 ,L1-dcache-load-misses\
 ,LLC-loads,LLC-load-misses\
 ,branch-misses,branches\
 ,L1-icache-load-misses\
 ,cycles,instructions ./reverse_bench -test.bench=BenchmarkReverseFull > result_full.txt 2>&1
```

Lets get off with the obvious make bench .

```shell
BenchmarkReverseHalf-8            330010              3624 ns/op
BenchmarkReverseFull-8            282148              4161 ns/op
```

 But in this benchmark I am using a fixed length array.
I would like to look at the performance over a range of arrays.

I am going to add two more benchmarks:

```go
func BenchmarkReverseDynamicHalf(b *testing.B) {
        b.N = 190168
        sizes := []int{1000, 10000, 100000, 1000000}

        // Disable GC during benchmarking
        b.Setenv("GODEBUG", "gcstoptheworld=1")

        for _, size := range sizes {
                b.N = size

                b.Run(fmt.Sprintf("ArraySize=%d", size), func(b *testing.B) {
                        arr := make([]int, b.N)

                        b.ResetTimer()
                        for i := 0; i < b.N; i++ {
                                reverseHalf(arr)
                        }
                })
        }
}
```

_same for reverse full_

#### Running the benchmarking again:

```shell
BenchmarkReverseHalf-8                    190168              5743 ns/op
BenchmarkReverseFull-8                    190168              7176 ns/op

BenchmarkReverseDynamicHalf/ArraySize=1000-8              134214            101721 ns/op
BenchmarkReverseDynamicHalf/ArraySize=10000-8             146358            117698 ns/op
BenchmarkReverseDynamicHalf/ArraySize=100000-8            143276            109742 ns/op
BenchmarkReverseDynamicHalf/ArraySize=1000000-8           180658            114818 ns/op

BenchmarkReverseDynamicFull/ArraySize=1000-8              166951            129158 ns/op
BenchmarkReverseDynamicFull/ArraySize=10000-8             166384            119364 ns/op
BenchmarkReverseDynamicFull/ArraySize=100000-8            177631            117992 ns/op
BenchmarkReverseDynamicFull/ArraySize=1000000-8           178808            114141 ns/op
```

> We don't see much deviation from the original result, the half iteration obviously, should take less time.
However the `ns/op` tend to converge as the array size increases.

But I want to look at the cpu performance, how the data flows.
One of these tool is perf. There are others like strace, gdb each serving different purposes. 

Below is a snippet from the man page.

```shell
$> man perf

NAME
       perf - Performance analysis tools for Linux
# yada yadaa

DESCRIPTION
       Performance counters for Linux are a new kernel-based subsystem that provide a framework for all things
       performance analysis. It covers hardware level (CPU/PMU, Performance Monitoring Unit) features and software
       features (software counters, tracepoints) as well.
```

```go
$> man perf stat

PERF-STAT(1)

NAME
       perf-stat - Run a command and gather performance counter statistics

SYNOPSIS
       perf stat [-e <EVENT> | --event=EVENT] [-a] <command>
       perf stat [-e <EVENT> | --event=EVENT] [-a] -- <command> [<options>]
       perf stat [-e <EVENT> | --event=EVENT] [-a] record [-o file] -- <command> [<options>]
       perf stat report [-i file]

DESCRIPTION
       This command runs a command and gathers performance counter statistics from it.
```

What we want to is check, as our bench mark test file runs, capture the events and show whatsup.

The event names can vary, but this works on my gentoo running on intel i7.

## Show me de rezults

*BenchmarkReverseHalf*

```go
goos: linux
goarch: amd64
pkg: github.com/go-batteries/slicendice/tests
cpu: Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
BenchmarkReverseHalf-8            190168              5938 ns/op
PASS

 Performance counter stats for './reverse_bench -test.bench=BenchmarkReverseHalf':

         2,091,237      cache-references:u                                                      (54.42%)
         1,535,745      cache-misses:u                   #   60.44% of all cache refs           (55.03%)
     1,876,225,405      L1-dcache-loads:u                                                       (55.28%)
       234,732,539      L1-dcache-load-misses:u          #   12.51% of all L1-dcache accesses   (55.49%)
           243,304      LLC-loads:u                                                             (37.74%)
           130,462      LLC-load-misses:u                #   53.62% of all L1-icache accesses   (36.50%)
           198,582      branch-misses:u                  #    0.01% of all branches             (36.24%)
     1,912,679,352      branches:u                                                              (36.07%)
            58,943      L1-icache-load-misses:u                                                 (35.94%)
     2,440,494,638      cycles:u                                                                (45.53%)
    11,340,624,609      instructions:u                   #    4.65  insn per cycle              (54.48%)

       1.138430212 seconds time elapsed

       1.120415000 seconds user
       0.019609000 seconds sys
```

*BenchmarkReverseFull*

```go
goos: linux
goarch: amd64
pkg: github.com/go-batteries/slicendice/tests
cpu: Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
BenchmarkReverseFull-8            190168              6974 ns/op
PASS

 Performance counter stats for './reverse_bench -test.bench=BenchmarkReverseFull':

         3,393,322      cache-references:u                                                      (54.67%)
         1,758,367      cache-misses:u                   #   51.82% of all cache refs           (55.06%)
     1,887,716,702      L1-dcache-loads:u                                                       (55.15%)
       236,253,730      L1-dcache-load-misses:u          #   12.52% of all L1-dcache accesses   (55.14%)
           136,517      LLC-loads:u                                                             (36.68%)
            56,342      LLC-load-misses:u                #   41.27% of all L1-icache accesses   (36.12%)
           193,339      branch-misses:u                  #    0.01% of all branches             (36.05%)
     2,834,599,781      branches:u                                                              (36.52%)
            68,149      L1-icache-load-misses:u                                                 (36.44%)
     2,977,524,085      cycles:u                                                                (45.45%)
    12,296,376,997      instructions:u                   #    4.13  insn per cycle              (54.41%)

       1.330565810 seconds time elapsed

       1.326694000 seconds user
       0.003345000 seconds sys

```

*BenchmarkReverseDynamicFull*

```shell
Performance counter stats for './reverse_bench -test.bench=BenchmarkReverseDynamicFull':

    66,521,152,504      cache-references:u                                                      (54.54%)
     1,906,065,494      cache-misses:u                   #    2.87% of all cache refs           (54.56%)
   269,042,150,174      L1-dcache-loads:u                                                       (54.56%)
    33,670,734,733      L1-dcache-load-misses:u          #   12.52% of all L1-dcache accesses   (54.59%)
     1,628,483,290      LLC-loads:u                                                             (36.40%)
        78,587,417      LLC-load-misses:u                #    4.83% of all L1-icache accesses   (36.37%)
         2,703,491      branch-misses:u                  #    0.00% of all branches             (36.36%)
   403,212,869,163      branches:u                                                              (36.36%)
        14,548,665      L1-icache-load-misses:u                                                 (36.35%)
   490,292,688,171      cycles:u                                                                (45.45%)
 1,614,240,594,864      instructions:u                   #    3.29  insn per cycle              (54.54%)

     163.769933238 seconds time elapsed

     162.543191000 seconds user
       0.565142000 seconds sys
```

*BenchmarkReverseDynamicHalf*

```shell
 Performance counter stats for './reverse_bench -test.bench=BenchmarkReverseDynamicHalf':

    65,813,989,153      cache-references:u                                                      (54.51%)
     1,559,375,185      cache-misses:u                   #    2.37% of all cache refs           (54.52%)
   265,659,475,560      L1-dcache-loads:u                                                       (54.55%)
    33,214,435,467      L1-dcache-load-misses:u          #   12.50% of all L1-dcache accesses   (54.58%)
     1,133,875,413      LLC-loads:u                                                             (36.42%)
        30,101,194      LLC-load-misses:u                #    2.65% of all L1-icache accesses   (36.41%)
         2,650,865      branch-misses:u                  #    0.00% of all branches             (36.39%)
   265,582,303,611      branches:u                                                              (36.35%)
         9,960,121      L1-icache-load-misses:u                                                 (36.34%)
   458,050,612,018      cycles:u                                                                (45.42%)
 1,861,193,621,352      instructions:u                   #    4.06  insn per cycle              (54.50%)

     132.351497920 seconds time elapsed

     131.743487000 seconds user
       0.433607000 seconds sys
```


## Key Metrics Explained

- **Cache References (cache-references)**, The total number of times the CPU attempted to read data from the cache.
- **Cache Misses (cache-misses)**, duh! The number of times a cache access was not fulfilled from any cache level and had to go to a slower memory source.
- **L1 Data Cache Loads and Misses**, CPU has different cache lines, L1, L2 , each having leser memory bandwith than the later, and faster than later.
- **LLC (Last Level Cache) Loads and Misses (LLC-loads and LLC-load-misses)**
- **Branch Misses and Branches (branch-misses and branches)**, Total number of branch instructions executed (if, for etc) and misses are the number of times it mis-predicted
- **L1 Instruction Cache Misses (L1-icache-load-misses)**
- **Instructions Executed pe CPU Cycles**

## Quick Overview

Benchmark: BenchmarkReverseHalf:

```shell
Cache miss rate: 60.44%
L1 data cache miss rate: 12.51%
LLC miss rate: 53.6%
Branch misprediction rate: 0.01%
Instructions per cycle (IPC): 4.65
Time Elapsed: 1.120 seconds
```

Benchmark: BenchmarkReverseFull:

```shell
Cache miss rate: 51.82%
L1 data cache miss rate: 12.52%
LLC miss rate: 41.27%
Branch misprediction rate: 0.01%
Instructions per cycle (IPC): 4.13
Time Elapsed: 1.331 seconds
```

Benchmark: BenchmarkReverseDynamicFull

```shell
Cache References: 54.54%
Cache Misses: 2.87% (of cache refs)

L1 DCache Loads: 54.56%
L1 DCache Load Misses: 12.52% (of L1 DCache accesses)

LLC Loads: 36.40%
LLC Load Misses: 4.83% (of L1 ICache accesses)

Branch Misses: 0.00% of all branches
L1 ICache Load Misses: 14,548,665
Instructions/Cycle: 3.29
Time Elapsed: 163.77 seconds
```

Benchmark: BenchmarkReverseDynamicHalf

```shell
Cache References: 54.51%
Cache Misses: 2.37% (of cache refs)

L1 DCache Loads: 54.55%
L1 DCache Load Misses: 12.50% (of L1 DCache accesses)
LLC Loads: 36.42%
LLC Load Misses:2.65% (of L1 ICache accesses)

Branch Misses: 2,650,865 (0.00% of all branches)
L1 ICache Load Misses: 9,960,121
Instructions/Cycle: 4.06 (instructions per cycle)
Time Elapsed: 132.35 seconds
```

## Analyzing the data

While for a fixed size array, we don't see too much deviation, between ReverseHalf and ReverseFull.
There are however a minor differences in:

- Instruction/Cycle, ReverseHalf seems to be better than ReverseFull
- LLC cache misses, The cache miss in general is more in the ReverseFull case
- Time for execution, is obviously faster for ReverseHalf

*The key takeway would be a tradeoff between the efficient cache utilization vs execution time.*

I was more interested in the next set of benchmarks. 

While looking at variations in length of array. We start to see the cache misses tend to become same.
But the execution time and cpu utilization is slightly better than ReverseFull. 

## Conclusion

Maybe in the larger scheme of things, this difference doesn't matter much,
which is why the go team might have not used the half logic.
Or atleast that I understood. For the time being, I will keep my implementation.
