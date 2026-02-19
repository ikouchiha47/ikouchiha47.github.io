---
title: "Scan Nodes"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "08-executor"
chapter_title: "Executor"
chapter_url: "/postgresql/08-executor/"
---

# Scan Nodes

## Summary

Scan nodes are the leaf operators of the executor plan tree. They read tuples
from base relations, indexes, subqueries, functions, or CTEs, apply qual
filters, and project output columns. PostgreSQL provides over a dozen scan
types, each optimized for a different access pattern. All scan nodes share the
common `ExecScan()` loop from `execScan.c`, which handles filtering and
projection uniformly -- individual scan types only need to supply a function
that fetches the next raw tuple.

---

## Overview

Every query plan bottoms out at one or more scan nodes that produce the raw
tuples flowing upward through joins, aggregates, and sorts. The planner selects
the scan type based on cost estimates: a sequential scan for large fractions of
a table, an index scan for selective predicates, a bitmap scan when multiple
index conditions must be combined.

### Scan Node Hierarchy

```
ScanState (base)
 |
 +-- SeqScanState          -- full table scan
 +-- SampleScanState       -- TABLESAMPLE
 +-- IndexScanState        -- B-tree / GiST / etc. traversal
 +-- IndexOnlyScanState    -- index-only (visibility map check)
 +-- BitmapIndexScanState  -- build TID bitmap from index
 +-- BitmapHeapScanState   -- fetch heap pages from TID bitmap
 +-- TidScanState          -- direct TID lookup
 +-- TidRangeScanState     -- TID range scan
 +-- SubqueryScanState     -- scan a sub-SELECT
 +-- FunctionScanState     -- scan function result set
 +-- ValuesScanState       -- scan VALUES list
 +-- TableFuncScanState    -- scan XMLTABLE / JSON_TABLE
 +-- CteScanState          -- scan CTE (WITH query)
 +-- WorkTableScanState    -- recursive CTE working table
 +-- ForeignScanState      -- FDW push-down scan
 +-- CustomScanState       -- extension-provided scan
```

---

## Key Source Files

| File | Purpose |
|---|---|
| `src/backend/executor/execScan.c` | `ExecScan()` generic scan loop |
| `src/backend/executor/nodeSeqscan.c` | Sequential scan |
| `src/backend/executor/nodeIndexscan.c` | Index scan with heap fetch |
| `src/backend/executor/nodeIndexonlyscan.c` | Index-only scan |
| `src/backend/executor/nodeBitmapIndexscan.c` | Bitmap index scan (TID bitmap builder) |
| `src/backend/executor/nodeBitmapHeapscan.c` | Bitmap heap scan (fetcher) |
| `src/backend/executor/nodeTidscan.c` | Direct TID scan |
| `src/backend/executor/nodeTidrangescan.c` | TID range scan |
| `src/backend/executor/nodeSamplescan.c` | TABLESAMPLE scan |
| `src/backend/executor/nodeSubqueryscan.c` | Subquery scan |
| `src/backend/executor/nodeFunctionscan.c` | Function scan |
| `src/include/executor/execScan.h` | `ExecScanAccessMtd` / `ExecScanRecheckMtd` types |
| `src/include/nodes/tidbitmap.h` | TIDBitmap structures for bitmap scans |

---

## How It Works

### Sequential Scan (SeqScan)

The simplest scan. Reads every tuple in heap order using the table access
method API.

```c
static TupleTableSlot *
SeqNext(SeqScanState *node)
{
    TableScanDesc scandesc = node->ss.ss_currentScanDesc;
    TupleTableSlot *slot = node->ss.ss_ScanTupleSlot;

    /* Lazy open: create scan descriptor on first call */
    if (scandesc == NULL)
    {
        scandesc = table_beginscan(node->ss.ss_currentRelation,
                                   estate->es_snapshot, 0, NULL);
        node->ss.ss_currentScanDesc = scandesc;
    }

    if (table_scan_getnextslot(scandesc, direction, slot))
        return slot;
    return NULL;
}
```

The call to `table_scan_getnextslot()` goes through the **table access method**
(tableam) abstraction. For heap tables, this ultimately calls `heap_getnext()`
which walks pages sequentially, checking tuple visibility against the snapshot.

**Parallel sequential scan.** When running under a Gather node, SeqScan uses
a `ParallelBlockTableScanDesc` in shared memory. Workers atomically claim page
ranges, ensuring each page is scanned exactly once without duplicating work.

### Index Scan (IndexScan)

Traverses an index (B-tree, GiST, GIN, etc.) and fetches corresponding heap
tuples:

```
ExecIndexScan
  |
  v
IndexNext(node)
  |
  +-- index_getnext_slot(scandesc, direction, slot)
  |     |
  |     +-- index AM returns next matching TID
  |     +-- table_index_fetch_tuple() retrieves heap tuple
  |     +-- visibility check against snapshot
  |
  +-- return slot (or NULL)
```

Index scans evaluate **index quals** (pushed into the index AM for efficient
key comparison) and **non-index quals** (checked after heap fetch). The
`IndexScanState` holds:

- `iss_ScanDesc` -- the index scan descriptor from the AM
- `iss_ScanKeys` -- array of `ScanKey` for index lookup
- `iss_OrderByKeys` -- for KNN (K-nearest-neighbor) ordered scans
- `iss_ReorderQueue` -- pairing heap for reordering KNN results

**Recheck.** After fetching the heap tuple, `IndexRecheck()` re-evaluates
the original qual against the actual tuple data. This is necessary because
some index types (GiST, SP-GiST) are lossy -- the index may return false
positives.

### Index-Only Scan (IndexOnlyScan)

Returns data directly from the index without visiting the heap, but only when
the **visibility map** confirms that all tuples on the page are visible to all
transactions:

```
IndexOnlyNext(node)
  |
  +-- index_getnext_slot(scandesc, ForwardScanDirection, slot)
  |
  +-- if (visibilitymap_get_status(blkno) == VISIBILITYMAP_ALL_VISIBLE)
  |     |
  |     +-- store index tuple data directly in slot
  |     +-- skip heap fetch entirely
  |
  +-- else
  |     |
  |     +-- table_index_fetch_tuple()  -- must check heap
  |     +-- if visible, store in slot
  |
  +-- return slot
```

The visibility map check is critical for performance. On a well-vacuumed table,
most pages are all-visible, and the index-only scan avoids nearly all heap I/O.

### Bitmap Scan (BitmapIndexScan + BitmapHeapScan)

A two-phase scan that combines multiple index conditions and fetches heap pages
in physical order to maximize sequential I/O:

```
Phase 1: BitmapIndexScan builds a TID bitmap
  |
  +-- For each index:
  |     scan index, collect matching TIDs into TIDBitmap
  |
  +-- BitmapAnd / BitmapOr combine bitmaps from multiple indexes
  |
Phase 2: BitmapHeapScan fetches heap tuples
  |
  +-- Iterate pages in physical order (from bitmap)
  |     |
  |     +-- For each page, fetch all matching tuples
  |     +-- Recheck quals (bitmap may be lossy for large result sets)
  |     +-- Apply remaining filter quals
  |     +-- Return matching tuples one at a time
```

The TID bitmap has two modes:

| Mode | When | Precision |
|---|---|---|
| **Exact** | Few matching tuples | Stores individual TIDs; no recheck needed |
| **Lossy** | Many matching tuples (exceeds `work_mem`) | Stores page numbers only; must recheck every tuple on the page |

```c
/* From tidbitmap.h */
typedef struct TIDBitmap {
    NodeTag     type;
    MemoryContext mcxt;
    TBMStatus   status;         /* exact or lossy */
    struct pagetable_hash *pagetable;  /* hash of PagetableEntry */
    int         nentries;       /* number of entries */
    int         maxentries;     /* limit before going lossy */
    ...
} TIDBitmap;
```

### TID Scan

Directly fetches tuples by their physical TID (block number + offset). Used for
queries like `WHERE ctid = '(0,1)'` or internally for row-level locking and
EPQ (EvalPlanQual) rechecks.

---

## Key Data Structures

### ScanState (base for all scans)

```c
typedef struct ScanState {
    PlanState       ps;                 /* base PlanState */
    Relation        ss_currentRelation; /* opened heap relation */
    TableScanDesc   ss_currentScanDesc; /* scan descriptor (heap/index) */
    TupleTableSlot *ss_ScanTupleSlot;   /* slot for raw scanned tuple */
} ScanState;
```

### IndexScanState

```c
typedef struct IndexScanState {
    ScanState       ss;                 /* base ScanState */
    ExprState      *indexqualorig;      /* original index qual for recheck */
    List           *indexorderbyorig;   /* ORDER BY expressions */
    ScanKey         iss_ScanKeys;       /* index scan keys */
    int             iss_NumScanKeys;
    IndexScanDesc   iss_ScanDesc;       /* index scan descriptor */
    Relation        iss_RelationDesc;   /* index relation */
    pairingheap    *iss_ReorderQueue;   /* KNN reorder queue */
    ...
} IndexScanState;
```

### BitmapHeapScanState

```c
typedef struct BitmapHeapScanState {
    ScanState       ss;
    ExprState      *bitmapqualorig;     /* original quals for recheck */
    TIDBitmap      *tbm;               /* bitmap from child BitmapIndexScan */
    TBMIterator     tbmiterator;        /* iterator over bitmap */
    TBMIterateResult *tbmres;           /* current page from bitmap */
    bool            can_skip_fetch;     /* all columns in index? */
    bool            exact_pages;        /* tracking exact vs lossy */
    ...
} BitmapHeapScanState;
```

---

## Diagram: Scan Type Selection

```
                        Query with WHERE clause
                                |
                    +-----------+-----------+
                    |                       |
              Has usable index?          No index
                    |                       |
              +-----+-----+            Seq Scan
              |           |
        Selective?    Multiple conditions?
              |           |
         Index Scan   Bitmap Scan
              |      (combine indexes)
              |
        Covers all columns?
              |
        Index Only Scan
```

### Parallel Scan Coordination

For parallel scans, each scan type implements four extra methods:

```
ExecXxxEstimate()           -- estimate DSM space needed
ExecXxxInitializeDSM()      -- set up shared state in DSM
ExecXxxReInitializeDSM()    -- reset for new scan
ExecXxxInitializeWorker()   -- worker attaches to shared state
```

For SeqScan, the shared state is a `ParallelBlockTableScanDesc` containing an
atomic counter for the next block to scan. Workers atomically increment this
counter to claim work:

```
Worker 0: pages 0-7       (claims block range atomically)
Worker 1: pages 8-15
Worker 2: pages 16-23
Leader:   pages 24-31
```

---

## Connections

| Topic | Link |
|---|---|
| Generic scan loop and Volcano model | [Volcano Model](volcano-model) |
| Index access methods (B-tree, GiST) | [Access Methods](../02-access-methods/) |
| Parallel scan coordination | [Parallel Query](parallel-query) |
| Visibility checks (snapshots, MVCC) | [Transactions](../03-transactions/) |
| Table access method API (tableam) | [Storage Engine](../01-storage/) |
| Join nodes that consume scans | [Join Nodes](join-nodes) |
| Buffer manager and I/O | [Storage Engine](../01-storage/) |
