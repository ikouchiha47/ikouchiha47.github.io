---
title: "BRIN Index"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "02-access-methods"
chapter_title: "Access Methods"
chapter_url: "/postgresql/02-access-methods/"
---

# BRIN (Block Range Index)

## Summary

BRIN is a **lossy, summarizing index** that stores aggregate information (e.g.,
min/max values) for ranges of consecutive heap pages. It is extremely compact
-- often just a few kilobytes for tables with billions of rows -- but only
effective when the physical order of data on disk correlates with the indexed
column values. BRIN excels at large, append-mostly tables where the indexed
column naturally increases (timestamps, serial IDs).

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/access/brin/brin.c` | Entry points: `brinhandler()`, `brininsert()`, `bringetbitmap()`, `brinbuild()` |
| `src/backend/access/brin/brin_pageops.c` | Page-level operations, tuple storage |
| `src/backend/access/brin/brin_revmap.c` | Reverse mapping: heap block range -> BRIN summary tuple |
| `src/backend/access/brin/brin_tuple.c` | BRIN tuple serialization/deserialization |
| `src/backend/access/brin/brin_minmax.c` | Min/max opclass (default) |
| `src/backend/access/brin/brin_minmax_multi.c` | Multi-range min/max opclass |
| `src/backend/access/brin/brin_inclusion.c` | Inclusion opclass (for range/box types) |
| `src/backend/access/brin/brin_bloom.c` | Bloom filter opclass |
| `src/backend/access/brin/brin_validate.c` | Opclass validation |
| `src/backend/access/brin/brin_xlog.c` | WAL redo |
| `src/backend/access/brin/README` | Design document |
| `src/include/access/brin.h` | `BrinOptions`, `BrinStatsData` |
| `src/include/access/brin_page.h` | `BrinSpecialSpace`, `BrinMetaPageData`, `RevmapContents` |
| `src/include/access/brin_internal.h` | `BrinOpcInfo`, `BrinDesc` |
| `src/include/access/brin_tuple.h` | `BrinMemTuple`, `BrinValues` |

---

## How It Works

### Core Concept

BRIN divides the heap into **block ranges** of `pages_per_range` consecutive
pages (default 128). For each range, it stores a **summary tuple** containing
aggregate information about the indexed column values in that range.

```
 Heap pages:  [0..127]  [128..255]  [256..383]  [384..511]  ...
                 |           |           |           |
                 v           v           v           v
 BRIN index:  summary_0  summary_1  summary_2  summary_3  ...
              min=1       min=1000   min=2000   min=3000
              max=999     max=1999   max=2999   max=3999
```

### Three Components

1. **Regular pages**: Store the BRIN summary tuples (variable-length).
2. **Revmap (Reverse Map) pages**: A fixed-size array mapping each block range
   number to the `ItemPointerData` of its summary tuple.
3. **Meta page** (block 0): Stores `pages_per_range`, revmap start block, and
   last revmap page.

### Scan Algorithm

```
bringetbitmap(scan)
  -> for each block range:
       -> look up summary tuple via revmap
       -> if no summary (unsummarized range):
            add all pages in range to bitmap (must scan them)
       -> call opclass consistent() with scan keys and summary values
            if consistent returns true:
              add all pages in range to bitmap
            else:
              skip entire range
  -> return lossy bitmap to executor
       (executor does bitmap heap scan with rechecks)
```

The bitmap is **lossy** at the page level: BRIN knows which block ranges
*might* contain matching tuples, but not which specific tuples.

### Insert Path

```
brininsert(rel, values, tid)
  -> compute block range number from TID's block
  -> look up summary via revmap
  -> if summary exists:
       -> call opclass add_value() to update summary
            (e.g., extend min/max range if new value is outside)
       -> if summary changed: write updated tuple
  -> if no summary:
       -> create new summary tuple for this range
       -> store in regular page, update revmap
```

---

## Key Data Structures

### BrinMetaPageData

```c
// src/include/access/brin_page.h
typedef struct BrinMetaPageData
{
    uint32      brinMagic;
    uint32      brinVersion;
    BlockNumber pagesPerRange;     // heap pages per block range
    BlockNumber lastRevmapPage;    // last revmap page block
    BlockNumber lastRegularPage;   // last regular (summary) page
} BrinMetaPageData;
```

### RevmapContents

```c
// src/include/access/brin_page.h
typedef struct RevmapContents
{
    // Array of ItemPointerData, one per block range.
    // rm_tids[i] points to the summary tuple for range i
    // (relative to this revmap page's starting range).
    ItemPointerData rm_tids[REVMAP_PAGE_MAXITEMS];
} RevmapContents;
```

### BrinOpcInfo

```c
// src/include/access/brin_internal.h
typedef struct BrinOpcInfo
{
    uint16      oi_nstored;          // number of stored values per range
    uint16      oi_regular_nulls;    // how nulls are represented
    uint16      oi_opaque_size;      // extra space needed
    Oid         oi_typcache[FLEXIBLE_ARRAY_MEMBER];  // type cache entries
} BrinOpcInfo;
```

### BrinDesc

```c
// src/include/access/brin_internal.h
typedef struct BrinDesc
{
    Relation        bd_index;
    TupleDesc       bd_tupdesc;      // summary tuple descriptor
    int             bd_totalstored;  // total stored values across all columns
    BrinOpcInfo    *bd_info[FLEXIBLE_ARRAY_MEMBER];  // per-column opclass info
} BrinDesc;
```

---

## Diagram: BRIN Physical Layout

```
 Block 0: Meta page
 +--------------------------+
 | BrinMetaPageData         |
 | pagesPerRange = 128      |
 | lastRevmapPage = 1       |
 +--------------------------+

 Block 1: Revmap page
 +--------------------------+
 | RevmapContents           |
 | rm_tids[0] -> (5, 1)     |  <-- summary for range 0 is at block 5, offset 1
 | rm_tids[1] -> (5, 2)     |
 | rm_tids[2] -> (5, 3)     |
 | ...                      |
 +--------------------------+

 Block 5: Regular page (summary tuples)
 +--------------------------+
 | Summary tuple 1:         |
 |   range 0: min=1 max=999 |
 | Summary tuple 2:         |
 |   range 1: min=1000      |
 |            max=1999      |
 | ...                      |
 +--------------------------+
```

---

## Opclass Strategies

BRIN supports multiple summarization strategies through opclasses:

### minmax (default)

Stores the minimum and maximum value for each range. Effective for columns with
natural ordering correlation.

### minmax_multi (PostgreSQL 14+)

Stores multiple min/max intervals per range. Handles columns where values are
clustered into groups rather than a single range.

### inclusion

Stores a bounding value that *includes* all values in the range. Used for
range types and geometric types (e.g., `box`). The summary is a single
bounding box/range that covers all values.

### bloom (PostgreSQL 14+)

Stores a Bloom filter of all values in the range. Works for equality queries
on columns with no ordering correlation. Probabilistic -- may produce false
positives but never false negatives.

---

## When BRIN Works Well (and When It Does Not)

**Good fit**:
- Large tables (hundreds of millions of rows)
- Column values correlate strongly with physical row order
- Append-only or append-mostly workloads
- Timestamp columns on time-series data
- Sequential ID columns

**Poor fit**:
- Randomly ordered data (every range covers the full value space)
- Small tables (overhead of bitmap heap scan outweighs benefit)
- Point queries requiring exact lookups (B-tree is better)

The correlation statistic (`pg_stats.correlation`) is a good predictor:
values close to 1.0 or -1.0 indicate BRIN will be effective.

---

## Connections

- **B-tree**: B-tree provides exact lookups; BRIN provides approximate
  filtering. For naturally ordered large tables, BRIN can be 100-1000x smaller
  than a B-tree.
- **Heap AM**: BRIN summaries are per-block-range of the heap. The heap's
  physical layout directly determines BRIN effectiveness.
- **Planner**: BRIN sets `amsummarizing = true`. The planner accounts for the
  lossy nature of BRIN and adds recheck conditions.
- **VACUUM**: `brin_summarize_new_values()` summarizes ranges that were inserted
  since the last summarization. `VACUUM` calls this automatically.
- **WAL**: `brin_xlog.c` handles redo for summary tuple inserts, updates, and
  revmap changes.
