---
title: "Predicate Locks"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "05-locking"
chapter_title: "Locking"
chapter_url: "/postgresql/05-locking/"
---

# Predicate Locks (SIRead Locks)

Predicate locks are a special class of locks used exclusively by
Serializable Snapshot Isolation (SSI) to detect read-write conflicts between
concurrent transactions. Unlike regular locks, predicate locks never block;
they act as markers that record "this transaction read this data" so that
later writes by other transactions can detect potential serialization
anomalies.

## Overview

PostgreSQL implements the `SERIALIZABLE` isolation level using SSI, based on
the research of Cahill, Rohm, and Fekete (SIGMOD 2008). The key insight is
that serialization anomalies in snapshot isolation can only occur when there
is a cycle of rw-dependencies among concurrent transactions, and specifically
when two consecutive rw-conflict edges exist in the dependency graph (a
"dangerous structure").

Predicate locks (called SIRead locks in the code) track the read side of
rw-conflicts. When a serializable transaction reads data, it places SIRead
locks on the objects it reads. When another serializable transaction writes
data covered by an existing SIRead lock, the system records an rw-conflict.
If a dangerous structure is detected, one of the transactions is aborted with
a serialization failure.

### Properties That Distinguish SIRead Locks from Regular Locks

1. **They never block.** They are flags, not mutual exclusion primitives.
2. **They survive COMMIT.** An SIRead lock must persist until all concurrent
   transactions complete, because a conflict can only be fully evaluated
   after the reading transaction commits.
3. **They cover ranges, not just specific tuples.** To prevent phantom reads,
   SIRead locks can be placed on pages or entire relations, not just
   individual tuples.
4. **They are automatically promoted** from fine-grained (tuple) to
   coarse-grained (page, relation) when memory pressure requires it.
5. **Only serializable transactions create or check them.**

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/storage/lmgr/predicate.c` | Core SSI implementation: SIRead lock management, conflict detection |
| `src/backend/storage/lmgr/README-SSI` | Detailed design document for SSI and predicate locking |
| `src/include/storage/predicate.h` | Public API: `CheckForSerializableConflictOut`, etc. |
| `src/include/storage/predicate_internals.h` | Internal structs: SERIALIZABLEXACT, PREDICATELOCK, etc. |

## How It Works

### The rw-Conflict Model

In snapshot isolation, three types of dependencies exist between transactions:

- **wr-dependency**: T2 reads data written by T1. T1 appears to execute
  before T2.
- **ww-dependency**: T2 overwrites data written by T1. T1 appears to execute
  before T2.
- **rw-conflict (anti-dependency)**: T1 reads data, and T2 writes data in
  the range T1 read (or would have read). T1 appears to execute before T2,
  even if T2 committed first.

An anomaly occurs when rw-conflicts form a cycle in the serialization graph.
Cahill et al. proved that a cycle must contain at least two consecutive
rw-conflict edges -- a pattern called a "dangerous structure":

```
Dangerous structure:

  T1 ---rw---> T2 ---rw---> T3

Where T1 and T3 are concurrent (overlap in time).
If T1 == T3 (the pivot), this is a direct cycle.
```

### SIRead Lock Acquisition

When a serializable transaction reads a tuple:

```
heapam_tuple_get (or index scan)
  |
  +-- CheckForSerializableConflictOut(relation, tuple)
  |     Record that this tuple was read by the current transaction
  |     Check if any concurrent transaction has already written
  |     a conflicting version of this tuple
  |
  +-- PredicateLockTuple(relation, tuple)
        |
        +-- Compute PREDICATELOCKTARGET from (dbOid, relOid, blockNo, offNum)
        +-- Look up or create lock in shared hash table
        +-- Associate lock with current SERIALIZABLEXACT
```

For index scans, locks are also placed at the page level to cover the
"gaps" between index entries (preventing phantoms):

```
PredicateLockPage(relation, blockno)
  Locks an entire heap or index page.

PredicateLockRelation(relation)
  Locks an entire relation (coarsest granularity).
```

### Lock Promotion (Granularity Escalation)

When the predicate lock table approaches capacity, fine-grained locks are
promoted to coarser granularity:

```
Tuple locks on the same page -> Page lock
  (when a threshold of per-page tuple locks is exceeded)

Page locks on the same relation -> Relation lock
  (when a threshold of per-relation page locks is exceeded)
```

This is conceptually similar to lock escalation in traditional lock managers
but is driven by memory pressure rather than lock count alone.

### Conflict Detection

Conflicts are checked at two points:

**When a serializable transaction writes (INSERT/UPDATE/DELETE):**

```
CheckForSerializableConflictIn(relation, tuple, buffer)
  |
  +-- Look up PREDICATELOCKTARGET for this tuple/page/relation
  +-- For each SIRead lock held by a different SERIALIZABLEXACT:
  |     Record an rw-conflict: reader -> writer
  |     Check for dangerous structure:
  |       Does the reader already have an inConflict from a third xact?
  |       Does the writer already have an outConflict to a third xact?
  |       If dangerous structure found: flag one transaction for abort
  +-- The flagged transaction will receive ERROR 40001
      (serialization_failure) at its next opportunity
```

**When a serializable transaction reads and finds a version written by a
concurrent committed transaction:**

```
CheckForSerializableConflictOut(relation, tuple)
  |
  +-- The writing transaction already committed
  +-- Record rw-conflict: current reader -> writer
  +-- Check for dangerous structure (same logic as above)
```

### Transaction Lifecycle

```
BEGIN ISOLATION LEVEL SERIALIZABLE
  |
  +-- GetSerializableTransactionSnapshot()
  |     Create SERIALIZABLEXACT for this transaction
  |     Link into active serializable transaction list
  |
  +-- [execute queries, accumulating SIRead locks and checking conflicts]
  |
  +-- COMMIT:
  |     PreCommit_CheckForSerializationFailure()
  |       Final check for dangerous structures
  |       If found: ERROR 40001 before commit completes
  |     ReleasePredicateLocks(isCommit=true)
  |       Keep SIRead locks alive (they may still be needed
  |       by concurrent transactions)
  |       Clean up when all overlapping transactions finish
  |
  +-- ROLLBACK:
        ReleasePredicateLocks(isCommit=false)
          Flag SERIALIZABLEXACT as rolled back
          SIRead locks can be released immediately
          (a rolled-back transaction cannot cause anomalies)
```

## Key Data Structures

### SERIALIZABLEXACT -- Per-Transaction SSI State

```c
typedef struct SERIALIZABLEXACT
{
    VirtualTransactionId vxid;
    TransactionId        topXid;

    /* Conflict tracking */
    dlist_head  outConflicts;   /* rw-conflicts where we are the reader */
    dlist_head  inConflicts;    /* rw-conflicts where we are the writer */

    /* SIRead locks held by this transaction */
    dlist_head  predicateLocks;

    /* Lifecycle flags */
    SHM_QUEUE   links;          /* link in global list */
    SerCommitSeqNo commitSeqNo;
    SerCommitSeqNo SeqNo;
    int         flags;          /* SXACT_FLAG_COMMITTED, _ROLLED_BACK, etc. */
    int         pid;
} SERIALIZABLEXACT;
```

### PREDICATELOCKTARGET -- What Is Locked

```c
typedef struct PREDICATELOCKTARGETTAG
{
    Oid     dbOid;
    Oid     relOid;
    /* For page-level: blockNo; for tuple-level: blockNo + offNum */
    /* For relation-level: zeros */
    BlockNumber blockNum;
    OffsetNumber offNum;
} PREDICATELOCKTARGETTAG;
```

### PREDICATELOCK -- Association Between Target and Transaction

```c
typedef struct PREDICATELOCK
{
    PREDICATELOCKTARGETTAG tag;
    SERIALIZABLEXACT      *myXact;
    dlist_node             xactLink;    /* link in SERIALIZABLEXACT's list */
    dlist_node             targetLink;  /* link in target's list */
    SerCommitSeqNo         commitSeqNo;
} PREDICATELOCK;
```

### RWConflict -- An rw-Dependency Edge

```c
typedef struct RWConflictData
{
    dlist_node  outLink;    /* link in reader's outConflicts */
    dlist_node  inLink;     /* link in writer's inConflicts */
    SERIALIZABLEXACT *sxactOut;  /* the reader */
    SERIALIZABLEXACT *sxactIn;   /* the writer */
} RWConflictData;
```

## Diagram: SSI Conflict Detection

```
T1 (serializable):  SELECT * FROM accounts WHERE balance > 1000
  |
  +-- SIRead lock on accounts (pages/tuples matching the predicate)
  |
  |                     T2 (serializable):  UPDATE accounts SET balance = 500
  |                       |                   WHERE id = 42
  |                       |
  |                       +-- CheckForSerializableConflictIn:
  |                       |     Found T1's SIRead lock on this tuple
  |                       |     Record rw-conflict: T1 -> T2
  |                       |
  |                       +-- Check dangerous structure:
  |                             Does T1 have an inConflict from T0?
  |                             If yes: T0 -> T1 -> T2 = dangerous
  |                             Flag T1 (or T2) for abort
  |
  +-- Later: T1 tries to commit
        PreCommit_CheckForSerializationFailure()
        If flagged: ERROR 40001 "could not serialize access"
```

## Read-Only Transaction Optimization

A read-only transaction running at `SERIALIZABLE` may be recognized as "safe"
-- meaning its snapshot is guaranteed to never participate in a dangerous
structure. This happens when all concurrent read-write transactions that
started before the read-only transaction have committed without creating
inbound rw-conflicts.

A safe read-only transaction can release all its SIRead locks early and
exempt itself from further conflict tracking. The `DEFERRABLE` option
for read-only serializable transactions explicitly waits for this safe
condition before beginning execution, trading latency for the guarantee
that the transaction will never be aborted for a serialization failure.

## Partitioning

Like the heavyweight lock manager, the predicate lock tables are partitioned
into 16 partitions (`NUM_PREDICATELOCK_PARTITIONS`), each protected by an
LWLock. This reduces contention when many serializable transactions are
active.

## Connections

- **MVCC / Snapshots**: SSI builds on top of snapshot isolation. The snapshot
  determines which tuple versions are visible; SIRead locks record which data
  was accessed under that snapshot.
- **Heavyweight Locks**: SIRead locks use entirely separate data structures
  from regular locks. They share the `src/backend/storage/lmgr/` directory
  but do not interact with the regular LOCK/PROCLOCK tables.
- **Index Scans**: Index access methods call `PredicateLockPage` on each
  index page visited and `PredicateLockTuple` on each heap tuple fetched.
  The page-level lock on index pages is essential for preventing phantom
  reads.
- **Transaction Manager**: The `SERIALIZABLEXACT` lifecycle is tied to
  transaction commit/abort. The `commitSeqNo` field imposes a serial order
  on committed transactions for conflict resolution.
- **Error Handling**: Serialization failures produce `ERRCODE_T_R_SERIALIZATION_FAILURE`
  (SQLSTATE 40001), which applications should handle by retrying the
  transaction.
