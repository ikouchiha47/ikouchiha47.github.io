---
title: "Spinlocks"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "05-locking"
chapter_title: "Locking"
chapter_url: "/postgresql/05-locking/"
---

# Spinlocks

Spinlocks are the lowest-level synchronization primitive in PostgreSQL. They
protect very short critical sections -- typically a few dozen instructions --
by busy-waiting until the lock becomes available. Spinlocks serve as the
foundation upon which lightweight locks are built.

## Overview

A spinlock is a single memory word that a CPU atomically tests and sets using
a hardware instruction (test-and-set, compare-and-swap, or load-linked /
store-conditional depending on the architecture). If the word is already set,
the caller spins in a tight loop, periodically backing off with increasing
delays, until the lock is released or a timeout fires.

Spinlocks provide **no** deadlock detection, **no** automatic release on
error, and **no** fairness guarantees. They exist purely because they are
extremely fast in the uncontended case: a single atomic instruction with no
kernel involvement.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/include/storage/s_lock.h` | Platform-specific TAS/TAS_SPIN macros, S_LOCK/S_UNLOCK API |
| `src/backend/storage/lmgr/s_lock.c` | Portable spin-wait loop with exponential backoff |
| `src/include/storage/spin.h` | Public API: `SpinLockInit`, `SpinLockAcquire`, `SpinLockRelease`, `SpinLockFree` |

## How It Works

### The Test-And-Set (TAS) Instruction

The core of every spinlock is the `TAS()` macro. On x86-64, this compiles to
a single `xchg` instruction (which has an implicit `LOCK` prefix):

```c
/*
 * Simplified from s_lock.h for x86-64:
 */
static __inline__ int
tas(volatile slock_t *lock)
{
    register slock_t _res = 1;

    __asm__ __volatile__(
        "lock; xchgb %0,%1\n"
        : "+q"(_res), "+m"(*lock)
        :
        : "memory");

    return (int) _res;   /* 0 = acquired, nonzero = failed */
}
```

On ARM (aarch64), an LDXR/STXR (load-exclusive / store-exclusive) pair is
used instead. The key requirement is **atomicity**: only one CPU can observe
the transition from unlocked to locked.

### The Spin-Wait Loop

When `TAS()` fails, `s_lock()` in `s_lock.c` enters a wait loop with
adaptive backoff:

```
s_lock(lock)
  |
  +-- init_spin_delay()
  |     spins_per_delay starts at DEFAULT_SPINS_PER_DELAY (typically 100)
  |
  +-- while TAS_SPIN(lock) fails:
  |     |
  |     +-- perform_spin_delay()
  |           |
  |           +-- If cur_delay < spins_per_delay:
  |           |     Spin (CPU pause / yield hint instruction)
  |           |     cur_delay++
  |           |
  |           +-- Else (exhausted spin budget):
  |                 pg_usleep(random delay between 1ms and 1s)
  |                 Increment delays counter
  |                 If delays >= NUM_DELAYS (1000):
  |                   PANIC -- "stuck spinlock detected"
  |
  +-- finish_spin_delay()
        Adapt spins_per_delay based on whether we had to sleep:
          - If we never slept: increase toward MAX_SPINS_PER_DELAY (1000)
          - If we slept a lot: decrease toward MIN_SPINS_PER_DELAY (10)
```

The adaptive algorithm is designed to handle both uniprocessor machines (where
spinning is wasteful because no other CPU can release the lock) and
multiprocessor machines (where a short spin is cheaper than a kernel sleep).

### Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `MIN_SPINS_PER_DELAY` | 10 | Minimum spin iterations before sleeping |
| `MAX_SPINS_PER_DELAY` | 1000 | Maximum spin iterations before sleeping |
| `NUM_DELAYS` | 1000 | Number of sleep cycles before PANIC |
| `MIN_DELAY_USEC` | 1,000 (1 ms) | Initial sleep duration |
| `MAX_DELAY_USEC` | 1,000,000 (1 s) | Maximum sleep duration |

With these settings, a stuck spinlock will PANIC after roughly 1-2 minutes.

### Memory Ordering

The TAS and S_UNLOCK macros include appropriate memory barriers:

- **TAS** must ensure that no loads or stores issued after the macro execute
  before the lock is obtained (acquire semantics).
- **S_UNLOCK** must ensure that all loads and stores issued before the macro
  complete before the lock is released (release semantics).

On x86-64, the `xchg` instruction provides a full memory fence implicitly.
On ARM and POWER, explicit barrier instructions (`dmb`, `lwsync`) are
emitted.

## Key Data Structures

```c
/*
 * slock_t is platform-dependent. On most platforms it is a simple
 * unsigned char or int:
 */
typedef unsigned char slock_t;   /* x86-64 */

/*
 * SpinDelayStatus tracks the adaptive backoff state:
 */
typedef struct SpinDelayStatus
{
    int     spins;         /* spin iterations so far in current cycle */
    int     delays;        /* number of times we called pg_usleep */
    int     cur_delay;     /* current delay counter */
    const char *file;      /* source location for diagnostics */
    int     line;
    const char *func;
} SpinDelayStatus;
```

### Spinlock Lifecycle

```
 SpinLockInit(lock)        SpinLockAcquire(lock)       SpinLockRelease(lock)
       |                          |                            |
       v                          v                            v
   *lock = 0              TAS(lock) == 0?                  *lock = 0
   (unlocked)             Yes: acquired                    + memory barrier
                          No:  enter s_lock() spin loop
```

## Usage Rules

The README in `src/backend/storage/lmgr/` lays out strict rules for spinlock
usage:

1. **Hold for at most a few dozen instructions.** Never hold a spinlock
   across a kernel call, subroutine call, or any operation that might block.

2. **No nested spinlocks.** There is no deadlock detection; acquiring a
   second spinlock while holding one risks permanent deadlock.

3. **Interrupts are deferred.** Query cancel and `die()` signals are held
   off while a spinlock is held. This prevents a backend from being killed
   while a shared data structure is in an inconsistent state.

4. **Do not use for user-visible locking.** Spinlocks are infrastructure for
   LWLocks and other internal mechanisms only.

## Platform Portability

`s_lock.h` contains a substantial block of `#ifdef` directives providing
TAS implementations for every supported architecture:

- **x86 / x86-64**: `xchgb` instruction
- **ARM (aarch64)**: `ldxr` / `stxr` pair with `dmb` barriers
- **POWER / PPC**: `lwarx` / `stwcx.` pair with `lwsync` / `isync`
- **Fallback**: If no hardware TAS is available, PostgreSQL falls back to a
  semaphore-based implementation, which is significantly slower.

The `SPIN_DELAY()` macro emits a "pause" or "yield" hint where available
(e.g., `PAUSE` on x86, `YIELD` on ARM) to reduce pipeline stalls and power
consumption during spinning.

## Diagram: Spinlock Acquisition Flow

```
  CPU 0                                CPU 1
    |                                    |
    |  TAS(lock) -> success (0)          |
    |  [lock = 1, CPU 0 owns it]        |
    |                                    |  TAS(lock) -> fail (1)
    |  ... critical section ...          |  spin... spin... spin...
    |                                    |  TAS_SPIN(lock) -> fail (1)
    |  S_UNLOCK(lock)                    |  pg_usleep(1ms)
    |  [lock = 0]                        |  TAS_SPIN(lock) -> success (0)
    |                                    |  [lock = 1, CPU 1 owns it]
    |                                    |  ... critical section ...
    |                                    |  S_UNLOCK(lock)
```

## Connections

- **LWLocks**: LWLocks were historically protected by internal spinlocks.
  Modern PostgreSQL uses atomic operations for the fast path, but the
  conceptual heritage remains. The `SpinDelayStatus` adaptive backoff is
  reused in LWLock wait loops.
- **Buffer Manager**: The buffer descriptor's state field uses atomic
  operations directly rather than spinlocks, but older versions used a
  per-buffer spinlock (`BufMappingLock`).
- **Shared Memory**: Any shared-memory data structure that needs very brief
  mutual exclusion (e.g., `shmem_alloc` during startup) may use a spinlock.
