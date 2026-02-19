---
title: "Lightweight Locks"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "05-locking"
chapter_title: "Locking"
chapter_url: "/postgresql/05-locking/"
---

# Lightweight Locks (LWLocks)

Lightweight locks protect shared-memory data structures such as buffer
mapping tables, WAL insertion slots, and the lock manager's own hash tables.
They support shared (read) and exclusive (write) modes, use atomic operations
for the fast path, and put waiters to sleep on OS semaphores rather than
busy-waiting.

## Overview

LWLocks sit between spinlocks and heavyweight locks in the locking hierarchy.
They are fast enough for per-page or per-hash-partition protection (a few
dozen instructions in the uncontended case) yet rich enough to support
read/write semantics and ordered wakeup of waiters.

Key properties:

- **Two modes**: `LW_SHARED` (multiple readers) and `LW_EXCLUSIVE` (single
  writer, blocks readers).
- **No deadlock detection**: Code must acquire LWLocks in a consistent order.
- **Automatic release on error**: The `elog()` recovery path calls
  `LWLockReleaseAll()`, so it is safe to `ereport(ERROR)` while holding
  LWLocks.
- **Interrupts deferred**: Query cancel and `die()` are held off while any
  LWLock is held, preventing partial updates to shared structures.
- **Wait-free shared acquisition** when uncontended: A single atomic
  compare-and-exchange is sufficient.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/storage/lmgr/lwlock.c` | Acquire, release, wait queue management |
| `src/include/storage/lwlock.h` | `LWLock` struct, `LWLockMode` enum, tranche IDs |
| `src/include/storage/lwlocklist.h` | Enumeration of all individually-named LWLocks |
| `src/include/storage/lwlocknames.h` | Auto-generated names for individual LWLocks |

## How It Works

### The Atomic State Variable

Each LWLock contains a single `pg_atomic_uint32 state` that encodes both the
lock mode and holder count:

```
  Bit layout of LWLock.state (32 bits):
  +----+----+----+------------------------------+
  | 31 | 30 | 29 |  28 ... 0                    |
  +----+----+----+------------------------------+
    |    |    |       |
    |    |    |       +-- Number of shared lockers (up to ~500 million)
    |    |    +---------- LW_FLAG_RELEASE_OK: waiters may be released
    |    +--------------- LW_FLAG_HAS_WAITERS: wait queue is non-empty
    +-------------------- LW_VAL_EXCLUSIVE: lock is held exclusively

  LW_VAL_EXCLUSIVE  = (1 << 24)  -- sentinel for exclusive hold
  LW_SHARED_MASK    = ((1 << 24) - 1)  -- mask for shared holder count
```

### Acquisition Protocol (Four Phases)

The acquisition protocol addresses a subtle race: between the moment a backend
sees the lock is held and the moment it enqueues itself, the holder might
release. The four-phase protocol prevents missed wakeups:

```
LWLockAcquire(lock, mode)
  |
  +-- Phase 1: Atomic attempt
  |     If mode == LW_SHARED:
  |       atomic_fetch_add(&state, 1)  -- increment shared count
  |       If no exclusive holder: SUCCESS
  |       Else: undo the add, proceed to Phase 2
  |     If mode == LW_EXCLUSIVE:
  |       atomic_compare_exchange(&state, 0, LW_VAL_EXCLUSIVE)
  |       If succeeded: SUCCESS
  |       Else: proceed to Phase 2
  |
  +-- Phase 2: Enqueue on wait list
  |     Acquire lock->waiters spinlock (via atomic ops on state)
  |     Add PGPROC to lock->waiters list
  |     Set LW_FLAG_HAS_WAITERS
  |     Set my lwWaitMode, lwWaiting = LW_WS_WAITING
  |
  +-- Phase 3: Retry atomic attempt
  |     Try Phase 1 again (lock may have been released during enqueue)
  |     If succeeded: dequeue self, SUCCESS
  |
  +-- Phase 4: Sleep
        Call PGSemaphoreLock(proc->sem) -- block on OS semaphore
        When woken: goto Phase 1
```

### Release Protocol

```
LWLockRelease(lock)
  |
  +-- If held exclusively:
  |     atomic_sub(&state, LW_VAL_EXCLUSIVE)
  |   Else (held shared):
  |     atomic_sub(&state, 1)
  |
  +-- If new state == 0 and LW_FLAG_HAS_WAITERS is set:
        Acquire waiters list
        Walk the list:
          - Wake all waiting shared lockers (if no exclusive waiter ahead)
          - Or wake the first exclusive waiter
        PGSemaphoreUnlock(each woken proc->sem)
```

Waiters are woken in FIFO order. If the first waiter wants exclusive access,
only that waiter is woken. If the first waiter wants shared access, all
consecutive shared waiters are woken together.

## Key Data Structures

```c
typedef struct LWLock
{
    uint16          tranche;    /* identifies which group this lock belongs to */
    pg_atomic_uint32 state;     /* encodes exclusive/shared holders + flags */
    proclist_head   waiters;    /* list of waiting PGPROCs */
#ifdef LOCK_DEBUG
    pg_atomic_uint32 nwaiters;
    struct PGPROC   *owner;     /* last exclusive owner (debug only) */
#endif
} LWLock;

/* Padded to a full cache line to prevent false sharing */
typedef union LWLockPadded
{
    LWLock  lock;
    char    pad[PG_CACHE_LINE_SIZE];   /* typically 64 or 128 bytes */
} LWLockPadded;

/* The main array of pre-allocated LWLocks in shared memory */
extern LWLockPadded *MainLWLockArray;
```

### PGPROC Fields for LWLock Waiting

Each backend's `PGPROC` structure contains:

```c
/* In PGPROC: */
LWLockWaitState  lwWaiting;     /* LW_WS_NOT_WAITING, LW_WS_WAITING, LW_WS_PENDING_WAKEUP */
uint8            lwWaitMode;    /* LW_EXCLUSIVE or LW_SHARED */
proclist_node    lwWaitLink;    /* link in LWLock's waiters list */
PGSemaphore      sem;           /* semaphore for sleeping */
```

## Tranches: Organizing LWLocks

LWLocks are grouped into **tranches** for monitoring and debugging. Each
tranche has a name that appears in `pg_stat_activity.wait_event`:

```
MainLWLockArray layout:
+-------------------------------------------------------------------+
| Individual named locks        | Buffer mapping | Lock manager     |
| (BufFreelistLock,             | partitions     | partitions       |
|  CheckpointerCommLock, ...)   | (128 locks)    | (16 locks)       |
| NUM_INDIVIDUAL_LWLOCKS        |                |                  |
+-------------------------------+----------------+------------------+
| Predicate lock manager partitions (16 locks)                      |
+-------------------------------------------------------------------+
```

Additional tranches are allocated dynamically for:
- Per-buffer content locks (one per shared buffer)
- WAL insertion locks (one per WAL insertion slot)
- Extension-requested tranches via `RequestNamedLWLockTranche()`

### Partitioning Constants

```c
#define NUM_BUFFER_PARTITIONS          128
#define NUM_LOCK_PARTITIONS             16   /* 2^4 */
#define NUM_PREDICATELOCK_PARTITIONS    16   /* 2^4 */
```

## Diagram: LWLock State Transitions

```
                    atomic_fetch_add(1)
            +------ UNLOCKED (state=0) ------+
            |                                 |
            v                                 v
   SHARED (state=N)                  EXCLUSIVE (state=LW_VAL_EXCLUSIVE)
   N = number of shared holders      Only one holder
            |                                 |
            | atomic_sub(1)                   | atomic_sub(LW_VAL_EXCLUSIVE)
            | if N-1 > 0: still shared        |
            | if N-1 == 0: unlocked           |
            |                                 |
            +--------> UNLOCKED <-------------+
                           |
                    If HAS_WAITERS flag set:
                    wake appropriate waiters
```

## The LWLockWaitForVar Pattern

LWLocks support a special pattern for waiting until a protected variable
changes value, without holding the lock:

```c
bool LWLockWaitForVar(LWLock *lock,
                      pg_atomic_uint64 *valptr,
                      uint64 oldval,
                      uint64 *newval);
```

This is used by the WAL subsystem: a backend waiting for WAL to be flushed
calls `LWLockWaitForVar()` on the WAL write lock, waiting until the flush
position advances past the desired LSN. The lock holder periodically calls
`LWLockUpdateVar()` to publish progress and wake waiters whose condition is
now satisfied.

## Performance Considerations

**Cache-line padding.** Each LWLock is padded to a full cache line (64 or 128
bytes) to prevent false sharing. Without padding, two unrelated locks on the
same cache line would cause cross-CPU cache invalidation traffic on every
acquisition.

**Wait-free shared path.** The common case of acquiring a shared lock on an
uncontended LWLock is a single `atomic_fetch_add` -- no spinlock, no kernel
call, no cache-line bouncing beyond the lock's own line.

**Tranche-level monitoring.** Because each tranche is named, `EXPLAIN
(BUFFERS)` and `pg_stat_activity` can report exactly which LWLock a backend is
waiting on (e.g., `LWLock:BufferMapping`, `LWLock:WALInsert`), making
contention analysis straightforward.

## Connections

- **Spinlocks**: LWLocks originally used spinlocks internally; modern
  PostgreSQL replaced them with atomic operations for the common path but
  retains the adaptive backoff logic from the spinlock implementation.
- **Buffer Manager**: Every buffer lookup acquires a shared LWLock on the
  buffer mapping partition. Every buffer read/write acquires a shared or
  exclusive buffer content lock (also an LWLock).
- **WAL**: The `WALInsertLock` tranche allows multiple backends to insert WAL
  records concurrently into different WAL insertion slots.
- **Heavyweight Locks**: The lock manager's shared hash tables are protected
  by 16 LWLock partitions (`LockManagerLock` tranche). Fast-path lock
  promotion also requires briefly holding a per-backend LWLock.
- **Replication**: `ReplicationSlotLock` and `ReplicationOriginLock` protect
  replication slot state in shared memory.
