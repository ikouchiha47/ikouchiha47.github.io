---
title: "Locking"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "05-locking"
chapter_title: "Locking"
is_chapter_index: true
---

# Concurrency Control

PostgreSQL uses a layered locking architecture to coordinate concurrent access
to shared resources. Four distinct lock types form a hierarchy, each built on
top of the one below it and each trading off overhead for richer semantics.

## Overview

Concurrent access in PostgreSQL must solve two fundamental problems:

1. **Mutual exclusion** -- protecting shared-memory data structures (buffer
   headers, hash tables, WAL buffers) from corruption when multiple backends
   read and write them simultaneously.

2. **Transactional isolation** -- preventing user-visible anomalies such as
   dirty reads, lost updates, and serialization failures across SQL
   statements.

PostgreSQL addresses these problems through four lock types, arranged from
lightest to heaviest:

| Lock Type | Typical Hold Time | Deadlock Detection | Auto-Release on Error |
|-----------|-------------------|--------------------|-----------------------|
| Spinlock | Nanoseconds (tens of instructions) | No | No |
| LWLock (Lightweight Lock) | Microseconds to milliseconds | No | Yes (on `elog` recovery) |
| Heavyweight Lock | Milliseconds to hours | Yes | Yes (at transaction end) |
| Predicate Lock (SIRead) | Transaction lifetime and beyond | Via SSI conflict detection | Yes (when safe) |

```
+--------------------------------------------------------------+
|                     SQL Statement                            |
|  (SELECT, INSERT, UPDATE, DELETE, ALTER TABLE, LOCK TABLE)   |
+-------------------------------+------------------------------+
                                |
                                v
+--------------------------------------------------------------+
|              Heavyweight Locks  (lock.c, lmgr.c)            |
|  8 lock modes, conflict matrix, deadlock detection,         |
|  fast-path optimization, advisory locks                      |
+-------------------------------+------------------------------+
                                |
                                v
+--------------------------------------------------------------+
|              Lightweight Locks  (lwlock.c)                   |
|  Shared / Exclusive modes, atomic state variable,           |
|  OS-level sleep on contention, tranche-based organization    |
+-------------------------------+------------------------------+
                                |
                                v
+--------------------------------------------------------------+
|              Spinlocks  (s_lock.c, s_lock.h)                |
|  Hardware TAS instruction, busy-wait with backoff,          |
|  ~1 minute timeout then PANIC                                |
+-------------------------------+------------------------------+
                                |
                                v
+--------------------------------------------------------------+
|              Hardware Atomics  (atomics.h)                   |
|  CAS, fetch-and-add, memory barriers                         |
+--------------------------------------------------------------+

        Predicate Locks (predicate.c) operate alongside
        heavyweight locks but use entirely separate structures
        (SERIALIZABLEXACT, PREDICATELOCK, PREDICATELOCKTARGET).
```

## The Lock Hierarchy in Practice

A single `SELECT * FROM orders WHERE id = 42` touches multiple layers:

1. **Heavyweight lock**: `AccessShareLock` on the `orders` relation (often
   recorded via fast-path to avoid lock-manager contention).

2. **LWLock**: Shared lock on the buffer mapping partition LWLock to look up
   the page in the buffer pool, then a pin and shared content lock on the
   buffer itself.

3. **Spinlock**: Briefly held inside LWLock acquisition to perform atomic
   state transitions when the fast atomic path cannot succeed.

4. **Predicate lock** (if running at `SERIALIZABLE`): An SIRead lock on the
   tuple or page, used later by the SSI machinery to detect rw-conflicts.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/storage/lmgr/s_lock.c` | Spinlock wait loop with exponential backoff |
| `src/include/storage/s_lock.h` | Platform-specific TAS implementations |
| `src/backend/storage/lmgr/lwlock.c` | Lightweight lock acquire/release with atomic state |
| `src/include/storage/lwlock.h` | LWLock struct, mode enum, tranche IDs |
| `src/backend/storage/lmgr/lock.c` | Heavyweight lock manager: hash tables, conflict checks, fast-path |
| `src/include/storage/lock.h` | LOCK, PROCLOCK, LOCALLOCK structs; LOCKTAG types |
| `src/include/storage/lockdefs.h` | Lock mode constants (AccessShareLock through AccessExclusiveLock) |
| `src/backend/storage/lmgr/deadlock.c` | Wait-for graph construction and cycle detection |
| `src/backend/storage/lmgr/predicate.c` | SIRead predicate locks for SSI |
| `src/backend/storage/lmgr/lmgr.c` | High-level lock wrapper functions called by executor |
| `src/backend/storage/lmgr/proc.c` | PGPROC sleep/wakeup, wait queue management |
| `src/backend/storage/lmgr/README` | Authoritative design document for the lock manager |
| `src/backend/storage/lmgr/README-SSI` | Design document for predicate locking and SSI |

## Design Principles

**Interrupts are deferred while holding spinlocks or LWLocks.** Query cancels
and `die()` signals are held off until all such locks are released. This
prevents a backend from being killed mid-update of a shared data structure,
which would leave it in an inconsistent state. Heavyweight locks do not impose
this restriction -- a backend can be interrupted while waiting for a
heavyweight lock.

**No deadlock detection for spinlocks or LWLocks.** The code relies on
disciplined lock ordering and short hold times to prevent deadlocks at these
levels. Heavyweight locks provide full deadlock detection because user
transactions can request locks in arbitrary order.

**Partitioned shared-memory hash tables.** Both the heavyweight lock manager
and the predicate lock manager partition their hash tables (16 partitions
each) to reduce contention on the LWLocks that protect them.

**Fast-path optimization.** The most common heavyweight locks (weak relation
locks like `AccessShareLock`) bypass the shared hash table entirely, recording
the lock in a per-backend array inside the PGPROC structure. This eliminates
the lock-manager partition LWLock as a bottleneck for read-heavy workloads.

## Chapters

| Chapter | Topic |
|---------|-------|
| [Spinlocks](spinlocks) | Hardware TAS, busy-wait with backoff, platform portability |
| [Lightweight Locks](lwlocks) | Shared/exclusive modes, atomic state, wait queues |
| [Heavyweight Locks](heavyweight-locks) | Lock modes, conflict matrix, fast-path, partitioning |
| [Deadlock Detection](deadlock-detection) | Wait-for graph, soft/hard edges, queue rearrangement |
| [Predicate Locks](predicate-locks) | SIRead locks, rw-conflict detection, SSI |

## Connections

- **Buffer Manager** (Chapter 01): Every buffer access acquires LWLocks for
  the buffer mapping hash and per-buffer content locks.
- **WAL** (Chapter 04): WAL insertion acquires the `WALInsertLock` tranche
  (an array of LWLocks) to allow concurrent insertions.
- **Transactions** (Chapter 03): Heavyweight locks are released at transaction
  commit/abort. The `PGPROC` structure ties a backend's lock state to its
  transaction lifecycle.
- **MVCC**: Predicate locks exist precisely because MVCC's snapshot isolation
  is not sufficient for true serializability; SSI bridges the gap.
