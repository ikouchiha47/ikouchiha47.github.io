---
title: "SP-GiST Index"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "02-access-methods"
chapter_title: "Access Methods"
chapter_url: "/postgresql/02-access-methods/"
---

# SP-GiST (Space-Partitioned Generalized Search Tree)

## Summary

SP-GiST supports **unbalanced, space-partitioning** tree structures such as
k-d trees, quadtrees, and radix trees (tries). Unlike GiST, which maintains a
balanced tree with overlapping bounding predicates, SP-GiST recursively divides
the search space into non-overlapping partitions. This makes it the natural
choice for data that decomposes hierarchically -- network addresses, text
prefixes, and point data in low dimensions.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/access/spgist/spginsert.c` | `spginsert()` -- insert routing |
| `src/backend/access/spgist/spgdoinsert.c` | `spgdoinsert()` -- core insert: descend, choose, split |
| `src/backend/access/spgist/spgscan.c` | `spggettuple()`, `spggetbitmap()` -- scan with stack-based traversal |
| `src/backend/access/spgist/spgutils.c` | `spghandler()`, page management, state initialization |
| `src/backend/access/spgist/spgkdtreeproc.c` | k-d tree opclass for `point` |
| `src/backend/access/spgist/spgquadtreeproc.c` | Quadtree opclass for `point` |
| `src/backend/access/spgist/spgtextproc.c` | Radix tree opclass for `text` |
| `src/backend/access/spgist/spgproc.c` | Support for `box`, `inet`, `range` types |
| `src/backend/access/spgist/spgvacuum.c` | VACUUM support |
| `src/backend/access/spgist/spgvalidate.c` | Opclass validation |
| `src/backend/access/spgist/spgxlog.c` | WAL redo |
| `src/backend/access/spgist/README` | Design document |
| `src/include/access/spgist.h` | User-facing callback structs (`spgConfigIn/Out`, `spgChooseIn/Out`, etc.) |
| `src/include/access/spgist_private.h` | `SpGistPageOpaqueData`, `SpGistState`, `SpGistMetaPageData` |

---

## How It Works

### Space-Partitioning Concept

SP-GiST recursively partitions the data space. Each internal node defines a
partitioning rule, and each child covers a non-overlapping region:

**k-d tree** (alternating axis splits):
```
         x < 5
        /     \
     y < 3     y < 7
    /    \    /    \
  (1,2) (3,4) (6,5) (8,9)
```

**Radix tree** (prefix decomposition):
```
           ""
          / \
        "a"  "b"
        / \    \
     "ab" "ac" "ba"
      |          |
    "abc"      "bar"
```

**Quadtree** (2D quadrant splits):
```
         center=(5,5)
        /   |   |   \
       Q1   Q2  Q3  Q4
      NW    NE  SW  SE
```

### Opclass Callback Functions

| Function | Purpose |
|----------|---------|
| `config` | Declare node structure: label type, prefix type, leaf type, whether node labels exist |
| `choose` | Given an inner tuple and a new value, decide: `spgMatchNode` (descend to child), `spgAddNode` (add new child), or `spgSplitTuple` (refine the partition) |
| `picksplit` | Given a set of leaf tuples, create an inner tuple with partitioning rule and distribute leaves among new nodes |
| `inner_consistent` | During scan: which child nodes could contain matching values? |
| `leaf_consistent` | Does a specific leaf tuple match the query? |

### Page Types

SP-GiST uses two kinds of pages:
- **Inner pages**: Store inner tuples (partitioning rules with node labels and
  downlinks).
- **Leaf pages**: Store leaf tuples (indexed values with TIDs).

A key design choice: inner tuples and leaf tuples are stored on **separate
pages**. This avoids the complexity of mixed pages and simplifies concurrency.

### Insert Algorithm

```
spgdoinsert(index, datum, tid)
  -> start at root inner tuple
  -> loop:
       call choose(inner_tuple, datum)
       switch result:
         spgMatchNode:
           follow downlink to child
           if child is leaf page:
             if space available: add leaf tuple, done
             else: call picksplit() to create new inner tuple
           if child is inner page:
             continue loop with child inner tuple

         spgAddNode:
           add a new node to the inner tuple for this datum
           (may require page split if inner tuple grows too large)

         spgSplitTuple:
           replace inner tuple with a more specific partitioning
           (e.g., extend prefix in radix tree)
```

### Scan Algorithm

```
spggettuple(scan)
  -> stack-based traversal (not a priority queue like GiST)
  -> push root onto stack
  -> loop:
       pop item from stack
       if inner tuple:
         call inner_consistent(query, inner_tuple)
         push matching child nodes onto stack
       if leaf tuple:
         call leaf_consistent(query, leaf_tuple)
         if true: return tuple
```

---

## Key Data Structures

### SpGistPageOpaqueData

```c
// src/include/access/spgist_private.h
typedef struct SpGistPageOpaqueData
{
    uint16      flags;          // SPGIST_META, SPGIST_LEAF, SPGIST_DELETED, SPGIST_NULLS
    uint16      nRedirection;   // number of redirect tuples
    uint16      nPlaceholder;   // number of placeholder tuples
    TransactionId xid;          // for deleted pages
} SpGistPageOpaqueData;
```

### SpGistMetaPageData

```c
// src/include/access/spgist_private.h
typedef struct SpGistMetaPageData
{
    uint32          magic;
    uint32          flags;
    SpGistLUPCache  lastUsedPages;  // cache of pages with free space
} SpGistMetaPageData;
```

### SpGistState

```c
// src/include/access/spgist_private.h
typedef struct SpGistState
{
    SpGistTypeDesc attType;           // original data type
    SpGistTypeDesc attPrefixType;     // prefix type (from config)
    SpGistTypeDesc attLabelType;      // node label type (from config)
    SpGistTypeDesc attLeafType;       // leaf stored type
    bool           config_leafType;   // was leaf type overridden?
    // cached opclass support function OIDs
    FmgrInfo    chooseFn;
    FmgrInfo    picksplitFn;
    FmgrInfo    innerConsistentFn;
    FmgrInfo    leafConsistentFn;
    // ...
} SpGistState;
```

### spgChooseIn / spgChooseOut

```c
// src/include/access/spgist.h
typedef struct spgChooseIn
{
    Datum       datum;           // value being inserted
    Datum       prefixDatum;     // current inner tuple's prefix
    int         nNodes;          // number of child nodes
    Datum      *nodeLabels;      // label for each child node
    int         level;           // current depth in tree
    bool        allTheSame;      // all nodes equivalent?
} spgChooseIn;

typedef struct spgChooseOut
{
    enum {
        spgMatchNode,            // descend to an existing node
        spgAddNode,              // add a new child node
        spgSplitTuple            // refine the inner tuple
    } resultType;
    union { ... } result;
} spgChooseOut;
```

---

## Diagram: SP-GiST Radix Tree for Text

```
  Indexed values: "abc", "abd", "bcd", "bce"

  Inner page:
  +------------------------------+
  | Inner tuple: prefix=""       |
  | Node 'a' -> leaf page 3     |
  | Node 'b' -> inner page 4    |
  +------------------------------+

  Leaf page 3:                   Inner page 4:
  +------------------+           +------------------------------+
  | "abc" -> TID_1   |           | Inner tuple: prefix="bc"    |
  | "abd" -> TID_2   |           | Node 'd' -> leaf page 5     |
  +------------------+           | Node 'e' -> leaf page 5     |
                                 +------------------------------+

  Leaf page 5:
  +------------------+
  | "d" -> TID_3     |   (suffix after prefix "bc")
  | "e" -> TID_4     |
  +------------------+
```

Note: Leaf tuples store only the **remaining suffix** after the prefix has been
consumed by ancestor inner tuples. This is a key space optimization.

---

## Built-in Opclasses

| Opclass | Data Type | Tree Type | Operators |
|---------|-----------|-----------|-----------|
| `kd_point_ops` | `point` | k-d tree | `<<`, `>>`, `~=`, `<@`, `<->` |
| `quad_point_ops` | `point` | Quadtree | same |
| `text_ops` | `text` | Radix tree | `=`, `<`, `>`, `<=`, `>=`, `^@` (starts with) |
| `box_ops` | `box` | Quadtree | `<<`, `>>`, `@>`, `<@`, `&&` |
| `inet_ops` | `inet` | Radix tree | `=`, `<`, `>`, `>>=`, `<<=` |
| `range_ops` | `anyrange` | Quadtree | `@>`, `<@`, `&&`, `=` |

---

## Connections

- **GiST**: Both support spatial data, but GiST uses balanced trees with
  overlapping regions while SP-GiST uses unbalanced trees with non-overlapping
  partitions. SP-GiST can be more efficient for uniformly distributed point
  data.
- **B-tree**: For text prefix searches (`LIKE 'abc%'`), the SP-GiST radix
  tree opclass is a specialized alternative to B-tree with `text_pattern_ops`.
- **Heap AM**: Like all index AMs, SP-GiST stores TIDs pointing into the heap.
- **WAL**: `spgxlog.c` handles redo for inner tuple splits, leaf insertions,
  node additions, and page operations.
- **VACUUM**: `spgvacuum.c` removes dead tuples and converts dead inner
  entries to placeholder tuples that can be reclaimed later.
