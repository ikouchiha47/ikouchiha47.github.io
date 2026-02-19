---
title: "Table AM API"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "02-access-methods"
chapter_title: "Access Methods"
chapter_url: "/postgresql/02-access-methods/"
---

# Table AM API (Pluggable Storage)

## Summary

Introduced in PostgreSQL 12, the **Table Access Method API** abstracts all
table-level operations behind the `TableAmRoutine` callback struct. This
enables alternative storage engines -- columnar stores, append-optimized
formats, in-memory engines -- to plug into PostgreSQL without modifying the
executor, planner, or utility commands. The heap remains the default and only
built-in implementation, but the API boundary is clean and well-defined.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/include/access/tableam.h` | `TableAmRoutine` definition, inline dispatch functions (`table_beginscan()`, etc.) |
| `src/backend/access/table/tableam.c` | Default implementations and dispatch helpers |
| `src/backend/access/table/tableamapi.c` | `GetTableAmRoutine()` -- resolves handler OID to `TableAmRoutine` pointer |
| `src/backend/access/table/table.c` | `table_open()`, `table_close()` -- relation open/close wrappers |
| `src/backend/access/table/toast_helper.c` | TOAST helper functions for any table AM |
| `src/backend/access/heap/heapam_handler.c` | `heap_tableam_handler()` -- the heap's `TableAmRoutine` implementation |
| `src/include/access/amapi.h` | `IndexAmRoutine` (the index-side counterpart) |

---

## How It Works

### Registration

A table AM is a PostgreSQL extension that:

1. Defines a **handler function** with signature `Datum handler(PG_FUNCTION_ARGS)`
   that returns a pointer to a filled `TableAmRoutine`.
2. Registers the handler as a `pg_am` entry with `amtype = 't'` (table).
3. Tables are created with `CREATE TABLE ... USING <am_name>`.

```sql
-- The default (heap) is implicit:
CREATE TABLE t1 (id int, data text);

-- Explicit AM selection:
CREATE TABLE t2 (id int, data text) USING heap;

-- Hypothetical columnar AM:
CREATE TABLE t3 (id int, data text) USING columnar;

-- Change the default for a session:
SET default_table_access_method = 'columnar';
```

### Callback Categories

The `TableAmRoutine` struct (defined at line 289 of `tableam.h`) organizes
callbacks into these groups:

```
TableAmRoutine
  |
  +-- Slot callbacks
  |     slot_callbacks            // return TupleTableSlotOps for this AM
  |
  +-- Table scan callbacks
  |     scan_begin                // start a sequential scan
  |     scan_end                  // end scan
  |     scan_rescan               // restart scan
  |     scan_getnextslot          // fetch next tuple into slot
  |     scan_set_tidrange         // set TID range for TID range scan
  |     scan_getnextslot_tidrange // fetch next tuple in TID range
  |
  +-- Parallel scan callbacks
  |     parallelscan_estimate     // shared memory size for parallel scan
  |     parallelscan_initialize   // init parallel scan descriptor
  |     parallelscan_reinitialize // reinit for new scan
  |
  +-- Index scan callbacks
  |     index_fetch_begin         // prepare for index-driven heap fetches
  |     index_fetch_reset         // reset between index scans
  |     index_fetch_end           // cleanup
  |     index_fetch_tuple         // fetch tuple by TID, check visibility
  |
  +-- Tuple operations (non-modifying)
  |     tuple_fetch_row_version   // fetch specific tuple version
  |     tuple_tid_valid           // is this TID valid?
  |     tuple_get_latest_tid      // follow update chain
  |     tuple_satisfies_snapshot  // visibility check
  |     tuple_complete_speculative // finalize speculative insert
  |
  +-- Tuple modification callbacks
  |     tuple_insert              // insert one tuple
  |     tuple_insert_speculative  // speculative insert (for ON CONFLICT)
  |     multi_insert              // batch insert
  |     tuple_delete              // delete tuple
  |     tuple_update              // update tuple (delete + insert)
  |     tuple_lock                // lock tuple for SELECT FOR UPDATE
  |
  +-- DDL / utility callbacks
  |     relation_set_new_filelocator  // assign new physical storage
  |     relation_nontransactional_truncate  // fast truncate
  |     relation_copy_data            // copy table data (ALTER TABLE)
  |     relation_copy_for_cluster     // copy for CLUSTER
  |     relation_vacuum               // VACUUM
  |     scan_analyze_next_block       // ANALYZE sampling
  |     scan_analyze_next_tuple       // ANALYZE tuple fetch
  |     index_build_range_scan        // scan for CREATE INDEX
  |     index_validate_scan           // scan for CREATE INDEX CONCURRENTLY
  |
  +-- Estimation / info callbacks
  |     relation_size                 // size of relation in bytes
  |     relation_needs_toast_table    // does this AM need TOAST?
  |     relation_toast_am             // which AM for the TOAST table?
  |     relation_fetch_toast_slice    // fetch a TOAST slice
  |
  +-- Planner support
        relation_estimate_size        // row count and page estimates
```

### Dispatch Pattern

`tableam.h` provides inline wrapper functions that the executor calls:

```c
// src/include/access/tableam.h (simplified)
static inline TableScanDesc
table_beginscan(Relation rel, Snapshot snapshot, int nkeys, ScanKey key)
{
    // ... set up flags
    return rel->rd_tableam->scan_begin(rel, snapshot, nkeys, key, NULL, flags);
}

static inline bool
table_scan_getnextslot(TableScanDesc scan, ScanDirection direction,
                       TupleTableSlot *slot)
{
    return scan->rs_rd->rd_tableam->scan_getnextslot(scan, direction, slot);
}
```

The `Relation` struct caches the `TableAmRoutine` pointer in `rd_tableam`,
set once during `RelationInitPhysicalAddr()` via `GetTableAmRoutine()`.

---

## Key Data Structures

### TableAmRoutine (abbreviated)

```c
// src/include/access/tableam.h
typedef struct TableAmRoutine
{
    NodeTag     type;   // T_TableAmRoutine

    // slot
    const TupleTableSlotOps *(*slot_callbacks)(Relation rel);

    // scans
    TableScanDesc (*scan_begin)(Relation rel, Snapshot snapshot,
                                int nkeys, ScanKeyData *key,
                                ParallelTableScanDesc pscan, uint32 flags);
    void (*scan_end)(TableScanDesc scan);
    bool (*scan_getnextslot)(TableScanDesc scan, ScanDirection direction,
                             TupleTableSlot *slot);

    // index fetch
    struct IndexFetchTableData *(*index_fetch_begin)(Relation rel);
    bool (*index_fetch_tuple)(struct IndexFetchTableData *scan,
                              ItemPointer tid, Snapshot snapshot,
                              TupleTableSlot *slot,
                              bool *call_again, bool *all_dead);

    // modifications
    void (*tuple_insert)(Relation rel, TupleTableSlot *slot,
                         CommandId cid, int options, BulkInsertState bistate);
    TM_Result (*tuple_delete)(Relation rel, ItemPointer tid, ...);
    TM_Result (*tuple_update)(Relation rel, ItemPointer otid,
                              TupleTableSlot *slot, ...);

    // VACUUM
    void (*relation_vacuum)(Relation rel, struct VacuumParams *params,
                            BufferAccessStrategy bstrategy);

    // ... many more callbacks
} TableAmRoutine;
```

### TM_Result (modification outcomes)

```c
// src/include/access/tableam.h
typedef enum TM_Result
{
    TM_Ok,                  // operation succeeded
    TM_Invisible,           // tuple not visible to our snapshot
    TM_SelfModified,        // modified by our own transaction
    TM_Updated,             // tuple was updated by concurrent txn
    TM_Deleted,             // tuple was deleted by concurrent txn
    TM_BeingModified,       // tuple is being modified (locked)
    TM_WouldBlock           // would block (SKIP LOCKED)
} TM_Result;
```

### IndexFetchTableData

```c
// Base struct for index-driven tuple fetches.
// The heap embeds this in IndexFetchHeapData (heapam.h).
typedef struct IndexFetchTableData
{
    Relation    rel;
} IndexFetchTableData;
```

---

## Diagram: Table AM Dispatch

```
  SELECT * FROM t WHERE id = 42;

  Executor (nodeIndexScan.c)
       |
       | index_getnext_slot()
       |     |
       |     v
       | IndexAmRoutine->amgettuple()   // B-tree returns TID
       |     |
       |     v
       | table_index_fetch_tuple()      // dispatch to table AM
       |     |
       |     v
       | TableAmRoutine->index_fetch_tuple()
       |     |
       |     +-- [heap] heap_index_fetch_tuple()
       |     |     -> read buffer for TID's block
       |     |     -> HeapTupleSatisfiesVisibility()
       |     |     -> if visible: fill slot, return true
       |     |
       |     +-- [columnar] columnar_index_fetch_tuple()
       |           -> read column chunks for TID
       |           -> reconstruct tuple into slot
       v
  Return tuple to upper plan node
```

---

## Implementing a Custom Table AM

A minimal table AM extension must:

1. Implement all **required** callbacks in `TableAmRoutine` (most are required;
   a few like `scan_set_tidrange` are optional).
2. Define a handler function:
   ```c
   PG_FUNCTION_INFO_V1(my_am_handler);
   Datum my_am_handler(PG_FUNCTION_ARGS)
   {
       TableAmRoutine *amroutine = makeNode(TableAmRoutine);
       amroutine->slot_callbacks = my_slot_callbacks;
       amroutine->scan_begin = my_scan_begin;
       // ... fill all callbacks
       PG_RETURN_POINTER(amroutine);
   }
   ```
3. Register in `pg_am`:
   ```sql
   CREATE ACCESS METHOD my_am TYPE TABLE HANDLER my_am_handler;
   ```
4. Handle TOAST (or declare `relation_needs_toast_table` returns false).
5. Handle VACUUM, ANALYZE, and CREATE INDEX callbacks.

Notable community table AMs include **Citus Columnar** and **Zheap** (undo-
based storage).

---

## Relationship Between Table AM and Index AM

The two APIs are carefully separated:

- **Index AMs** produce TIDs. They know nothing about how tuples are stored.
- **Table AMs** resolve TIDs to tuples. They know nothing about index
  structure.
- The executor bridges them: it asks the index for TIDs, then asks the table
  AM for the actual tuples.

This separation means any index type works with any table type. A columnar
table AM can use B-tree, GIN, or BRIN indexes as long as it implements
`index_fetch_tuple` and the index build callbacks.

---

## Connections

- **Heap AM**: The heap is the reference implementation of `TableAmRoutine`.
  `heapam_handler.c` maps every callback to a concrete heap function.
- **Executor**: `nodeSeqscan.c`, `nodeIndexscan.c`, `nodeModifyTable.c` all
  call through the table AM API, never directly into heap code.
- **VACUUM**: The `relation_vacuum` callback lets each AM define its own
  dead-tuple cleanup strategy.
- **TOAST**: The table AM decides whether it needs a TOAST table and how to
  fetch TOAST slices. The heap uses a side table; other AMs might inline large
  values differently.
- **Catalog**: `pg_am` stores AM registrations. `pg_class.relam` records
  which AM each table uses. Default is controlled by
  `default_table_access_method` GUC.
