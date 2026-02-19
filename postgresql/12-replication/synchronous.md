---
title: "Synchronous Replication"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "12-replication"
chapter_title: "Replication"
chapter_url: "/postgresql/12-replication/"
---

# Synchronous Replication

## Summary

Synchronous replication makes a committing transaction on the primary wait
until one or more standbys have confirmed receipt (or replay) of the
transaction's WAL. PostgreSQL supports two selection methods: **priority-based**
(FIRST), where the N highest-priority standbys must confirm, and
**quorum-based** (ANY), where any N standbys from a candidate list suffice.
The wait can be configured at three durability levels: write, flush, or apply.
All synchronous commit logic executes on the primary; standbys are completely
unaware of their synchronous role.

---

## Overview

Asynchronous replication (the default) allows the primary to commit
transactions without waiting for any standby. This gives the best performance
but means that if the primary crashes, recently committed transactions may
not yet exist on any standby -- a window of potential data loss.

Synchronous replication closes this window by requiring the primary to wait
for standby confirmation before acknowledging a commit to the client. The
design in PostgreSQL has several notable properties:

1. **Primary-side logic only** -- the standbys do not know which transactions
   are synchronous. They simply stream WAL and report progress as usual.
2. **Configurable durability** -- the `synchronous_commit` GUC controls
   whether to wait for write, flush, or apply on the standby.
3. **No per-transaction coordination** -- there are no round-trip messages for
   individual transactions. The primary infers commit confirmation from the
   standby's reported LSN positions.
4. **Ordered wait queue** -- waiting backends are organized in an LSN-ordered
   queue for efficient release.

---

## Key Source Files

| File | Purpose |
|---|---|
| `src/backend/replication/syncrep.c` | Core synchronous replication logic: waiting, releasing, standby selection |
| `src/backend/replication/syncrep_gram.y` | Grammar for parsing `synchronous_standby_names` |
| `src/backend/replication/syncrep_scanner.l` | Lexer for `synchronous_standby_names` |
| `src/include/replication/syncrep.h` | `SyncRepConfigData`, wait modes, standby data structures |
| `src/include/replication/walsender_private.h` | `WalSndCtlData` with `SyncRepQueue` arrays |
| `src/backend/replication/walsender.c` | Walsender calls `SyncRepReleaseWaiters()` on feedback |
| `src/backend/access/transam/xact.c` | Commit path calls `SyncRepWaitForLSN()` |

---

## How It Works

### 1. Configuration

Synchronous replication is controlled by two GUC parameters:

**`synchronous_standby_names`** specifies which standbys to wait for and how:

```
# Priority-based: wait for 2 standbys, preferring s1, then s2, then s3
synchronous_standby_names = 'FIRST 2 (s1, s2, s3)'

# Quorum-based: wait for any 2 of the 3 standbys
synchronous_standby_names = 'ANY 2 (s1, s2, s3)'

# Legacy syntax (equivalent to FIRST 1)
synchronous_standby_names = 's1'
```

**`synchronous_commit`** controls the durability level:

| Value | Behavior |
|---|---|
| `off` | No wait at all (async even locally) |
| `local` | Wait for local WAL flush only |
| `remote_write` | Wait for standby to write WAL to OS cache |
| `on` (default) | Wait for standby to flush WAL to disk |
| `remote_apply` | Wait for standby to replay WAL |

The parsed configuration is stored in a `SyncRepConfigData` structure:

```c
typedef struct SyncRepConfigData
{
    int     config_size;       /* total struct size */
    int     num_sync;          /* number of required confirmations */
    uint8   syncrep_method;    /* SYNC_REP_PRIORITY or SYNC_REP_QUORUM */
    int     nmembers;          /* number of named standbys */
    char    member_names[FLEXIBLE_ARRAY_MEMBER]; /* concatenated names */
} SyncRepConfigData;
```

### 2. The Commit Wait Path

When a transaction commits and `synchronous_commit` requires standby
confirmation, the commit path calls `SyncRepWaitForLSN()`:

```
Backend commit path (xact.c):
    RecordTransactionCommit():
        XLogFlush(commitLsn)    // flush WAL locally

    SyncRepWaitForLSN(commitLsn, true):
        if !SyncRepRequested():
            return              // fast path: no sync rep configured

        // Determine wait mode from synchronous_commit setting
        mode = SyncRepWaitMode  // WRITE, FLUSH, or APPLY

        // Insert into ordered wait queue
        SyncRepQueueInsert(mode):
            // Insert into SyncRepQueue[mode], ordered by LSN
            // (walk from tail, most new commits go near the end)
            proc->waitLSN = commitLsn
            proc->syncRepState = SYNC_REP_WAITING

        // Wait loop
        while proc->syncRepState == SYNC_REP_WAITING:
            WaitLatch(MyLatch, timeout)

            // Check for cancellation
            if interrupted:
                SyncRepCancelWait()
                ereport(ERROR)

        // Released by walsender
        Assert(proc->syncRepState == SYNC_REP_WAIT_COMPLETE)
```

The wait queue is a doubly-linked list (`dlist_head`) stored in
`WalSndCtl->SyncRepQueue[mode]`. There are three independent queues, one for
each wait mode (write, flush, apply).

### 3. The Release Path

When a walsender receives a status update from a standby, it calls
`SyncRepReleaseWaiters()` to check whether any waiting backends can be
released:

```
Walsender receives standby feedback:
    ProcessStandbyReplyMessage():
        update WalSnd->write, flush, apply

    SyncRepReleaseWaiters():
        if !SyncStandbysDefined():
            return

        // Get aggregate sync positions based on method
        if method == SYNC_REP_PRIORITY:
            SyncRepGetOldestSyncRecPtr(&write, &flush, &apply):
                // Among the top-N priority standbys,
                // find the OLDEST (minimum) position
                // This is the bottleneck: all N must have reached this LSN

        else: // SYNC_REP_QUORUM
            SyncRepGetNthLatestSyncRecPtr(&write, &flush, &apply, N):
                // Among all candidate standbys,
                // find the Nth-latest position
                // This means at least N standbys have reached this LSN

        // Release waiters whose LSN has been satisfied
        for each mode in [WRITE, FLUSH, APPLY]:
            if aggregated_lsn[mode] > WalSndCtl->lsn[mode]:
                SyncRepWakeQueue(false, mode):
                    walk SyncRepQueue[mode] from head
                    for each waiter where waitLSN <= aggregated_lsn:
                        waiter->syncRepState = SYNC_REP_WAIT_COMPLETE
                        SetLatch(waiter->latch)
                WalSndCtl->lsn[mode] = aggregated_lsn[mode]
```

### 4. Priority-Based Selection (FIRST N)

With `FIRST N (s1, s2, s3)`, PostgreSQL assigns priorities to standbys based
on their position in the list. The synchronous standbys are the N
highest-priority connected standbys that are currently streaming.

```
Example: FIRST 2 (s1, s2, s3)

s1 (priority 1) -- connected, streaming  --> sync standby
s2 (priority 2) -- connected, streaming  --> sync standby
s3 (priority 3) -- connected, streaming  --> potential (takes over if s1 or s2 disconnects)

Aggregate position = MIN(s1.flush, s2.flush)
    (both s1 AND s2 must have flushed to this LSN)
```

The implementation sorts candidate standbys by priority and takes the minimum
position among the top N:

```c
static void
SyncRepGetOldestSyncRecPtr(XLogRecPtr *writePtr, XLogRecPtr *flushPtr,
                           XLogRecPtr *applyPtr,
                           SyncRepStandbyData *sync_standbys, int num_standbys)
{
    /* sync_standbys is pre-sorted by priority, limited to top N */
    for (i = 0; i < num_standbys; i++)
    {
        *writePtr = Min(*writePtr, sync_standbys[i].write);
        *flushPtr = Min(*flushPtr, sync_standbys[i].flush);
        *applyPtr = Min(*applyPtr, sync_standbys[i].apply);
    }
}
```

### 5. Quorum-Based Selection (ANY N)

With `ANY N (s1, s2, s3)`, any N standbys from the list suffice. There is no
priority ordering -- all listed standbys are equal candidates.

```
Example: ANY 2 (s1, s2, s3)

s1 flush = 0/3000000
s2 flush = 0/3500000
s3 flush = 0/3200000

Sort by flush descending: s2, s3, s1
Nth latest (2nd) = s3.flush = 0/3200000

At least 2 standbys (s2 and s3) have flushed to 0/3200000.
Waiters with commitLSN <= 0/3200000 can be released.
```

The implementation finds the Nth-largest position among all candidates:

```c
static void
SyncRepGetNthLatestSyncRecPtr(XLogRecPtr *writePtr, ...)
{
    /* Sort candidates by position (descending) */
    /* Return the Nth entry -- at least N standbys are at or beyond this point */
    *writePtr = sync_standbys[nth - 1].write;
    *flushPtr = sync_standbys[nth - 1].flush;
    *applyPtr = sync_standbys[nth - 1].apply;
}
```

---

## Key Data Structures

### SyncRepStandbyData (syncrep.h)

Used to collect candidate synchronous standby information:

```c
typedef struct SyncRepStandbyData
{
    pid_t       pid;
    XLogRecPtr  write;
    XLogRecPtr  flush;
    XLogRecPtr  apply;
    int         sync_standby_priority;  /* 0 if not in sync list */
    int         walsnd_index;
    bool        is_me;
} SyncRepStandbyData;
```

### Wait State in PGPROC

Each backend's synchronous replication state is stored in its `PGPROC` entry:

```c
/* In PGPROC (proc.h) */
struct PGPROC
{
    /* ... */
    XLogRecPtr  waitLSN;          /* LSN this backend is waiting for */
    int         syncRepState;     /* NOT_WAITING, WAITING, or WAIT_COMPLETE */
    dlist_node  syncRepLinks;     /* links in SyncRepQueue */
    /* ... */
};
```

### The Three Wait Queues

```
WalSndCtl->SyncRepQueue[3]:

  [SYNC_REP_WAIT_WRITE]   ──> proc_A(LSN=100) ──> proc_B(LSN=200) ──> ...
  [SYNC_REP_WAIT_FLUSH]   ──> proc_C(LSN=150) ──> proc_D(LSN=300) ──> ...
  [SYNC_REP_WAIT_APPLY]   ──> proc_E(LSN=120) ──> ...

WalSndCtl->lsn[3]:
  [WRITE] = 180    (all waiters with LSN <= 180 have been released)
  [FLUSH] = 140    (all waiters with LSN <= 140 have been released)
  [APPLY] = 100    (all waiters with LSN <= 100 have been released)
```

---

## Synchronous Commit Flow Diagram

```
Client                  Primary Backend            Walsender              Standby
  |                          |                         |                      |
  |-- COMMIT -------------->|                         |                      |
  |                          |                         |                      |
  |                  XLogInsert(commit record)         |                      |
  |                  XLogFlush(commitLsn)              |                      |
  |                          |                         |                      |
  |                  SyncRepWaitForLSN(commitLsn)      |                      |
  |                  [insert into SyncRepQueue]        |                      |
  |                  [sleep on latch]                  |                      |
  |                          |                         |                      |
  |                          |          WAL data ----->| ---- WAL data ------>|
  |                          |                         |                      |
  |                          |                         |<-- status: flush=LSN |
  |                          |                         |                      |
  |                          |  SyncRepReleaseWaiters()|                      |
  |                          |  [compute aggregate LSN]|                      |
  |                          |  [walk queue, release]  |                      |
  |                          |                         |                      |
  |                  [latch set, wake up]              |                      |
  |                  syncRepState = WAIT_COMPLETE      |                      |
  |                          |                         |                      |
  |<-- COMMIT OK ------------|                         |                      |
  |                          |                         |                      |
```

---

## Edge Cases and Failure Modes

### All Sync Standbys Disconnect

If all synchronous standbys disconnect, waiting backends remain blocked
indefinitely. This is by design: PostgreSQL guarantees that if
`synchronous_commit = on` and a commit is acknowledged, the data exists on
the required number of standbys. The administrator must either reconnect a
standby or change `synchronous_standby_names` to empty (which releases all
waiters immediately).

### Standby Promotion During Sync Wait

If a backend is waiting for sync rep confirmation and the standby is promoted
(making it a new primary), the waiting backend will remain blocked until
either the wait is cancelled or the configuration is changed.

### Per-Transaction Override

`synchronous_commit` is a session-level GUC that can be changed per
transaction:

```sql
SET LOCAL synchronous_commit = 'local';
-- This transaction will not wait for standby confirmation
```

This allows mixing synchronous and asynchronous transactions based on their
durability requirements.

### Performance Impact

Synchronous replication adds network round-trip latency to every commit. The
impact depends on:
- Network latency between primary and standby
- `synchronous_commit` level (write < flush < apply)
- Number of required confirmations (more = slower, bounded by slowest)
- Whether FIRST or ANY is used (ANY is more resilient to slow standbys)

---

## Connections to Other Sections

- **[Streaming Replication](streaming.html)** -- The walsender/walreceiver
  feedback loop provides the LSN positions that drive synchronous commit
  decisions. The `WalSnd->write/flush/apply` fields are the direct inputs.

- **[Logical Replication](logical.html)** -- Logical replication subscribers
  can participate in synchronous replication. The subscriber's apply worker
  reports its position through the same walsender feedback mechanism.

- **[Conflict Resolution](conflict-resolution.html)** -- With
  `synchronous_commit = remote_apply`, the primary knows that committed data
  has been applied on the standby, which strengthens read-after-write
  consistency guarantees for applications that read from standbys.
