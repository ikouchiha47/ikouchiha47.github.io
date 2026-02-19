---
title: "Message Queues"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "11-ipc"
chapter_title: "IPC"
chapter_url: "/postgresql/11-ipc/"
---

# Shared Memory Message Queues

When a parallel query runs, the leader process must exchange data with its workers:
sending query parameters, receiving result tuples, and relaying error messages.
PostgreSQL uses two primitives for this: **shm_mq** (a lock-free ring buffer for
streaming bytes between exactly one sender and one receiver) and **shm_toc** (a
simple table of contents that maps integer keys to addresses within a DSM segment).

---

## Overview

The parallel query communication stack has three layers:

1. **DSM segment** -- A chunk of dynamic shared memory created by the leader and
   attached by each worker (see [Shared Memory](shared-memory.md)).

2. **shm_toc** -- A table of contents at the start of the DSM segment that lets
   each participant find the data structures it needs by key.

3. **shm_mq** -- Ring buffers allocated within the DSM segment, one per
   communication channel (typically one error queue and one tuple queue per worker).

```
DSM Segment
+------------------------------------------------------------+
| shm_toc (header + entries)                                 |
|   key 0 -> query text                                      |
|   key 1 -> serialized PlannedStmt                          |
|   key 2 -> serialized params                               |
|   key 3 -> shm_mq[0] (worker 0 tuple queue)               |
|   key 4 -> shm_mq[1] (worker 1 tuple queue)               |
|   key 5 -> shm_mq[2] (worker 0 error queue)               |
|   key 6 -> shm_mq[3] (worker 1 error queue)               |
|   ...                                                       |
| [allocated chunks referenced by TOC entries]                |
+------------------------------------------------------------+
```

---

## Key Source Files

| File | Role |
|------|------|
| `src/include/storage/shm_mq.h` | shm_mq public API, `shm_mq_result` enum |
| `src/backend/storage/ipc/shm_mq.c` | Ring buffer implementation |
| `src/include/storage/shm_toc.h` | shm_toc API, estimator macros |
| `src/backend/storage/ipc/shm_toc.c` | TOC create/attach/allocate/lookup |
| `src/backend/access/transam/parallel.c` | Parallel query setup using shm_toc + shm_mq |
| `src/backend/executor/tqueue.c` | Tuple queue: serializes/deserializes tuples over shm_mq |
| `src/backend/libpq/pqmq.c` | Redirects libpq protocol messages through shm_mq (error reporting) |

---

## How It Works: shm_toc

### Structure

```c
/* src/backend/storage/ipc/shm_toc.c */
typedef struct shm_toc_entry
{
    uint64  key;       /* Arbitrary identifier */
    Size    offset;    /* Byte offset from TOC start */
} shm_toc_entry;

struct shm_toc
{
    uint64      toc_magic;             /* Magic number for validation */
    slock_t     toc_mutex;             /* Protects concurrent inserts */
    Size        toc_total_bytes;       /* Total managed space */
    Size        toc_allocated_bytes;   /* Space already allocated */
    uint32      toc_nentry;            /* Number of TOC entries */
    shm_toc_entry toc_entry[FLEXIBLE_ARRAY_MEMBER];
};
```

The TOC is a bump allocator that grows entries from the front and data chunks from
the back of the managed space:

```
+--------+--------+--------+-----+            +-------+-------+
| entry0 | entry1 | entry2 | ... |  (free)    | chunk2| chunk1|
+--------+--------+--------+-----+            +-------+-------+
^                                                              ^
toc start                                              toc start + total_bytes
```

`shm_toc_allocate(toc, nbytes)` carves `nbytes` from the back.
`shm_toc_insert(toc, key, address)` records the mapping. Lookups are linear
scans (the TOC is designed for a small number of keys, typically under 20).

### Estimator

Before creating a DSM segment, the leader must estimate how large it needs to be.
The estimator macros help with this:

```c
shm_toc_estimator e;
shm_toc_initialize_estimator(&e);
shm_toc_estimate_chunk(&e, query_text_len);
shm_toc_estimate_chunk(&e, planned_stmt_len);
shm_toc_estimate_chunk(&e, shm_mq_size * nworkers);
shm_toc_estimate_keys(&e, 3 + nworkers);
Size segsize = shm_toc_estimate(&e);
```

### Create and Attach

The leader creates the TOC:

```c
dsm_segment *seg = dsm_create(segsize, 0);
shm_toc *toc = shm_toc_create(PARALLEL_MAGIC, dsm_segment_address(seg), segsize);
```

Workers attach:

```c
dsm_segment *seg = dsm_attach(handle);
shm_toc *toc = shm_toc_attach(PARALLEL_MAGIC, dsm_segment_address(seg));
```

The magic number serves as a version check. If a worker attaches to a segment
with the wrong magic, `shm_toc_attach()` returns NULL.

---

## How It Works: shm_mq

### Ring Buffer Design

```c
/* src/backend/storage/ipc/shm_mq.c */
struct shm_mq
{
    slock_t          mq_mutex;          /* Protects sender/receiver assignment */
    PGPROC          *mq_receiver;       /* Receiver's PGPROC (for SetLatch) */
    PGPROC          *mq_sender;         /* Sender's PGPROC (for SetLatch) */
    pg_atomic_uint64 mq_bytes_read;     /* Total bytes consumed by receiver */
    pg_atomic_uint64 mq_bytes_written;  /* Total bytes produced by sender */
    Size             mq_ring_size;      /* Capacity of the ring buffer */
    bool             mq_detached;       /* Has either side disconnected? */
    uint8            mq_ring_offset;    /* Offset of mq_ring from struct start */
    char             mq_ring[FLEXIBLE_ARRAY_MEMBER];  /* The ring buffer */
};
```

This is a classic single-producer, single-consumer ring buffer. The sender writes
at position `mq_bytes_written % mq_ring_size` and the receiver reads at
`mq_bytes_read % mq_ring_size`. The difference `mq_bytes_written - mq_bytes_read`
is the amount of unread data.

No locks are needed for data transfer. The `mq_mutex` only protects the one-time
assignment of `mq_sender` and `mq_receiver`. After that, synchronization relies
entirely on atomic reads/writes of the byte counters and memory barriers.

### Message Framing

Each message is preceded by a length word. `shm_mq_send()` writes the length
followed by the data bytes. `shm_mq_receive()` reads the length first, then
reads that many bytes. Messages can wrap around the ring buffer; the implementation
handles the split transparently.

### Flow Control and Wakeups

When the ring buffer is full (sender) or empty (receiver), the process must wait:

```
Sender:
  1. Check: is there room? (mq_bytes_written - mq_bytes_read < mq_ring_size)
  2. If no room and nowait=true: return SHM_MQ_WOULD_BLOCK
  3. If no room and nowait=false:
       a. SetLatch(mq_receiver->procLatch)  -- wake receiver to consume data
       b. WaitLatch(MyLatch, ...)            -- sleep until receiver reads
       c. Retry

Receiver:
  1. Check: is there data? (mq_bytes_written > mq_bytes_read)
  2. If no data and nowait=true: return SHM_MQ_WOULD_BLOCK
  3. If no data and nowait=false:
       a. SetLatch(mq_sender->procLatch)    -- wake sender to produce data
       b. WaitLatch(MyLatch, ...)            -- sleep until sender writes
       c. Retry
```

### Send Batching

The `shm_mq_handle` (backend-private state) tracks `mqh_send_pending`: bytes
written to the ring but not yet reflected in `mq_bytes_written`. The counter is
only updated (making data visible to the receiver) when either:

- The pending bytes reach 1/4 of the ring size, or
- A flush is explicitly requested (`force_flush = true`), or
- The ring is full and the sender must wait.

This batching reduces the frequency of atomic writes and `SetLatch` calls, both
of which involve CPU cache line bouncing.

### Detach

Either side can call `shm_mq_detach()`, which sets `mq_detached = true` and wakes
the counterparty. After detach, any send or receive returns `SHM_MQ_DETACHED`.

---

## Key Data Structures

### shm_mq_handle (Backend-Private)

```c
struct shm_mq_handle
{
    shm_mq                 *mqh_queue;           /* The shared queue */
    dsm_segment            *mqh_segment;         /* Owning DSM segment */
    BackgroundWorkerHandle *mqh_handle;          /* For detecting worker death */
    char                   *mqh_buffer;          /* Reassembly buffer */
    Size                    mqh_buflen;          /* Buffer allocation size */
    Size                    mqh_send_pending;    /* Bytes written but not flushed */
    Size                    mqh_partial_bytes;   /* Partial message progress */
    Size                    mqh_expected_bytes;  /* Expected message size */
    bool                    mqh_length_word_complete;  /* Have we read the length? */
    bool                    mqh_counterparty_attached; /* Is the other end connected? */
};
```

### shm_mq_result

```c
typedef enum
{
    SHM_MQ_SUCCESS,      /* Message sent or received */
    SHM_MQ_WOULD_BLOCK,  /* Non-blocking: try again later */
    SHM_MQ_DETACHED,     /* Counterparty has disconnected */
} shm_mq_result;
```

### shm_mq_iovec

For scatter-gather sends, `shm_mq_sendv()` accepts an array of `shm_mq_iovec`:

```c
typedef struct
{
    const char *data;
    Size        len;
} shm_mq_iovec;
```

This avoids copying when a message is assembled from multiple pieces (e.g., a
length header plus payload).

---

## Diagram: Parallel Query Communication

```
Leader Backend
+--------------------------------------------------+
|                                                  |
|  1. dsm_create(segsize)                          |
|  2. shm_toc_create(magic, seg, segsize)          |
|  3. Allocate and insert:                         |
|       - query_string                             |
|       - PlannedStmt (serialized)                 |
|       - Params (serialized)                      |
|       - shm_mq per worker (tuple + error)        |
|  4. Launch workers via RegisterDynamicBGWorker   |
|  5. Wait on WaitEventSet for shm_mq readability  |
|                                                  |
|  tuple_mq[0] <------- Worker 0                   |
|  tuple_mq[1] <------- Worker 1                   |
|  error_mq[0] <------- Worker 0                   |
|  error_mq[1] <------- Worker 1                   |
+--------------------------------------------------+

Worker 0                            Worker 1
+-----------------------------+     +-----------------------------+
| 1. dsm_attach(handle)       |     | 1. dsm_attach(handle)       |
| 2. shm_toc_attach(magic)    |     | 2. shm_toc_attach(magic)    |
| 3. Look up query, params    |     | 3. Look up query, params    |
| 4. Attach to tuple_mq[0]   |     | 4. Attach to tuple_mq[1]   |
| 5. Execute partial plan     |     | 5. Execute partial plan     |
| 6. shm_mq_send(tuples)     |     | 6. shm_mq_send(tuples)     |
| 7. shm_mq_detach()         |     | 7. shm_mq_detach()         |
+-----------------------------+     +-----------------------------+
```

### Tuple Queue Protocol

The executor's `tqueue.c` layer sits on top of `shm_mq`. For each result tuple:

1. The worker serializes the tuple into a `MinimalTuple` (no system columns).
2. It sends the tuple via `shm_mq_send()`.
3. The leader receives via `shm_mq_receive()` and deserializes.

For tuples containing by-reference types that point into the worker's memory
(e.g., TOAST pointers, record types), the tuple queue includes a type remapping
mechanism that ensures the leader can interpret the data correctly.

### Error Reporting via pqmq

`pqmq.c` redirects the standard libpq error reporting protocol through `shm_mq`.
When a worker calls `ereport(ERROR, ...)`, the error message is serialized using
the standard libpq protocol format and sent via the error queue. The leader
receives these messages and re-raises them in its own context, so errors from
workers appear seamlessly in the client's error stream.

---

## Ring Buffer Synchronization Detail

The lock-free protocol relies on careful ordering of memory operations:

```
SENDER writes data to mq_ring:
  1. Write bytes to mq_ring[write_pos .. write_pos + len]
  2. pg_write_barrier()                    -- ensure ring writes are visible
  3. pg_atomic_write_u64(&mq_bytes_written, new_value)  -- publish

RECEIVER reads data from mq_ring:
  1. pg_atomic_read_u64(&mq_bytes_written)  -- observe available bytes
  2. pg_read_barrier()                      -- ensure subsequent reads see ring data
  3. Read bytes from mq_ring[read_pos .. read_pos + len]
  4. pg_atomic_write_u64(&mq_bytes_read, new_value)  -- release consumed space
```

The atomic operations on the byte counters and the memory barriers guarantee that:
- The receiver never reads data that the sender has not finished writing.
- The sender never overwrites data that the receiver has not finished reading.

No mutex is held during data transfer. The `mq_mutex` spinlock is only acquired
during the one-time setup of `mq_sender` and `mq_receiver`.

---

## Connections

- **[Shared Memory](shared-memory.md)** -- shm_mq and shm_toc are laid out within
  DSM segments. The DSM lifecycle governs when queues are created and destroyed.

- **[Latches and Wait Events](latches-and-events.md)** -- shm_mq uses SetLatch to
  wake the counterparty. The leader uses a WaitEventSet to monitor multiple queues.

- **[ProcArray](procarray.md)** -- shm_mq stores PGPROC pointers for sender and
  receiver, using them to access `procLatch` for signaling.

- **Chapter 8 (Executor)** -- Parallel Gather and Gather Merge nodes consume tuples
  from shm_mq queues. The executor's tqueue.c serializes tuples for transport.

- **Chapter 10 (Memory)** -- DSA (Dynamic Shared Area) provides a more general
  allocator on top of DSM for cases like parallel hash joins, where the data
  structure is more complex than a simple ring buffer.
