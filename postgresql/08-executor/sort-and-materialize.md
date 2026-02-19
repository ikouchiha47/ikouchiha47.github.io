---
title: "Sort and Materialize"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "08-executor"
chapter_title: "Executor"
chapter_url: "/postgresql/08-executor/"
---

# Sort and Materialize

## Summary

Sorting and materialization are the key pipeline-breaking operations in the
executor. The **Sort** node uses the `tuplesort` infrastructure to perform
in-memory quicksort for small datasets and external balanced k-way merge sort
for large ones, with I/O managed by the `logtape` module. The **Material** node
buffers all input tuples for repeated access. **IncrementalSort** exploits
partially pre-sorted input. **Memoize** caches results of parameterized scans
using an LRU hash table, avoiding redundant rescans when the same parameter
values recur.

---

## Overview

| Node | Purpose | Blocking? | Memory Behavior |
|---|---|---|---|
| **Sort** | Sort all input tuples by specified keys | Yes | In-memory up to `work_mem`, then external sort |
| **IncrementalSort** | Sort when leading keys are already ordered | Partially | Sorts groups of presorted rows |
| **Material** | Buffer all input for repeated reads | Yes | Spills to tuplestore on disk if needed |
| **Memoize** | Cache parameterized subplan results (LRU) | No (per lookup) | Bounded by `work_mem`, LRU eviction |

---

## Key Source Files

| File | Purpose |
|---|---|
| `src/backend/executor/nodeSort.c` | Sort executor node |
| `src/backend/executor/nodeIncrementalSort.c` | Incremental sort node |
| `src/backend/executor/nodeMaterial.c` | Materialize node |
| `src/backend/executor/nodeMemoize.c` | Memoize (result caching) node |
| `src/backend/utils/sort/tuplesort.c` | Core sorting engine |
| `src/backend/utils/sort/tuplesortvariants.c` | Sort specializations (heap, datum, etc.) |
| `src/backend/utils/sort/logtape.c` | Logical tape I/O for external sort |
| `src/backend/utils/sort/tuplestore.c` | General-purpose tuple buffer |
| `src/include/utils/tuplesort.h` | `Tuplesortstate` and public API |
| `src/include/utils/tuplestore.h` | `Tuplestorestate` and public API |

---

## How It Works

### Sort Node

The Sort node operates in two phases:

```
Phase 1 (on first ExecProcNode call):
  Read ALL tuples from outer plan
  Pass each to tuplesort_puttupleslot()
  Call tuplesort_performsort()

Phase 2 (on subsequent calls):
  Call tuplesort_gettupleslot() to return sorted tuples one at a time
```

```c
static TupleTableSlot *
ExecSort(PlanState *pstate)
{
    SortState *node = castNode(SortState, pstate);

    if (!node->sort_Done)
    {
        /* Phase 1: consume all input */
        tuplesortstate = tuplesort_begin_heap(..., work_mem, ...);

        for (;;)
        {
            slot = ExecProcNode(outerPlanState(node));
            if (TupIsNull(slot))
                break;
            tuplesort_puttupleslot(tuplesortstate, slot);
        }

        tuplesort_performsort(tuplesortstate);
        node->sort_Done = true;
    }

    /* Phase 2: return next sorted tuple */
    if (tuplesort_gettupleslot(tuplesortstate, forward, false, slot, NULL))
        return slot;
    return NULL;
}
```

**Datum sort optimization.** When the sort result has a single column,
PostgreSQL uses a Datum-only sort path which avoids tuple overhead and is
significantly faster for pass-by-value types.

### tuplesort: The Sorting Engine

`tuplesort.c` implements a sophisticated sorting engine that adapts to data
size:

```
                   Input tuples
                       |
              fits in work_mem?
              /               \
           yes                 no
            |                   |
    in-memory quicksort    external sort
    (or radix sort for     (multiple phases)
     pass-by-value types)
            |                   |
    single sorted array    sorted runs on "tapes"
            |                   |
            +--------+----------+
                     |
              tuplesort_gettupleslot()
              returns tuples in order
```

#### In-Memory Sort

When all tuples fit within `work_mem`:

1. Tuples accumulate in a growable array (`memtuples`)
2. On `performsort`, quicksort (or radix sort) is applied
3. Tuples are returned by scanning the sorted array

PostgreSQL uses a comparison-based `qsort_ssup` (with SortSupport for
type-specific optimizations like abbreviated keys) or a radix sort for
integer/float types.

**Abbreviated keys.** The SortSupport mechanism can compute a fixed-size
"abbreviated" representation of the first sort key that fits in a Datum. This
allows most comparisons to be resolved without touching the full tuple,
dramatically improving cache locality:

```c
typedef struct SortSupportData {
    Oid             ssup_ctype;
    bool            ssup_nulls_first;
    /* Abbreviated key support */
    Datum         (*abbrev_converter)(Datum original, SortSupport ssup);
    int           (*abbrev_comparator)(Datum a, Datum b, SortSupport ssup);
    bool          (*abbrev_abort)(int memtupcount, SortSupport ssup);
    /* Full key comparator */
    int           (*comparator)(Datum a, Datum b, SortSupport ssup);
    ...
} SortSupportData;
```

#### External Sort

When tuples exceed `work_mem`:

1. **Run generation.** Fill memory with tuples, quicksort them, write the
   sorted run to a logical tape. Repeat until all input is consumed.
2. **Merge.** Perform a balanced k-way merge of all runs.

```
Run generation:
  Fill memory --> sort --> write to tape 0
  Fill memory --> sort --> write to tape 1
  Fill memory --> sort --> write to tape 2
  ...

k-way merge:
  Tape 0: [1, 5, 9, ...]
  Tape 1: [2, 4, 8, ...]     --> merge heap --> output tape
  Tape 2: [3, 6, 7, ...]

  If runs > tapes: multi-pass merge
  Pass 1: merge runs into fewer, longer runs
  Pass 2: merge again until single output
```

The number of tapes is determined by `work_mem / TAPE_BUFFER_OVERHEAD`, ensuring
each tape has enough read-ahead buffer to maintain sequential I/O. Since
PostgreSQL 15, a balanced merge is used instead of the older polyphase merge.

### logtape: Logical Tape I/O

The `logtape` module provides an abstraction of multiple sequential-access
"tapes" backed by a single temporary file. It handles:

- **Block recycling.** As soon as a block is read from a tape, its disk space
  can be reused by another tape, minimizing temp file size.
- **Read-ahead buffering.** Each tape pre-reads `work_mem / num_tapes` bytes
  to maintain sequential access patterns.
- **Freeze.** A tape can be "frozen" to allow random access (needed when the
  caller requests sorted output with mark/restore capability).

```c
/* Logical tape abstraction */
typedef struct LogicalTapeSet {
    BufFile    *pfile;          /* underlying temp file */
    int         nBlocksWritten;
    /* Free block tracking */
    long       *freeBlocks;
    int         nFreeBlocks;
    ...
} LogicalTapeSet;

typedef struct LogicalTape {
    LogicalTapeSet *tapeSet;
    bool            writing;    /* currently writing or reading? */
    bool            frozen;     /* frozen for random access? */
    long            firstBlockNumber;
    /* Read buffer */
    char           *buffer;
    int             buffer_size;
    int             pos;        /* position in buffer */
    int             nbytes;     /* valid bytes in buffer */
    ...
} LogicalTape;
```

### IncrementalSort

When input is already sorted by a prefix of the required sort keys,
IncrementalSort avoids sorting the entire dataset. It groups consecutive tuples
that share the same presorted key prefix and sorts only within each group:

```
Required sort: (a, b, c)
Input sorted by: (a)

Group 1 (a=1): sort by (b, c)  --> emit sorted group
Group 2 (a=2): sort by (b, c)  --> emit sorted group
Group 3 (a=3): sort by (b, c)  --> emit sorted group
```

This is particularly effective with LIMIT queries, where only the first few
groups may need to be sorted before enough result tuples are produced.

### Material Node

Buffers all input tuples in a `Tuplestorestate` for repeated access:

```c
static TupleTableSlot *
ExecMaterial(PlanState *pstate)
{
    MaterialState *node = castNode(MaterialState, pstate);

    if (!node->eof_underlying)
    {
        /* Still reading from child */
        slot = ExecProcNode(outerPlanState(node));
        if (!TupIsNull(slot))
        {
            tuplestore_puttupleslot(node->tuplestorestate, slot);
            return slot;
        }
        node->eof_underlying = true;
    }

    /* Reading from materialized store */
    if (tuplestore_gettupleslot(node->tuplestorestate, forward, false, slot))
        return slot;
    return NULL;
}
```

The `tuplestore` starts in memory and transparently spills to a temp file when
it exceeds `work_mem`. It supports multiple read pointers for concurrent
access (used by window functions and CTEs).

### Memoize Node

Caches results of parameterized subplans using a hash table with LRU eviction:

```
ExecMemoize:
  |
  +-- hash(current_parameters)
  |
  +-- cache lookup
  |     |
  |     +-- HIT: return cached tuples one at a time
  |     |
  |     +-- MISS:
  |           +-- evict LRU entry if cache full
  |           +-- execute subplan, cache results
  |           +-- return first tuple
  |
  +-- on rescan: try cache again with new parameters
```

The cache uses a doubly-linked list for LRU tracking. Accessed entries are moved
to the tail; eviction removes from the head. The `singlerow` optimization
marks cache entries as complete after one tuple, enabling early exit for
unique joins.

```
State machine:
  MEMO_CACHE_LOOKUP          -- try cache
  MEMO_CACHE_FETCH_NEXT_TUPLE -- return next cached tuple
  MEMO_FILLING_CACHE         -- populating from subplan
  MEMO_CACHE_BYPASS_MODE     -- entry too large, pass through
  MEMO_END                   -- done
```

---

## Key Data Structures

### Tuplesortstate

```c
typedef struct Tuplesortstate {
    TupSortStatus   status;             /* INITIAL, BOUNDED, BUILDRUNS, ... */
    bool            bounded;            /* using top-N heapsort? */
    int64           bound;              /* N for top-N */
    int64           availMem;           /* remaining memory budget */
    int64           allowedMem;         /* total work_mem */

    /* In-memory sort */
    SortTuple      *memtuples;          /* array of tuples */
    int             memtupcount;
    int             memtupsize;         /* allocated array length */

    /* External sort */
    LogicalTapeSet *tapeset;
    int             maxTapes;
    int             nRuns;              /* number of sorted runs */
    SortTuple      *mergetuples;        /* merge heap */
    ...
} Tuplesortstate;
```

### SortState

```c
typedef struct SortState {
    ScanState       ss;
    bool            sort_Done;          /* sort complete? */
    bool            bounded;            /* using top-N? */
    int64           bound;              /* LIMIT value */
    void           *tuplesortstate;     /* opaque Tuplesortstate */
    ...
} SortState;
```

---

## Diagram: tuplesort State Machine

```
                   INITIAL
                     |
          +----------+----------+
          |                     |
    fits in memory?        exceeds work_mem
          |                     |
    SORTEDINMEM            BUILDRUNS
    (qsort/radix)              |
          |              write sorted runs
          |              to logical tapes
          |                     |
          |               MERGING
          |              (k-way merge)
          |                     |
          +----------+----------+
                     |
              SORTEDONTAPE or
              SORTEDINMEM
                     |
            tuplesort_gettupleslot()
```

### Top-N Heapsort

When a Sort node sits below a Limit node, it uses a **bounded heap** to keep
only the top N tuples in memory. This avoids sorting the entire input:

```
ExecSetTupleBound(n, sortNode)
  --> tuplesort enters BOUNDED mode
  --> maintains a max-heap of size N
  --> each new tuple: if smaller than heap max, replace and sift down
  --> after all input: extract heap in sorted order
```

This reduces memory from O(input) to O(N) and time from O(N log N) to
O(input * log N).

---

## Connections

| Topic | Link |
|---|---|
| Executor overview | [Query Executor](index) |
| Volcano model and pipeline breakers | [Volcano Model](volcano-model) |
| Merge join requiring sorted input | [Join Nodes](join-nodes) |
| Sorted aggregation | [Aggregation](aggregation) |
| Parallel sort via Gather Merge | [Parallel Query](parallel-query) |
| work_mem and memory accounting | [Memory Management](../10-memory/) |
| Temp file I/O | [Storage Engine](../01-storage/) |
