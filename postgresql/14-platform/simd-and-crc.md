---
title: "SIMD, CRC, and Hardware Acceleration"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "14-platform"
chapter_title: "Platform Layer"
chapter_url: "/postgresql/14-platform/"
---

# SIMD, CRC-32C, and Hardware Acceleration

## Summary

PostgreSQL exploits hardware-specific instructions for three performance-critical
operations: CRC-32C checksums (protecting WAL records and data pages), SIMD
vector comparisons (accelerating text searches and visibility checks), and
population count (used in bitmap operations). On multi-socket systems, the NUMA
abstraction layer ensures shared buffers are queried and placed on the correct
memory node. Each of these facilities uses a compile-time or runtime dispatch
mechanism to select the fastest available implementation, falling back to
portable C code when hardware acceleration is unavailable.

## Overview

The common thread across these facilities is **dispatch to the best available
hardware path**:

```
                       Compile time                Runtime
                    +---------------+          +-------------+
    CRC-32C:        USE_SSE42_CRC32C  -or->    function pointer
                    USE_ARMV8_CRC32C           selects SSE4.2 vs
                                               AVX-512 vs SB8

    SIMD:           USE_SSE2 / USE_NEON  -or-> USE_NO_SIMD
                                               (uint64 emulation)

    POPCNT:         __builtin_popcount   -or-> lookup table
                    POPCNT instruction         pg_number_of_ones[]

    NUMA:           USE_LIBNUMA          -or-> stub returning -1
```

## Key Source Files

| File | Role |
|------|------|
| `src/include/port/pg_crc32c.h` | CRC-32C API macros and dispatch logic |
| `src/port/pg_crc32c_sse42.c` | SSE4.2 hardware CRC implementation |
| `src/port/pg_crc32c_sse42_choose.c` | Runtime chooser: AVX-512 vs SSE4.2 vs SB8 |
| `src/port/pg_crc32c_armv8.c` | ARMv8 CRC extension implementation |
| `src/port/pg_crc32c_sb8.c` | Slicing-by-8 software fallback |
| `src/include/port/simd.h` | SIMD vector types and operations |
| `src/include/port/pg_bitutils.h` | Popcount, CLZ, CTZ, bit manipulation |
| `src/port/pg_bitutils.c` | Lookup tables for non-builtin platforms |
| `src/port/pg_popcount_x86.c` | x86 AVX-512 VPOPCNT accelerated popcount |
| `src/port/pg_popcount_aarch64.c` | ARM NEON accelerated popcount |
| `src/include/port/pg_numa.h` | NUMA query API |
| `src/port/pg_numa.c` | libnuma wrapper and stub implementation |

## How It Works

### CRC-32C: The Checksum Hot Path

Every WAL record and every data page (when `data_checksums` is enabled) is
protected by a CRC-32C checksum. The speed of this computation directly affects
write throughput and recovery time.

PostgreSQL defines four macros as the public interface:

```c
INIT_CRC32C(crc)          /* crc = 0xFFFFFFFF */
COMP_CRC32C(crc, data, len)  /* accumulate bytes */
FIN_CRC32C(crc)           /* crc ^= 0xFFFFFFFF */
EQ_CRC32C(c1, c2)         /* equality check */
```

The `COMP_CRC32C` macro is where dispatch happens. The implementation hierarchy:

```
+----------------------------------------------+
|           COMP_CRC32C(crc, data, len)        |
+----------------------------------------------+
           |                    |
  Compile-time known     Runtime dispatch
  USE_SSE42_CRC32C       via function pointer
           |                    |
           v                    v
  pg_comp_crc32c_dispatch()   pg_comp_crc32c -->  [one of:]
           |                                       |
  +--------+--------+              +---------------+---------------+
  |                 |              |               |               |
  Small constant    Large          AVX-512         SSE 4.2         SB8
  len < 32:         input:        (if CPUID       (if CPUID       (software
  inline            call via       confirms)       confirms)       fallback)
  _mm_crc32_u64     fn pointer
  _mm_crc32_u32
  _mm_crc32_u8
```

**The inline fast path** is a compile-time optimization for small, constant-size
inputs. When GCC or Clang can prove that `len` is a compile-time constant less
than 32, the computation is inlined directly using SSE4.2 intrinsics, avoiding a
function-call overhead:

```c
/* From pg_crc32c.h -- the dispatch function */
pg_attribute_target("sse4.2")
static inline pg_crc32c
pg_comp_crc32c_dispatch(pg_crc32c crc, const void *data, size_t len)
{
    if (__builtin_constant_p(len) && len < 32)
    {
        const unsigned char *p = data;
        for (; len >= 8; p += 8, len -= 8)
            crc = _mm_crc32_u64(crc, *(const uint64 *) p);
        for (; len >= 4; p += 4, len -= 4)
            crc = _mm_crc32_u32(crc, *(const uint32 *) p);
        for (; len > 0; --len)
            crc = _mm_crc32_u8(crc, *p++);
        return crc;
    }
    else
        return pg_comp_crc32c(crc, data, len);
}
```

**The runtime chooser** (`pg_crc32c_sse42_choose.c`) runs once at startup. It
uses CPUID to check for AVX-512 support (specifically the `vpclmulqdq`
instruction for parallel CRC) and sets the `pg_comp_crc32c` function pointer
accordingly.

**The software fallback** (slicing-by-8) processes 8 bytes per loop iteration
using eight 256-entry lookup tables. This is the fastest portable
implementation, roughly 10x slower than hardware CRC on modern CPUs.

### ARMv8 CRC Extension

On AArch64, the CRC32C instruction is part of the optional CRC extension
(mandatory in ARMv8.1+). The dispatch mechanism mirrors x86:

```c
/* Compile-time: known to have CRC extension */
#define USE_ARMV8_CRC32C

/* Or: runtime check via reading auxiliary vector */
#define USE_ARMV8_CRC32C_WITH_RUNTIME_CHECK
```

The runtime check reads `/proc/self/auxv` on Linux or uses
`sysctlbyname("hw.optional.armv8_crc32", ...)` on macOS to detect the
extension at process startup.

### SIMD Vector Operations

The `simd.h` header provides a platform-independent vector API for bulk
byte/word comparisons. The primary use cases are:

- **String scanning:** Finding null terminators, newlines, or delimiter bytes
  in large buffers (used by COPY, text input functions).
- **Visibility map checks:** Testing whether groups of heap pages are
  all-visible or all-frozen.

The type definitions adapt to the available instruction set:

```c
#if defined(USE_SSE2)
    typedef __m128i Vector8;     /* 16 bytes, 16 x uint8 */
    typedef __m128i Vector32;    /* 16 bytes, 4 x uint32 */
#elif defined(USE_NEON)
    typedef uint8x16_t Vector8;  /* 16 bytes, ARM NEON */
    typedef uint32x4_t Vector32;
#else
    #define USE_NO_SIMD
    typedef uint64 Vector8;      /* 8 bytes, bitwise emulation */
#endif
```

Key operations and their hardware mapping:

| Function | SSE2 | NEON | No-SIMD |
|----------|------|------|---------|
| `vector8_broadcast(c)` | `_mm_set1_epi8(c)` | `vdupq_n_u8(c)` | SWAR bit trick |
| `vector8_has(v, c)` | `PCMPEQB` + `PMOVMSKB` | `VCEQ` + reduce | byte loop |
| `vector8_has_zero(v)` | `PCMPEQB` zero + mask | `VMIN` + extract | SWAR null check |
| `vector8_has_le(v, c)` | `PMINUB` + compare | `VCLE` + reduce | byte loop |
| `vector8_highbit_mask(v)` | `PMOVMSKB` | shift + narrow + extract | not available |

The **SWAR (SIMD Within A Register)** fallback for `USE_NO_SIMD` packs 8 bytes
into a `uint64` and uses the classic null-byte detection trick:

```
To detect a zero byte in word w:
  ((w - 0x0101010101010101) & ~w & 0x8080808080808080) != 0
```

### Population Count (POPCNT)

Bitmap operations (visibility map, free-space map, relcache invalidation masks)
need to count set bits. PostgreSQL provides:

```c
/* Fast path: compiler builtin (often maps to POPCNT instruction) */
pg_popcount32(uint32 word)  /* __builtin_popcount */
pg_popcount64(uint64 word)  /* __builtin_popcountll */

/* Bulk: count bits in a byte array */
pg_popcount(const char *buf, int bytes)
```

On x86-64 with AVX-512 VPOPCNT, the bulk `pg_popcount()` processes 64 bytes
per iteration using `_mm512_popcnt_epi64`, delivering roughly 16x the
throughput of scalar POPCNT. On AArch64, the NEON path uses `VCNT` (count bits
per byte lane) with horizontal adds.

When no hardware popcount is available, a 256-entry lookup table
(`pg_number_of_ones[]`) provides the fallback.

### NUMA Awareness

On multi-socket servers, memory access latency depends on which NUMA node owns
the physical memory. PostgreSQL's NUMA layer (introduced in v18) provides
primitives for querying page placement:

```c
/* Initialize libnuma; returns -1 if unavailable */
int pg_numa_init(void);

/* Query which NUMA node each page resides on */
int pg_numa_query_pages(int pid, unsigned long count,
                        void **pages, int *status);

/* Get the highest NUMA node ID */
int pg_numa_get_max_node(void);
```

The implementation wraps Linux's `move_pages(2)` syscall (via
`numa_move_pages()` from libnuma), chunking queries into groups of 1024 pages
(or 16 on 32-bit systems, to work around a kernel bug in `do_pages_stat()`).

Before querying a page's NUMA node, it must be faulted into physical memory:

```c
static inline void
pg_numa_touch_mem_if_required(void *ptr)
{
    volatile uint64 touch pg_attribute_unused();
    touch = *(volatile uint64 *) ptr;
}
```

This volatile read forces the kernel to allocate a physical page, after which
`move_pages(2)` can report its NUMA node accurately.

On non-Linux platforms (or when libnuma is not available), all three functions
are stubs: `pg_numa_init()` returns -1, and the query functions are no-ops.

## Key Data Structures

### CRC-32C Dispatch

```
pg_comp_crc32c  (function pointer, set once at startup)
       |
       +---> pg_comp_crc32c_avx512()     (if AVX-512 + VPCLMULQDQ)
       +---> pg_comp_crc32c_sse42()      (if SSE 4.2)
       +---> pg_comp_crc32c_armv8()      (if ARMv8 CRC extension)
       +---> pg_comp_crc32c_loongarch()  (if LoongArch CRCC)
       +---> pg_comp_crc32c_sb8()        (software fallback)
```

### SIMD Type Map

```
          USE_SSE2                  USE_NEON               USE_NO_SIMD
  +-------------------+    +-------------------+    +------------------+
  | Vector8 = __m128i |    | Vector8 =         |    | Vector8 = uint64 |
  | (16 x uint8)      |    |   uint8x16_t      |    | (8 x uint8 SWAR) |
  |                   |    | (16 x uint8)      |    |                  |
  | Vector32 = __m128i|    | Vector32 =        |    | Vector32: N/A    |
  | (4 x uint32)      |    |   uint32x4_t      |    | (not implemented)|
  +-------------------+    +-------------------+    +------------------+
```

### NUMA Query Flow

```
  pg_numa_init()
       |
       v
  numa_available()  ----[fail]----> return -1 (NUMA disabled)
       |
     [ok]
       v
  pg_numa_query_pages(pid, count, pages[], status[])
       |
       +---> loop in chunks of NUMA_QUERY_CHUNK_SIZE (1024 or 16)
       |       |
       |       +---> CHECK_FOR_INTERRUPTS()
       |       +---> numa_move_pages(pid, chunk, &pages[i], NULL, &status[i], 0)
       |       |       (queries placement, does NOT migrate)
       |       +---> on error: return immediately
       |
       v
  status[] now contains NUMA node ID for each page
```

## Performance Characteristics

| Operation | Hardware path | Software fallback | Ratio |
|-----------|--------------|-------------------|-------|
| CRC-32C of 8 KB page | ~30 ns (SSE4.2) | ~1200 ns (SB8) | ~40x |
| CRC-32C of 8 KB page | ~15 ns (AVX-512) | ~1200 ns (SB8) | ~80x |
| `vector8_has()` on 16 bytes | 2 instructions | 16-byte loop | ~8x |
| `pg_popcount()` on 8 KB | ~50 ns (AVX-512 VPOPCNT) | ~800 ns (table) | ~16x |
| NUMA query, 1024 pages | ~50 us (move_pages) | N/A (returns 0) | -- |

## Connections

- **Chapter 5 (WAL):** Every `XLogRecord` header includes a CRC-32C computed over the entire record. The choice between SSE4.2 and software CRC directly impacts WAL write throughput and crash-recovery speed.
- **Chapter 4 (Buffer Manager):** When `data_checksums` is enabled, each 8 KB page carries a CRC that is verified on every read from disk. NUMA-aware buffer allocation ensures shared_buffers pages are local to the accessing CPU's memory node.
- **Chapter 9 (Query Execution):** SIMD vector operations accelerate sequential scan filters, COPY parsing, and text comparison functions in the executor.
- **Chapter 14 (this chapter), Atomics:** The CRC dispatch function pointer is itself set using atomic-safe initialization patterns to handle concurrent first-use scenarios.
