---
title: "Replication"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "12-replication"
chapter_title: "Replication"
is_chapter_index: true
---

# Chapter 12: Replication

## Summary

PostgreSQL replication enables high availability and horizontal read scaling by
propagating changes from a primary server to one or more standbys. The system
supports two fundamentally different modes: **physical replication**, which
ships raw WAL bytes to produce byte-identical copies of the primary, and
**logical replication**, which decodes WAL into a stream of logical change
events that can be selectively applied. This chapter examines the internal
machinery behind both approaches -- from the walsender/walreceiver protocol
and replication slots, through logical decoding and the reorder buffer, to
synchronous commit and conflict resolution.

---

## Overview

Replication in PostgreSQL is built on top of the Write-Ahead Log (WAL). Every
change that modifies data pages is first recorded in WAL, and replication
exploits this by shipping those records to other servers. The two replication
modes differ in *what* they ship and *how* they interpret it:

| Aspect | Physical Replication | Logical Replication |
|---|---|---|
| **Unit of transfer** | Raw WAL bytes (page-level changes) | Decoded row-level change events |
| **Standby type** | Byte-identical hot standby | Independent server with own schema |
| **Use cases** | HA failover, read replicas | Selective table sync, cross-version upgrade, data integration |
| **WAL level required** | `replica` | `logical` |
| **Key processes** | walsender, walreceiver, startup | walsender, logical worker, apply worker |

### Architectural Layers

The replication subsystem is organized into several cooperating layers:

```
+---------------------------------------------------------------------+
|                        Client Applications                          |
|           (read queries on standby / subscriber queries)            |
+---------------------------------------------------------------------+
           |                                        |
           v                                        v
+------------------------+           +-----------------------------+
|    Physical Standby    |           |     Logical Subscriber      |
|  +------------------+  |           |  +----------------------+   |
|  |  walreceiver     |  |           |  |  logical apply       |   |
|  |  startup process |  |           |  |  worker              |   |
|  |  (WAL replay)    |  |           |  |  (row-level apply)   |   |
|  +------------------+  |           |  +----------------------+   |
+----------+-------------+           +-------------+---------------+
           |                                       |
           | Streaming Protocol                    | Streaming Protocol
           | (physical WAL bytes)                  | (logical changes)
           |                                       |
+----------+---------------------------------------+---------------+
|                         Primary Server                           |
|  +-----------------------------------------------------------+  |
|  |                      walsender(s)                         |  |
|  |  +------------------+      +---------------------------+  |  |
|  |  | Physical sender  |      | Logical sender            |  |  |
|  |  | (reads WAL from  |      | (decodes WAL via          |  |  |
|  |  |  disk, streams)  |      |  logical decoding engine)  |  |  |
|  |  +------------------+      +---------------------------+  |  |
|  +-----------------------------------------------------------+  |
|  +-----------------------------------------------------------+  |
|  |                    Replication Slots                       |  |
|  |  (track consumer progress, prevent WAL/row removal)       |  |
|  +-----------------------------------------------------------+  |
|  +-----------------------------------------------------------+  |
|  |              WAL (pg_wal/)                                |  |
|  +-----------------------------------------------------------+  |
+------------------------------------------------------------------+
```

### The Walsender/Walreceiver Protocol

Both physical and logical replication share a common transport layer built on
the libpq streaming protocol. A standby (or logical subscriber) connects to
the primary using a **replication connection** -- a special connection mode
that speaks a small command language instead of SQL. The key commands are:

- `IDENTIFY_SYSTEM` -- returns the system identifier, timeline, and current WAL position
- `CREATE_REPLICATION_SLOT` -- creates a slot to track replication progress
- `START_REPLICATION` -- begins WAL streaming from a given LSN
- `BASE_BACKUP` -- initiates a physical base backup

Once `START_REPLICATION` is issued, the walsender enters COPY mode and
continuously sends WAL data messages. The receiver periodically sends status
updates containing its write, flush, and apply positions.

---

## Key Source Files

| File | Purpose |
|---|---|
| `src/backend/replication/walsender.c` | WAL sender process -- serves both physical and logical streams |
| `src/backend/replication/walreceiver.c` | WAL receiver process -- runs on standby, writes received WAL to disk |
| `src/backend/replication/walreceiverfuncs.c` | Shared memory interface for walreceiver status |
| `src/backend/replication/slot.c` | Replication slot management (create, drop, persist, invalidate) |
| `src/backend/replication/syncrep.c` | Synchronous replication -- commit waiting and standby release |
| `src/backend/replication/logical/decode.c` | Logical decoding -- translates WAL records into change events |
| `src/backend/replication/logical/reorderbuffer.c` | Reassembles transaction changes in commit order |
| `src/backend/replication/logical/snapbuild.c` | Builds historic catalog snapshots for logical decoding |
| `src/backend/replication/logical/conflict.c` | Conflict detection and logging for logical replication |
| `src/backend/replication/logical/worker.c` | Logical replication apply worker |
| `src/backend/replication/logical/launcher.c` | Logical replication launcher -- manages apply workers |
| `src/backend/storage/ipc/standby.c` | Hot standby conflict resolution |
| `src/include/replication/walsender_private.h` | `WalSnd` and `WalSndCtlData` shared memory structures |
| `src/include/replication/walreceiver.h` | `WalRcvData` shared memory structure and walreceiver states |
| `src/include/replication/slot.h` | `ReplicationSlot` and `ReplicationSlotPersistentData` structs |
| `src/include/replication/syncrep.h` | `SyncRepConfigData` and sync rep wait modes |
| `src/include/replication/reorderbuffer.h` | `ReorderBuffer`, `ReorderBufferTXN`, `ReorderBufferChange` |
| `src/include/replication/snapbuild.h` | `SnapBuild` state machine and snapshot builder interface |
| `src/include/replication/conflict.h` | `ConflictType` enum and `ConflictTupleInfo` |

---

## How It Works: Replication Lifecycle

### 1. Setting Up Replication

Physical replication begins with a base backup (`pg_basebackup`), which
creates a copy of the entire data directory. The standby is configured with
`primary_conninfo` pointing back to the primary. On startup, the standby's
startup process replays any locally available WAL, then signals the postmaster
to launch a walreceiver to stream more WAL from the primary.

Logical replication is configured through the SQL-level `CREATE PUBLICATION`
and `CREATE SUBSCRIPTION` commands. The subscription launcher on the
subscriber starts apply workers that connect to the primary's walsender using
logical replication slots.

### 2. Steady-State Streaming

During normal operation, the walsender reads WAL from disk (physical) or
decodes it through the logical decoding pipeline (logical) and streams it to
the connected consumer. The consumer acknowledges progress, which the
walsender records in the replication slot. This feedback loop serves three
purposes:

1. **Progress tracking** -- allows resumption after disconnection
2. **WAL retention** -- prevents removal of WAL still needed by consumers
3. **Synchronous commit** -- enables the primary to wait for standby confirmation

### 3. Replication Slots as the Coordination Mechanism

Replication slots are the central coordination mechanism. They are stored both
in shared memory (for runtime efficiency) and on disk under `pg_replslot/`
(for crash safety). Each slot tracks:

- **restart_lsn** -- oldest WAL position the consumer might need
- **confirmed_flush** -- latest position acknowledged by the consumer
- **xmin / catalog_xmin** -- transaction ID horizons that prevent premature vacuuming
- **invalidated** -- whether the slot has been invalidated (WAL removed, rows removed, etc.)

---

## Key Data Structures

### ReplicationSlot (slot.h)

The in-memory representation of a replication slot, protected by a per-slot
spinlock and the global `ReplicationSlotControlLock`:

```c
typedef struct ReplicationSlot
{
    slock_t     mutex;
    bool        in_use;
    ProcNumber  active_proc;       /* who is using this slot */
    bool        just_dirtied;
    bool        dirty;

    /* Effective xmin/catalog_xmin (may lag behind persistent values) */
    TransactionId effective_xmin;
    TransactionId effective_catalog_xmin;

    /* On-disk persistent state */
    ReplicationSlotPersistentData data;
    /* ... */
} ReplicationSlot;
```

### WalSnd (walsender_private.h)

Per-walsender shared memory state, used for monitoring and synchronous
replication coordination:

```c
typedef struct WalSnd
{
    pid_t       pid;
    WalSndState state;             /* STARTUP, CATCHUP, STREAMING, STOPPING */
    XLogRecPtr  sentPtr;           /* WAL sent up to here */
    XLogRecPtr  write;             /* standby has written up to here */
    XLogRecPtr  flush;             /* standby has flushed up to here */
    XLogRecPtr  apply;             /* standby has applied up to here */
    TimeOffset  writeLag, flushLag, applyLag;
    int         sync_standby_priority;
    slock_t     mutex;
    TimestampTz replyTime;
    ReplicationKind kind;          /* physical or logical */
} WalSnd;
```

---

## Chapter Organization

This chapter is divided into four sections, each covering a major aspect of
the replication subsystem:

1. **[Streaming Replication](streaming.html)** -- Physical replication internals:
   the walsender/walreceiver architecture, the streaming protocol, and
   replication slots.

2. **[Logical Replication](logical.html)** -- Logical decoding internals: the
   decode pipeline, the reorder buffer, snapshot building, and output plugins.

3. **[Synchronous Replication](synchronous.html)** -- How PostgreSQL implements
   synchronous commit across standbys, including priority-based and quorum-based
   modes.

4. **[Conflict Resolution](conflict-resolution.html)** -- How conflicts are
   detected and resolved in both hot standby (physical) and logical replication
   scenarios.

---

## Connections to Other Chapters

- **[Chapter 4: WAL](../04-wal/)** -- Replication is built directly on the WAL
  infrastructure. Understanding WAL record format, LSNs, and the WAL writer is
  prerequisite to understanding replication.

- **[Chapter 5: Buffer Manager](../05-buffer-manager/)** -- Hot standby conflicts
  arise when WAL replay needs to modify buffers that are pinned by read queries.

- **[Chapter 6: MVCC and Snapshots](../06-mvcc/)** -- Logical decoding builds
  its own historic snapshots using the same visibility rules that MVCC uses for
  normal queries.

- **[Chapter 8: Transactions](../08-transactions/)** -- The reorder buffer
  reconstructs transaction boundaries from WAL, and synchronous replication
  hooks into the commit path.

- **[Chapter 10: VACUUM](../10-vacuum/)** -- Replication slots hold back xmin
  horizons, directly affecting when VACUUM can remove dead tuples.
