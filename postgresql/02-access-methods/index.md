---
title: "Access Methods"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "02-access-methods"
chapter_title: "Access Methods"
is_chapter_index: true
---

# Chapter 2: Access Methods

## Summary

Access Methods (AMs) are PostgreSQL's abstraction for how data is stored and
retrieved. Every table is managed by a **Table AM** (almost always the heap),
and every index is managed by an **Index AM** (B-tree, hash, GiST, GIN, BRIN,
or SP-GiST). PostgreSQL 12+ exposes both as pluggable APIs, letting extensions
provide entirely new storage engines or index types without modifying the core.

---

## Overview

PostgreSQL separates *what* the executor wants (scan a table, insert a tuple,
look up a key) from *how* the AM accomplishes it. Two callback structs sit at
the centre of this design:

| Layer | Callback Struct | Header | Purpose |
|-------|----------------|--------|---------|
| Table AM | `TableAmRoutine` | `src/include/access/tableam.h` | Scan, fetch, insert, update, delete, vacuum for heap-like stores |
| Index AM | `IndexAmRoutine` | `src/include/access/amapi.h` | Build, insert, scan, vacuum for index structures |

Each AM registers a **handler function** (e.g., `heap_tableam_handler`,
`bthandler`) that returns a pointer to the filled-in routine struct. The
executor then calls through these function pointers, never knowing which
concrete AM is behind the relation.

---

## Architecture Diagram

```
                        Executor
                           |
              +------------+------------+
              |                         |
       table_scan_*()            index_scan_*()
              |                         |
      +-------v--------+      +--------v--------+
      | TableAmRoutine  |      | IndexAmRoutine   |
      | (tableam.h)     |      | (amapi.h)        |
      +-------+---------+      +--------+---------+
              |                         |
    +---------+          +---------+---------+---------+---------+
    |                    |         |         |         |         |
  Heap AM           B-tree     Hash      GiST      GIN      BRIN
  (heap/)           (nbtree/)  (hash/)   (gist/)   (gin/)   (brin/)
                                                              |
                                                           SP-GiST
                                                           (spgist/)
```

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/include/access/amapi.h` | `IndexAmRoutine` definition and all index AM callback typedefs |
| `src/include/access/tableam.h` | `TableAmRoutine` definition and table AM callback typedefs |
| `src/backend/access/table/tableam.c` | Generic table AM dispatcher functions |
| `src/backend/access/table/tableamapi.c` | `GetTableAmRoutine()` -- resolves handler OID to routine |
| `src/backend/access/index/` | Generic index AM utilities (`amapi.c`, `indexam.c`, `genam.c`) |
| `src/include/access/genam.h` | `IndexScanDesc` and generic index scan definitions |
| `src/include/access/relscan.h` | `TableScanDesc` base struct |

---

## How the Pieces Fit Together

### Table Access

1. `table_beginscan()` calls `scan_begin` in the `TableAmRoutine`.
2. The heap AM creates a `HeapScanDescData` (which embeds a `TableScanDescData`).
3. `table_scan_getnextslot()` calls `scan_getnextslot` to fetch tuples.
4. Visibility is checked via `HeapTupleSatisfiesVisibility()`.

### Index Access

1. `index_beginscan()` calls `ambeginscan` in the `IndexAmRoutine`.
2. For a B-tree, `btbeginscan()` allocates `BTScanOpaqueData`.
3. `index_getnext_slot()` calls `amgettuple`, which walks the tree and
   returns TIDs. The executor then calls `index_fetch_tuple` on the table AM
   to retrieve the heap tuple.

### Planner Integration

The planner calls `amcostestimate` to get selectivity and cost for each
potential index path. Flags like `amcanorder`, `amcanunique`, and
`amsearcharray` on `IndexAmRoutine` tell the planner which plan shapes are
valid.

---

## Chapter Contents

| Section | Topic |
|---------|-------|
| [Heap AM](heap.html) | Heap storage, page layout, HOT updates, TOAST |
| [B-tree](btree.html) | Lehman-Yao B+tree, deduplication, page splits |
| [Hash Index](hash.html) | Linear hashing, overflow pages |
| [GiST](gist.html) | Generalized Search Tree for spatial and custom types |
| [GIN](gin.html) | Inverted index, fast update buffer, posting lists |
| [BRIN](brin.html) | Block Range Index for large naturally-ordered tables |
| [SP-GiST](spgist.html) | Space-partitioned trees: k-d trees, radix tries |
| [Table AM API](table-am-api.html) | Pluggable storage API deep dive |

---

## Connections

- **Chapter 1 (Storage and Buffer Manager)**: AMs read and write pages through the buffer manager. The heap page layout (`PageHeaderData`, `ItemIdData`) is the foundation for the heap AM.
- **Chapter 3 (Query Executor)**: The executor drives all AM operations through the `TableAmRoutine` and `IndexAmRoutine` interfaces.
- **Chapter 4 (MVCC and Concurrency)**: Visibility rules in `heapam_visibility.c` determine which tuples the heap AM returns. Index AMs rely on the table AM for final visibility checks.
- **Chapter 5 (WAL and Recovery)**: Every AM writes WAL records for crash safety. Each AM has its own `*_xlog.c` module.
