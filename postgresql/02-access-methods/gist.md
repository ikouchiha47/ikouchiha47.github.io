---
title: "GiST Index"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "02-access-methods"
chapter_title: "Access Methods"
chapter_url: "/postgresql/02-access-methods/"
---

# GiST (Generalized Search Tree)

## Summary

GiST is a **balanced, height-balanced tree** that generalizes B-trees to
support arbitrary data types and query predicates. Unlike a B-tree (which
requires a total ordering), GiST works with any data type that can define
**consistent**, **union**, **penalty**, and **picksplit** functions. It powers
PostgreSQL's built-in support for geometric types, range types, full-text
search (`tsvector`), and the PostGIS extension for spatial data.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/access/gist/gist.c` | Entry points: `gisthandler()`, `gistinsert()`, `gistgettuple()`, `gistgetbitmap()` |
| `src/backend/access/gist/gistbuild.c` | `gistbuild()` -- buffered bulk loading |
| `src/backend/access/gist/gistbuildbuffers.c` | In-memory buffers for build |
| `src/backend/access/gist/gistget.c` | `gistgettuple()` -- priority queue scan |
| `src/backend/access/gist/gistsplit.c` | Page split logic using `picksplit` callback |
| `src/backend/access/gist/gistutil.c` | Tuple management, page utilities |
| `src/backend/access/gist/gistproc.c` | Built-in opclass support functions (box, point, polygon) |
| `src/backend/access/gist/gistscan.c` | Scan initialization |
| `src/backend/access/gist/gistvacuum.c` | VACUUM support |
| `src/backend/access/gist/gistxlog.c` | WAL redo |
| `src/backend/access/gist/gistvalidate.c` | Operator class validation |
| `src/backend/access/gist/README` | Design notes |
| `src/include/access/gist.h` | `GISTPageOpaqueData`, `GISTENTRY`, `GIST_SPLITVEC` |
| `src/include/access/gist_private.h` | `GISTSTATE`, `GISTInsertStack`, `GISTSearchItem` |

---

## How It Works

### Tree Structure

GiST is a balanced tree where:
- **Internal nodes** contain *bounding predicates* (e.g., bounding boxes) that
  cover all entries in the subtree below.
- **Leaf nodes** contain the actual indexed values with TIDs.

```
             +--------------------+
             | root: covers all   |
             | [bbox_whole_table] |
             +----+----------+---+
                  |          |
       +----------+     +----+--------+
       | internal  |     | internal   |
       | [bbox_NW] |     | [bbox_SE]  |
       +--+----+---+     +--+----+---+
          |    |             |    |
        leaf  leaf         leaf  leaf
        entries            entries
```

### User-Defined Operator Class Functions

A GiST opclass must provide these support functions:

| # | Function | Purpose |
|---|----------|---------|
| 1 | `consistent` | Does a subtree/leaf match the query predicate? |
| 2 | `union` | Compute the union of a set of entries (bounding predicate) |
| 3 | `compress` | Transform a datum for storage in the index |
| 4 | `decompress` | Reverse of compress (often identity) |
| 5 | `penalty` | Cost of inserting an entry into a subtree |
| 6 | `picksplit` | Split a set of entries into two groups |
| 7 | `same` | Are two entries identical? |
| 8 | `distance` (optional) | Distance from entry to query (for KNN) |
| 9 | `fetch` (optional) | Reconstruct original datum from index (for index-only scans) |

### Search Algorithm

GiST search uses a **priority queue** (ordered by distance for KNN, or
traversal order for containment queries):

```
gistgettuple(scan)
  -> GISTSearchItem queue (pairing heap)
  -> push root onto queue
  -> loop:
       pop item with lowest distance/penalty
       if leaf:
         return tuple to executor
       if internal:
         for each child:
           call consistent(child_key, query)
           if true: push child onto queue with distance()
```

For non-ordered scans (e.g., `@>`, `&&`), the queue degenerates to a stack
(depth-first). For KNN scans (`ORDER BY geom <-> point`), the priority queue
ensures nearest results are returned first.

### Insert Algorithm

```
gistinsert(rel, values, tid)
  -> gistdoinsert()
       -> descend from root, at each level:
            call penalty() for each child
            choose child with lowest penalty
       -> at leaf: insert entry
            if page full:
              -> gistsplit() calls picksplit() to divide entries
              -> may cascade splits up the tree
              -> adjust parent bounding predicates via union()
```

---

## Key Data Structures

### GISTPageOpaqueData

```c
// src/include/access/gist.h
typedef struct GISTPageOpaqueData
{
    FullTransactionId gist_page_id;   // for deleted page tracking
    BlockNumber rightlink;            // right sibling (like Lehman-Yao)
    uint16      flags;                // F_LEAF, F_DELETED, F_FOLLOW_RIGHT, F_TUPLES_DELETED
} GISTPageOpaqueData;
```

### GISTENTRY

```c
// src/include/access/gist.h
typedef struct GISTENTRY
{
    Datum       key;            // the indexed value (or bounding predicate)
    Relation    rel;
    Page        page;
    OffsetNumber offset;
    bool        leafkey;        // true if this is a leaf-level entry
} GISTENTRY;
```

### GIST_SPLITVEC

```c
// src/include/access/gist.h
typedef struct GIST_SPLITVEC
{
    OffsetNumber *spl_left;     // array of offsets going to left page
    int          spl_nleft;
    Datum        spl_ldatum;    // union of left entries
    OffsetNumber *spl_right;    // array of offsets going to right page
    int          spl_nright;
    Datum        spl_rdatum;    // union of right entries
} GIST_SPLITVEC;
```

### GISTInsertStack

```c
// src/include/access/gist_private.h
typedef struct GISTInsertStack
{
    BlockNumber blkno;
    Buffer      buffer;
    Page        page;
    GistNSN     lsn;
    OffsetNumber downlinkoffnum;    // where the downlink to child is
    struct GISTInsertStack *parent;
    // ...
} GISTInsertStack;
```

---

## Diagram: GiST Split

```
 Before split (page full):
 +---------------------------------------+
 | entry A  entry B  entry C  entry D    |
 | entry E  entry F  entry G  entry H    |
 +---------------------------------------+

 picksplit() divides into two groups:

 Left page:                Right page:
 +-------------------+     +-------------------+
 | entry A  entry C  |     | entry B  entry D  |
 | entry E  entry G  |     | entry F  entry H  |
 +-------------------+     +-------------------+

 Parent gets two entries:
   union(A,C,E,G)  ->  left page
   union(B,D,F,H)  ->  right page
```

---

## Buffered Build

For large tables, `gistbuild()` uses a **buffered build** strategy
(`gistbuildbuffers.c`):

1. Assign each internal node a buffer (in memory or on temp files).
2. Tuples are pushed into the root buffer.
3. When a buffer fills, its contents are flushed down one level.
4. This reduces random I/O by batching inserts.

Controlled by `buffering = auto | on | off` in `CREATE INDEX`.

---

## Common Use Cases

| Data Type | Operators | Example |
|-----------|-----------|---------|
| `point`, `box`, `polygon` | `<<`, `>>`, `@>`, `<@`, `&&`, `<->` | Spatial containment, nearest neighbor |
| `inet`, `cidr` | `>>=`, `<<=` | Network containment |
| `range` types | `@>`, `<@`, `&&`, `-|-` | Range overlap and containment |
| `tsvector` | `@@` | Full-text search |
| `ltree` | `@>`, `<@` | Label tree queries |

---

## Connections

- **SP-GiST**: An alternative for space-partitioned structures (quad trees,
  k-d trees) where GiST's balanced tree is less natural.
- **GIN**: For full-text search, GIN is often preferred over GiST because it
  stores exact lexeme lists. GiST uses lossy signatures.
- **Planner**: GiST sets `amcanorderbyop = true` to enable KNN (`ORDER BY ...
  <->`) optimization. The planner calls `gistcostestimate()`.
- **WAL**: `gistxlog.c` handles redo for page splits, updates, and deletions.
