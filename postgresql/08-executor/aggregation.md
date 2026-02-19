---
title: "Aggregation"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "08-executor"
chapter_title: "Executor"
chapter_url: "/postgresql/08-executor/"
---

# Aggregation and Window Functions

## Summary

PostgreSQL supports two primary aggregation strategies -- **hash aggregation**
and **sorted (group) aggregation** -- plus **grouping sets** (ROLLUP, CUBE)
and **window functions**. The `Agg` node handles standard aggregation with a
uniform transition-function pipeline: for each input tuple, call the transition
function to update the aggregate state; after the last tuple in a group, call
the optional final function to produce the result. The `WindowAgg` node extends
this model to compute window functions over partitions with frame-based access
to surrounding rows.

---

## Overview

### Aggregate Execution Model

Every aggregate follows the same three-step lifecycle:

```
transvalue = initcond
foreach input_tuple:
    transvalue = transfunc(transvalue, input_value(s))
result = finalfunc(transvalue)
```

If no `finalfunc` is defined, the final `transvalue` is the result. For
partial aggregation (parallel queries), the pipeline extends with
`combinefunc`, `serializefunc`, and `deserializefunc`.

### Aggregation Strategies

| Strategy | `AggStrategy` | When Used | Memory |
|---|---|---|---|
| **Plain** | `AGG_PLAIN` | No GROUP BY (single group) | Minimal |
| **Sorted** | `AGG_SORTED` | Input pre-sorted on GROUP BY keys | Minimal |
| **Hashed** | `AGG_HASHED` | Unsorted input, fits in `work_mem` | O(groups) |
| **Mixed** | `AGG_MIXED` | Grouping sets with both sorted and hashed phases | Varies |

---

## Key Source Files

| File | Purpose |
|---|---|
| `src/backend/executor/nodeAgg.c` | Main aggregation node (~3000 lines) |
| `src/backend/executor/nodeWindowAgg.c` | Window function execution |
| `src/backend/executor/nodeGroup.c` | Simple GROUP BY without aggregates |
| `src/backend/executor/execGrouping.c` | Group key comparison utilities |
| `src/include/nodes/execnodes.h` | `AggState`, `WindowAggState` structs |

---

## How It Works

### Hash Aggregation

For each input tuple, compute the hash of the GROUP BY keys and look up (or
create) the corresponding entry in a hash table. Each entry holds the
transition values for all aggregates in that group.

```
ExecAgg (AGG_HASHED)
  |
  +-- Phase 1: Build hash table
  |     loop:
  |       slot = ExecProcNode(outer)
  |       if NULL, move to phase 2
  |       hash = hash_group_keys(slot)
  |       entry = lookup_or_create(hashtable, hash, group_keys)
  |       advance_aggregates(entry, slot)   /* call transfunc */
  |
  +-- Phase 2: Iterate hash table, emit results
        for each entry in hashtable:
          finalize_aggregates(entry)         /* call finalfunc */
          project and return result tuple
```

The hash table uses the `TupleHashTable` abstraction:

```c
typedef struct TupleHashTableData {
    tuplehash_hash *hashtab;    /* simplehash hash table */
    int             numCols;    /* number of GROUP BY columns */
    AttrNumber     *keyColIdx;  /* column numbers of group keys */
    Oid            *eqfuncoids; /* equality function OIDs */
    ...
} TupleHashTableData;
```

**Memory management.** Each grouping set gets its own `aggcontext` (an
`ExprContext`). When a group boundary is hit in sorted mode, the context is
rescanned (not just reset) so that transition functions can register shutdown
callbacks via `AggRegisterCallback`.

**Spilling to disk.** As of PostgreSQL 15+, hash aggregation can spill
partitions to disk when `work_mem` is exceeded, similar to hash join batching.
This prevents out-of-memory failures on high-cardinality GROUP BY.

### Sorted Aggregation

Requires input pre-sorted on the GROUP BY keys. Detects group boundaries by
comparing the current tuple's keys to the previous tuple's keys:

```
ExecAgg (AGG_SORTED)
  |
  loop:
    slot = ExecProcNode(outer)
    if NULL or group_keys_changed:
      finalize current group
      emit result tuple
      reset transition values for new group
    advance_aggregates(current_group, slot)
```

This has minimal memory overhead (only the current group's transition states)
and works well when the planner can leverage an existing sort order.

### Grouping Sets, ROLLUP, and CUBE

Grouping sets allow multiple levels of aggregation in a single pass. For
example:

```sql
SELECT department, region, SUM(sales)
FROM orders
GROUP BY ROLLUP (department, region);
-- Produces groups: (dept, region), (dept), ()
```

PostgreSQL handles this using a **chained aggregation** approach:

1. Input is sorted by the finest grouping set (department, region)
2. Multiple sets of transition values are maintained concurrently
3. When a group boundary occurs for a finer grouping set, the coarser sets
   continue accumulating while the finer set finalizes

```
Input sorted by (department, region):

  (Sales, East, 100) --> update groups: (Sales,East), (Sales), ()
  (Sales, East, 200) --> update groups: (Sales,East), (Sales), ()
  (Sales, West, 150) --> boundary! finalize (Sales,East)
                         update groups: (Sales,West), (Sales), ()
  (Eng, East, 300)   --> boundary! finalize (Sales,West), (Sales)
                         update groups: (Eng,East), (Eng), ()
  EOF                 --> finalize (Eng,East), (Eng), ()
```

For non-ROLLUP grouping sets that cannot share a sort order, the planner emits
multiple `Agg` nodes (one per required sort order) combined with `Append`.

### Partial Aggregation (Parallel Queries)

In parallel aggregation, work is split into partial and final phases:

```
Gather
  |
  Finalize Aggregate (combinefunc)
    |
  Partial Aggregate (transfunc, skip finalfunc)
    |
  [parallel worker scans]
```

Each worker runs the transition functions on its partition of the data and
outputs serialized partial results. The leader's `Finalize Aggregate` node
deserializes these and combines them using the `combinefunc`.

The `aggsplit` flag controls this:

| Split | transfunc/combinefunc | finalfunc | serialize/deserialize |
|---|---|---|---|
| `AGGSPLIT_SIMPLE` | transfunc | yes | no |
| `AGGSPLIT_INITIAL_SERIAL` | transfunc | skip | serialize output |
| `AGGSPLIT_FINAL_DESERIAL` | combinefunc | yes | deserialize input |

### Window Functions (WindowAgg)

Window functions compute results across a "window" of related rows without
collapsing them into groups. The `WindowAgg` node:

1. Accumulates all tuples of the current partition into a **tuplestore**
2. For each row, evaluates window functions using the `WindowObject` API
3. Returns each input row augmented with window function results

```
WindowAgg
  |
  +-- buffer partition into tuplestore
  |
  +-- for each row in partition:
  |     set frame boundaries (ROWS/RANGE/GROUPS)
  |     for each window function:
  |       compute result over frame
  |     project: original columns + window results
  |     return tuple
  |
  +-- on partition boundary: reset and start new partition
```

The `WindowObject` API provides functions like:
- `WinGetFuncArgInPartition()` -- access argument values at arbitrary positions
- `WinGetFuncArgInFrame()` -- access within the current frame
- `WinSetMarkPosition()` / `WinGetCurrentPosition()` -- navigation

**Frame types:**

| Type | Boundary | Description |
|---|---|---|
| `ROWS` | Physical row offset | Fixed number of rows before/after |
| `RANGE` | Value range | Rows within a value distance |
| `GROUPS` | Peer groups | Groups of rows with equal ORDER BY values |

**Optimization for running aggregates:** For `ROWS BETWEEN UNBOUNDED PRECEDING
AND CURRENT ROW`, PostgreSQL maintains a running transition value rather than
re-scanning the entire frame for each row. It also supports inverse transition
functions for sliding frames (e.g., subtracting a row leaving the frame).

```c
typedef struct WindowObjectData {
    NodeTag         type;
    WindowAggState *winstate;       /* parent state */
    List           *argstates;      /* argument expressions */
    void           *localmem;       /* per-partition local memory */
    int             markptr;        /* tuplestore mark pointer */
    int             readptr;        /* tuplestore read pointer */
    int64           markpos;        /* row that markptr is on */
    int64           seekpos;        /* row that readptr is on */
    ...
} WindowObjectData;
```

---

## Key Data Structures

### AggState

```c
typedef struct AggState {
    ScanState       ss;
    List           *aggs;               /* list of Aggref nodes */
    int             numaggs;            /* number of aggregates */
    int             numtrans;           /* number of transition states */
    AggStrategy     aggstrategy;        /* PLAIN, SORTED, HASHED, MIXED */
    AggSplit        aggsplit;           /* SIMPLE, INITIAL, FINAL */
    AggStatePerAgg  peragg;             /* per-aggregate info */
    AggStatePerTrans pertrans;          /* per-transition info */
    ExprContext    *tmpcontext;          /* short-lived for transfunc calls */
    ExprContext   **aggcontexts;        /* per-grouping-set contexts */
    TupleHashTable *hashtable;          /* for AGG_HASHED */
    bool            table_filled;       /* hash table complete? */
    int             current_set;        /* current grouping set */
    int             numphases;          /* number of sort phases */
    ...
} AggState;
```

### AggStatePerTransData (per transition state)

```c
typedef struct AggStatePerTransData {
    Aggref         *aggref;
    FmgrInfo        transfn;            /* transition function */
    FmgrInfo        serialfn;           /* serialization function */
    FmgrInfo        deserialfn;         /* deserialization function */
    Datum           initValue;          /* initial transition value */
    bool            initValueIsNull;
    bool            transfn_strict;     /* is transfunc strict? */
    Datum           transValue;         /* current transition value */
    bool            transValueIsNull;
    ...
} AggStatePerTransData;
```

---

## Diagram: Aggregation Pipeline

```
                  Input Tuples
                       |
            +----------+----------+
            |                     |
      AGG_SORTED              AGG_HASHED
            |                     |
    sorted by group key    hash(group_key)
            |                     |
    detect boundary        lookup/create entry
            |                     |
    transfunc(state, val)  transfunc(state, val)
            |                     |
    on boundary:           after all input:
    finalfunc(state)       iterate hash table
            |               finalfunc(state)
            |                     |
            +----------+----------+
                       |
                 Result Tuples
```

### Partial Aggregation Pipeline

```
  Worker 0          Worker 1          Worker 2
     |                  |                 |
  Partial Agg       Partial Agg      Partial Agg
  (transfunc)       (transfunc)      (transfunc)
  (serialize)       (serialize)      (serialize)
     |                  |                 |
     +--------+---------+---------+-------+
              |                   |
           Gather             (tuple queue)
              |
        Finalize Agg
        (deserialize)
        (combinefunc)
        (finalfunc)
              |
         Result Tuples
```

---

## Connections

| Topic | Link |
|---|---|
| Executor overview | [Query Executor](index) |
| Sorted input via Sort nodes | [Sort and Materialize](sort-and-materialize) |
| Parallel partial aggregation | [Parallel Query](parallel-query) |
| Expression evaluation in transfuncs | [Expression Evaluation](expression-eval) |
| Planner aggregate strategy selection | [Query Optimizer](../07-query-optimizer/) |
| Memory contexts for aggregate state | [Memory Management](../10-memory/) |
| Statistics for group cardinality estimates | [Statistics](../13-statistics/) |
