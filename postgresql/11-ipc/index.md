---
title: "IPC"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "11-ipc"
chapter_title: "IPC"
is_chapter_index: true
---

# Chapter 11: Inter-Process Communication

PostgreSQL is a multi-process system. Every client connection gets its own backend
process, and a constellation of auxiliary processes (checkpointer, background writer,
WAL writer, autovacuum, etc.) runs alongside them. These processes must coordinate
constantly: they share buffer pages, transaction state, lock tables, and statistics.
The IPC subsystem provides the primitives that make all of this work.

---

## Why IPC Matters

A single `SELECT` touches IPC in at least three ways:

1. **Shared memory** -- the backend reads buffer pages and catalog caches that live
   in a memory region mapped into every process.
2. **ProcArray** -- to build a snapshot the backend scans dense arrays in shared
   memory that track every running transaction.
3. **Latches** -- when the backend needs to wait (for a lock, for WAL flush, for I/O
   completion) it sleeps on a latch that another process will set.

Parallel queries add two more:

4. **Dynamic shared memory (DSM)** -- the leader allocates a segment that workers
   attach to, holding query state and tuple queues.
5. **Shared-memory message queues (`shm_mq`)** -- workers stream result tuples back
   to the leader through lock-free ring buffers in that DSM segment.

---

## Subsystem Map

```
+----------------------------------------------------------------------+
|                        Postmaster (pid 1)                            |
|   Creates the main shared memory region at startup via shmem.c       |
+----------------------------------------------------------------------+
        |  fork()
        v
+------------------+  +------------------+  +------------------+
| Backend (pid N)  |  | Backend (pid M)  |  | Checkpointer     |
|                  |  |                  |  |                  |
| MyProc (PGPROC)  |  | MyProc (PGPROC)  |  | MyProc (PGPROC)  |
| procLatch        |  | procLatch        |  | procLatch        |
+--------+---------+  +--------+---------+  +--------+---------+
         |                     |                      |
         +----------+----------+----------------------+
                    |
         +----------v-----------+
         |   Main Shared Memory  |
         |                       |
         |  +------------------+ |
         |  | Shmem Index      | |   shmem.c -- hash table of named regions
         |  +------------------+ |
         |  | Buffer Pool      | |   bufmgr.c
         |  +------------------+ |
         |  | Lock Tables      | |   lock.c, lwlock.c
         |  +------------------+ |
         |  | ProcArray        | |   procarray.c -- dense XID arrays
         |  +------------------+ |
         |  | PGPROC[]         | |   proc.c -- per-process structs
         |  +------------------+ |
         |  | DSM Control      | |   dsm.c -- tracks dynamic segments
         |  +------------------+ |
         +-----------+-----------+
                     |
         +-----------v-----------+
         | Dynamic Shared Memory  |
         |  (per parallel query)  |
         |                        |
         |  shm_toc (TOC)         |
         |  shm_mq  (ring bufs)  |
         |  query state, params   |
         +------------------------+
```

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/storage/ipc/shmem.c` | Fixed shared memory allocator and Shmem Index |
| `src/backend/storage/ipc/ipci.c` | Orchestrates shared memory initialization at startup |
| `src/backend/storage/ipc/dsm.c` | Dynamic shared memory segment lifecycle |
| `src/backend/storage/ipc/dsm_impl.c` | Platform backends for DSM (POSIX, SysV, mmap, Windows) |
| `src/backend/storage/ipc/latch.c` | Latch set/reset/wait primitives |
| `src/backend/storage/ipc/waiteventset.c` | Multiplexed waiting (epoll/kqueue/poll/Windows) |
| `src/backend/storage/ipc/procarray.c` | ProcArray management and snapshot construction |
| `src/backend/storage/lmgr/proc.c` | PGPROC initialization and process sleep/wakeup |
| `src/backend/storage/ipc/shm_mq.c` | Single-reader single-writer shared memory queues |
| `src/backend/storage/ipc/shm_toc.c` | Table of contents for DSM segments |
| `src/backend/storage/ipc/pmsignal.c` | Postmaster signal management |
| `src/backend/storage/ipc/procsignal.c` | Inter-backend signaling (SIGUSR1-based) |
| `src/backend/storage/ipc/sinvaladt.c` | Shared invalidation message infrastructure |

---

## Chapter Roadmap

| Section | What You Will Learn |
|---------|---------------------|
| [Shared Memory](shared-memory.md) | How the main shared memory region is created and subdivided; dynamic shared memory for parallel queries; the four DSM implementation backends |
| [Latches and Wait Events](latches-and-events.md) | How processes sleep and wake each other; the Latch abstraction; WaitEventSet and its platform-specific implementations; the self-pipe trick vs epoll/kqueue |
| [ProcArray and PGPROC](procarray.md) | The PGPROC struct that represents every process in shared memory; how ProcArray tracks running transactions; how GetSnapshotData builds MVCC snapshots from dense arrays |
| [Message Queues](message-queues.md) | shm_mq ring buffers for parallel worker communication; shm_toc for organizing DSM segments; how parallel query moves tuples between processes |

---

## The Initialization Sequence

When the postmaster starts, `CreateSharedMemoryAndSemaphores()` in `ipci.c`
orchestrates the creation of the entire shared memory region:

1. **Calculate total size** -- `CalculateShmemSize()` calls every subsystem's
   `*ShmemSize()` function (e.g., `BufferShmemSize()`, `ProcArrayShmemSize()`,
   `LockShmemSize()`) and sums the results.

2. **Create the OS-level segment** -- `PGSharedMemoryCreate()` calls into the
   platform layer (`sysv_shmem.c` or `win32_shmem.c`) to allocate the region.

3. **Initialize the allocator** -- `InitShmemAllocator()` sets up the bump allocator
   that hands out chunks from the region.

4. **Initialize the Shmem Index** -- `InitShmemIndex()` creates the hash table that
   maps string names to locations within the segment.

5. **Initialize each subsystem** -- `CreateOrAttachShmemStructs()` calls every
   subsystem's `*ShmemInit()` function. Each one uses `ShmemInitStruct()` to either
   allocate a new chunk or attach to an existing one (important for `EXEC_BACKEND`
   platforms where backends cannot simply inherit pointers via `fork()`).

6. **Initialize DSM control** -- `dsm_postmaster_startup()` sets up the control
   segment that tracks all dynamic shared memory segments.

7. **Run extension hooks** -- `shmem_startup_hook` lets extensions like `pg_stat_statements`
   allocate their own shared memory regions.

---

## How IPC Connects to Other Subsystems

```
    Locking (Ch 5)                Transactions (Ch 3)
    LWLocks protect               Snapshots built from
    shared memory structures      ProcArray dense arrays
         |                              |
         +------+               +-------+
                |               |
                v               v
         +------+---------------+------+
         |       IPC Subsystem          |
         |  shmem, DSM, latches,        |
         |  ProcArray, shm_mq           |
         +------+---------------+------+
                |               |
         +------+               +-------+
         |                              |
         v                              v
    Buffer Manager (Ch 1)         Executor (Ch 8)
    Buffer descriptors and        Parallel query uses
    pages live in shared memory   DSM + shm_mq for workers
```

---

## Connections

- **Chapter 1 (Storage)** -- The buffer pool is the largest consumer of shared memory.
  Buffer descriptors, the buffer mapping hash table, and the actual page frames are
  all allocated from the main shared memory region during startup.

- **Chapter 3 (Transactions)** -- MVCC snapshots are built by reading ProcArray's
  dense XID arrays. The `xmin` horizon that controls tuple visibility and vacuum
  is computed from these same arrays.

- **Chapter 5 (Locking)** -- LWLocks and heavyweight locks both reside in shared
  memory. Latches are the sleep/wakeup mechanism underneath lock waits.

- **Chapter 8 (Executor)** -- Parallel query creates DSM segments, attaches `shm_toc`
  tables of contents, and uses `shm_mq` queues to stream tuples between the leader
  and worker processes.

- **Chapter 10 (Memory)** -- DSA (Dynamic Shared Area) builds on top of DSM to
  provide a `palloc`-like allocator within dynamic shared memory segments.

- **Chapter 12 (Replication)** -- WAL sender and receiver processes use latches and
  shared memory to coordinate streaming replication state.
