---
title: "Custom Access Methods"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "15-extensions"
chapter_title: "Extensions"
chapter_url: "/postgresql/15-extensions/"
---

# Custom Access Methods: Table AM and Index AM APIs

> *PostgreSQL's access method layer is a contract: the executor promises to call a defined set of callbacks in a defined order, and the access method promises to return tuples through a defined interface. The heap is just the default implementation of that contract -- extensions can provide entirely different storage engines.*

## Overview

PostgreSQL separates the executor from the physical storage layer through two callback-based APIs: the **Table Access Method** (Table AM) for tuple storage and the **Index Access Method** (Index AM) for index structures. Each API is defined as a C struct of function pointers that an access method handler function returns. The executor never directly manipulates pages or tuples -- it always goes through these callback interfaces.

The Table AM API (`TableAmRoutine`) was introduced in PostgreSQL 12, replacing the hard-coded heap assumptions that were previously wired throughout the executor. The Index AM API (`IndexAmRoutine`) has existed since PostgreSQL 9.6, enabling custom index types to be added as extensions.

Both APIs follow the same pattern: a handler function registered in the `pg_am` catalog returns a pointer to a statically allocated routine struct. The executor caches this pointer in the relation descriptor (`rd_tableam` or `rd_amroutine`) and calls the function pointers throughout query execution.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/include/access/tableam.h` | `TableAmRoutine` struct definition and all `table_*` wrapper functions |
| `src/include/access/amapi.h` | `IndexAmRoutine` struct definition and index AM callback typedefs |
| `src/backend/access/heap/heapam_handler.c` | Heap's implementation of `TableAmRoutine` |
| `src/backend/access/nbtree/nbtree.c` | B-tree's implementation of `IndexAmRoutine` |
| `src/backend/access/index/amapi.c` | `GetIndexAmRoutine`, `GetIndexAmRoutineByAmId` |
| `src/backend/access/table/tableamapi.c` | `GetTableAmRoutine` |
| `src/backend/commands/amcmds.c` | `CREATE ACCESS METHOD` command processing |

## How It Works

### Registration

An access method is registered by creating an entry in `pg_am` with a handler function:

```sql
CREATE ACCESS METHOD myam TYPE TABLE HANDLER myam_handler;
-- or
CREATE ACCESS METHOD myidx TYPE INDEX HANDLER myidx_handler;
```

The handler function returns a pointer to the routine struct:

```c
PG_FUNCTION_INFO_V1(myam_handler);
Datum
myam_handler(PG_FUNCTION_ARGS)
{
    TableAmRoutine *amroutine = makeNode(TableAmRoutine);

    amroutine->slot_callbacks = myam_slot_callbacks;
    amroutine->scan_begin = myam_scan_begin;
    amroutine->scan_end = myam_scan_end;
    amroutine->scan_getnextslot = myam_scan_getnextslot;
    /* ... fill in all required callbacks ... */

    PG_RETURN_POINTER(amroutine);
}
```

### Table AM API

The `TableAmRoutine` struct contains approximately 40 callback function pointers organized into six categories:

```
TableAmRoutine
 |
 +-- Slot Callbacks
 |    +-- slot_callbacks          : return TupleTableSlotOps for this AM
 |
 +-- Table Scan Callbacks
 |    +-- scan_begin              : start a sequential scan
 |    +-- scan_end                : end a scan
 |    +-- scan_rescan             : restart a scan
 |    +-- scan_getnextslot        : fetch next tuple into a slot
 |    +-- scan_set_tidrange       : set TID range for range scans (optional)
 |    +-- scan_getnextslot_tidrange : fetch next tuple in TID range (optional)
 |
 +-- Parallel Scan Callbacks
 |    +-- parallelscan_estimate   : shared memory size for parallel scan
 |    +-- parallelscan_initialize : set up parallel scan descriptor
 |    +-- parallelscan_reinitialize : reset parallel scan
 |
 +-- Index Scan Callbacks
 |    +-- index_fetch_begin       : prepare for index-driven tuple fetches
 |    +-- index_fetch_reset       : release cross-fetch resources
 |    +-- index_fetch_end         : end index fetch
 |    +-- index_fetch_tuple       : fetch tuple by TID from index scan
 |
 +-- Tuple Manipulation Callbacks
 |    +-- tuple_fetch_row_version : fetch specific tuple version by TID
 |    +-- tuple_tid_valid         : validate a TID
 |    +-- tuple_get_latest_tid    : follow update chain to latest version
 |    +-- tuple_satisfies_snapshot: visibility check
 |    +-- index_delete_tuples     : bulk delete check for index cleanup
 |    +-- tuple_insert            : insert a single tuple
 |    +-- tuple_insert_speculative: speculative insert (ON CONFLICT)
 |    +-- tuple_complete_speculative: confirm/abort speculative insert
 |    +-- multi_insert            : bulk insert
 |    +-- tuple_delete            : delete by TID
 |    +-- tuple_update            : update by TID
 |    +-- tuple_lock              : lock a tuple (SELECT FOR UPDATE)
 |    +-- finish_bulk_insert      : finalize bulk operations (optional)
 |
 +-- DDL Callbacks
 |    +-- relation_set_new_filelocator : create new storage
 |    +-- relation_nontransactional_truncate : truncate storage
 |    +-- relation_copy_data      : copy storage (tablespace change)
 |    +-- relation_copy_for_cluster : CLUSTER / VACUUM FULL
 |    +-- relation_vacuum         : VACUUM
 |    +-- scan_analyze_next_block : ANALYZE block sampling
 |    +-- scan_analyze_next_tuple : ANALYZE tuple sampling
 |    +-- index_build_range_scan  : scan table for index build
 |    +-- index_validate_scan     : concurrent index build validation
 |
 +-- Miscellaneous Callbacks
 |    +-- relation_size           : return size in bytes
 |    +-- relation_needs_toast_table : does AM need TOAST?
 |    +-- relation_toast_am       : which AM for the TOAST table?
 |    +-- relation_fetch_toast_slice : detoast a value
 |    +-- relation_estimate_size  : planner size estimation
 |
 +-- Executor Callbacks
      +-- scan_bitmap_next_tuple  : bitmap scan support (optional)
      +-- scan_sample_next_block  : TABLESAMPLE block selection
      +-- scan_sample_next_tuple  : TABLESAMPLE tuple selection
```

#### The Scan Lifecycle

The most common code path through the Table AM is a sequential scan:

```
table_beginscan(rel, snapshot, nkeys, keys)
  |
  +--> rel->rd_tableam->scan_begin(rel, snapshot, nkeys, keys, NULL, flags)
  |    Returns: TableScanDesc (AM-specific, typically embedded in larger struct)
  |
  v
table_scan_getnextslot(scan, ForwardScanDirection, slot)  [called in a loop]
  |
  +--> scan->rs_rd->rd_tableam->scan_getnextslot(scan, direction, slot)
  |    Returns: true if tuple found, false if scan complete
  |    Side effect: fills slot with tuple data
  |
  v
table_endscan(scan)
  |
  +--> scan->rs_rd->rd_tableam->scan_end(scan)
```

#### TM_Result: The DML Return Code

All DML callbacks (`tuple_delete`, `tuple_update`, `tuple_lock`) return a `TM_Result` enum that tells the executor what happened:

```c
typedef enum TM_Result
{
    TM_Ok,              /* Operation succeeded */
    TM_Invisible,       /* Tuple not visible to this snapshot */
    TM_SelfModified,    /* Modified by current transaction */
    TM_Updated,         /* Modified by another transaction */
    TM_Deleted,         /* Deleted by another transaction */
    TM_BeingModified,   /* Concurrent modification in progress */
    TM_WouldBlock,      /* Lock would block (SKIP LOCKED) */
} TM_Result;
```

The executor uses these codes to implement retry loops for concurrent updates and the `ON CONFLICT` protocol.

### Index AM API

The `IndexAmRoutine` struct defines the contract for index access methods. It contains both boolean capability flags and function pointer callbacks:

```
IndexAmRoutine
 |
 +-- Capability Flags
 |    +-- amstrategies      : number of operator strategies (0 = variable)
 |    +-- amsupport          : number of support functions
 |    +-- amcanorder         : can return tuples in index order?
 |    +-- amcanorderbyop     : ORDER BY operator result?
 |    +-- amcanbackward      : backward scan support?
 |    +-- amcanunique        : UNIQUE constraint support?
 |    +-- amcanmulticol      : multi-column indexes?
 |    +-- amsearcharray       : ScalarArrayOpExpr handling?
 |    +-- amsearchnulls      : IS NULL / IS NOT NULL?
 |    +-- amclusterable      : CLUSTER support?
 |    +-- ampredlocks        : predicate lock support?
 |    +-- amcanparallel      : parallel scan?
 |    +-- amcaninclude       : INCLUDE columns?
 |    +-- amsummarizing      : block-level granularity (like BRIN)?
 |
 +-- Index Build Callbacks
 |    +-- ambuild            : build index from scratch
 |    +-- ambuildempty       : build empty index (for WAL replay)
 |    +-- aminsert           : insert single index entry
 |    +-- aminsertcleanup    : post-insert cleanup (optional)
 |
 +-- Index Maintenance
 |    +-- ambulkdelete       : bulk delete during VACUUM
 |    +-- amvacuumcleanup    : post-VACUUM cleanup
 |
 +-- Index Scan Callbacks
 |    +-- ambeginscan        : prepare for index scan
 |    +-- amrescan           : (re)start scan with new keys
 |    +-- amgettuple         : get next matching TID (optional)
 |    +-- amgetbitmap        : get all matching TIDs as bitmap (optional)
 |    +-- amendscan          : end index scan
 |    +-- ammarkpos          : mark current position (optional)
 |    +-- amrestrpos         : restore marked position (optional)
 |
 +-- Cost Estimation
 |    +-- amcostestimate     : provide cost estimates to planner
 |    +-- amgettreeheight    : estimate tree height (optional)
 |
 +-- Metadata
 |    +-- amcanreturn        : can index return data directly? (optional)
 |    +-- amoptions          : parse reloptions
 |    +-- amproperty         : report AM/index properties (optional)
 |    +-- amvalidate         : validate opclass definition
 |    +-- amadjustmembers    : validate opfamily changes (optional)
 |
 +-- Parallel Scan
 |    +-- amestimateparallelscan : DSM size estimate (optional)
 |    +-- aminitparallelscan    : initialize parallel scan (optional)
 |    +-- amparallelrescan      : restart parallel scan (optional)
 |
 +-- Strategy Translation
      +-- amtranslatestrategy  : AM strategy to CompareType (optional)
      +-- amtranslatecmptype   : CompareType to AM strategy (optional)
```

#### The Index Scan Lifecycle

```
ambeginscan(indexRelation, nkeys, norderbys)
  |
  +--> Returns: IndexScanDesc
  |
  v
amrescan(scan, keys, nkeys, orderbys, norderbys)
  |
  +--> Initializes scan with search keys
  |
  v
amgettuple(scan, ForwardScanDirection)  [called in a loop]
  |
  +--> Returns: true if found, with scan->xs_heaptid set
  |    The executor then calls table AM to fetch the actual tuple
  |
  v
amendscan(scan)
```

For bitmap scans, `amgetbitmap` is called instead of `amgettuple`. It fills a `TIDBitmap` with all matching TIDs at once, which the executor then uses to drive a bitmap heap scan.

### How the Executor Connects Table AM and Index AM

During an index scan, the executor coordinates both APIs:

```
IndexScan executor node
  |
  +-- index_beginscan()     --> IndexAmRoutine->ambeginscan()
  +-- index_rescan()        --> IndexAmRoutine->amrescan()
  |
  +-- Loop:
  |    index_getnext_tid()  --> IndexAmRoutine->amgettuple()
  |      |                       returns TID
  |      v
  |    index_fetch_tuple()  --> TableAmRoutine->index_fetch_tuple()
  |      |                       returns tuple in slot
  |      v
  |    Return slot to parent node
  |
  +-- index_endscan()       --> IndexAmRoutine->amendscan()
```

## Key Data Structures

### TableScanDesc

The base scan descriptor returned by `scan_begin`. Access methods embed this in a larger struct:

```
TableScanDescData
 +-- rs_rd           : Relation (the table being scanned)
 +-- rs_snapshot     : Snapshot (visibility rules)
 +-- rs_nkeys        : int (number of scan keys)
 +-- rs_key          : ScanKey (array of scan keys)
 +-- rs_flags        : uint32 (SO_TYPE_* | SO_ALLOW_*)
 +-- rs_parallel     : ParallelTableScanDesc (NULL if not parallel)
```

The heap AM embeds this as the first field of `HeapScanDescData`, which adds heap-specific state like the current buffer, page, and line pointer offset.

### IndexScanDesc

```
IndexScanDescData
 +-- heapRelation     : Relation
 +-- indexRelation     : Relation
 +-- xs_snapshot       : Snapshot
 +-- numberOfKeys      : int
 +-- keyData           : ScanKey
 +-- xs_heaptid        : ItemPointerData (current result TID)
 +-- xs_itup           : IndexTuple (current index tuple)
 +-- xs_want_itup      : bool (index-only scan?)
 +-- opaque            : void* (AM-private state)
```

## Implementing a Custom Table AM: Required vs Optional Callbacks

Not all callbacks in `TableAmRoutine` are required. The `GetTableAmRoutine` function validates that mandatory callbacks are filled in:

| Callback | Required? | Notes |
|----------|-----------|-------|
| `slot_callbacks` | Yes | Must return appropriate `TupleTableSlotOps` |
| `scan_begin` / `scan_end` / `scan_rescan` / `scan_getnextslot` | Yes | Core scan functionality |
| `index_fetch_begin` / `index_fetch_end` / `index_fetch_tuple` | Yes | Index scan support |
| `tuple_insert` / `tuple_delete` / `tuple_update` | Yes | DML support |
| `tuple_lock` | Yes | `SELECT FOR UPDATE` |
| `relation_set_new_filelocator` | Yes | DDL (CREATE TABLE) |
| `relation_vacuum` | Yes | VACUUM support |
| `scan_bitmap_next_tuple` | No | Only needed for bitmap scan support |
| `finish_bulk_insert` | No | Only needed if bulk insert state requires finalization |
| `scan_set_tidrange` / `scan_getnextslot_tidrange` | No | Both or neither must be provided |

## Connections to Other Chapters

| Chapter | Connection |
|---------|-----------|
| [Chapter 2: Access Methods](../02-access-methods/) | The built-in B-tree, hash, GiST, GIN, BRIN, and heap all implement these same APIs |
| [Chapter 1: Storage](../01-storage/) | Table AMs manage physical storage through the buffer manager and storage manager interfaces |
| [Chapter 8: Executor](../08-executor/) | The executor drives all access through `table_*` and `index_*` wrapper functions that dispatch to AM callbacks |
| [Chapter 7: Query Optimizer](../07-query-optimizer/) | The planner calls `amcostestimate` and checks capability flags to decide which scan strategies are available |
| [Chapter 3: Transactions](../03-transactions/) | `TM_Result` codes drive the executor's concurrency control behavior for updates and locks |
