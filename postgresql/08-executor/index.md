---
title: "Executor"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "08-executor"
chapter_title: "Executor"
is_chapter_index: true
---

# Chapter 8: Query Executor

## Summary

The query executor is the runtime engine of PostgreSQL. It receives a plan tree
from the optimizer and produces result tuples by recursively pulling data through
a pipeline of interconnected plan nodes. Every SQL statement -- whether a simple
`SELECT`, an `INSERT ... SELECT`, or a complex analytical query with window
functions -- ultimately runs through the same executor framework.

---

## Overview

After the planner builds an optimal `PlannedStmt`, the executor takes over.
Execution proceeds in four phases, each exposed through a hook-able interface:

| Phase | Entry Point | Purpose |
|---|---|---|
| **Start** | `ExecutorStart()` | Build the `PlanState` tree, open relations, allocate memory |
| **Run** | `ExecutorRun()` | Pull tuples through the plan tree via `ExecutePlan()` |
| **Finish** | `ExecutorFinish()` | Fire AFTER triggers, run post-processing |
| **End** | `ExecutorEnd()` | Close relations, free resources |

The heart of the executor is the **Volcano iterator model**: every plan node
exposes an `ExecProcNode` function pointer that, when called, returns the next
tuple (or NULL to signal completion). The root node calls its children, which
call their children, forming a demand-driven data pipeline.

```
                  ExecutorRun
                      |
                 ExecutePlan
                      |
               ExecProcNode (root)
                /           \
         ExecProcNode     ExecProcNode
          (scan)           (join)
                           /     \
                    ExecProcNode  ExecProcNode
                     (scan)        (sort)
```

### Key Concepts

**Plan vs. PlanState.** The planner produces immutable `Plan` nodes. During
`ExecutorStart`, `ExecInitNode()` walks the plan tree and creates a parallel
tree of mutable `PlanState` nodes that carry runtime state -- open scan
descriptors, hash tables, sort states, expression evaluation machinery.

**TupleTableSlots.** Tuples flow between nodes as `TupleTableSlot` references.
Slots are a uniform abstraction over heap tuples, minimal tuples, and virtual
tuples (column arrays). This avoids copying data unnecessarily.

**Expression evaluation.** Qual filters, projection lists, and computed columns
are compiled into flat `ExprEvalStep` arrays during initialization and executed
via a fast interpreted dispatch loop (or JIT-compiled native code).

**Memory management.** Each node typically has a per-tuple `ExprContext` whose
memory is reset between tuples, plus query-lifespan memory for hash tables and
sort state. This two-tier approach keeps memory usage predictable.

---

## Key Source Files

| File | Purpose |
|---|---|
| `src/backend/executor/execMain.c` | Top-level executor interface: `ExecutorStart/Run/Finish/End` |
| `src/backend/executor/execProcnode.c` | `ExecInitNode()` / `ExecProcNode()` / `ExecEndNode()` dispatch |
| `src/backend/executor/execScan.c` | Generic scan loop shared by all scan nodes |
| `src/backend/executor/execExpr.c` | Expression "compilation" into `ExprEvalStep` arrays |
| `src/backend/executor/execExprInterp.c` | Interpreted expression evaluation (switch/computed-goto) |
| `src/backend/executor/execTuples.c` | `TupleTableSlot` management |
| `src/backend/executor/execUtils.c` | `EState` and `ExprContext` setup utilities |
| `src/backend/executor/execParallel.c` | Parallel query infrastructure |
| `src/include/nodes/execnodes.h` | All `PlanState` struct definitions |
| `src/include/nodes/plannodes.h` | All `Plan` struct definitions |

---

## Key Data Structures

### EState (Executor State)

The global execution state for a query, shared across all plan nodes:

```c
typedef struct EState {
    NodeTag         type;
    ScanDirection   es_direction;       /* forward or backward scan */
    Snapshot        es_snapshot;         /* visibility snapshot */
    Snapshot        es_crosscheck_snapshot;
    List           *es_range_table;     /* RT entries */
    Index           es_range_table_size;
    Relation       *es_relations;       /* opened relations array */
    ...
    PlannedStmt    *es_plannedstmt;     /* the plan being executed */
    ParamListInfo   es_param_list_info; /* external parameters */
    ParamExecData  *es_param_exec_vals; /* internal parameters */
    MemoryContext   es_query_cxt;       /* query-lifespan memory */
    List           *es_tupleTable;      /* TupleTableSlots */
    ...
} EState;
```

### PlanState (base for all node states)

```c
typedef struct PlanState {
    NodeTag         type;
    Plan           *plan;               /* associated Plan node */
    EState         *state;              /* link to per-query EState */
    ExecProcNodeMtd ExecProcNode;       /* function to get next tuple */
    ExecProcNodeMtd ExecProcNodeReal;   /* actual impl (ExecProcNode may wrap) */
    Instrumentation *instrument;        /* optional EXPLAIN ANALYZE stats */
    ExprState      *qual;               /* qual condition */
    struct PlanState *lefttree;         /* outer (left) input */
    struct PlanState *righttree;        /* inner (right) input */
    TupleTableSlot *ps_ResultTupleSlot; /* result slot */
    ExprContext    *ps_ExprContext;      /* expression eval context */
    ...
} PlanState;
```

---

## How It Works: End-to-End

### 1. ExecutorStart -- Building the Runtime Tree

```
ExecutorStart(queryDesc, eflags)
  --> InitPlan(queryDesc, eflags)
        --> ExecInitNode(plannedstmt->planTree, estate, eflags)
              --> switch (nodeTag(node))
                    T_SeqScan  --> ExecInitSeqScan()
                    T_HashJoin --> ExecInitHashJoin()
                    T_Sort     --> ExecInitSort()
                    ...
              --> recursively init children
              --> set result->ExecProcNode = ExecXxx
```

`ExecInitNode()` is a large switch statement in `execProcnode.c` that dispatches
to the appropriate `ExecInitXxx()` function for each of the ~40 node types. Each
init function:

1. Allocates its `XxxState` struct
2. Opens relations / indexes as needed
3. Initializes expressions via `ExecInitExpr()`
4. Recursively calls `ExecInitNode()` on child plans
5. Sets the `ExecProcNode` function pointer

### 2. ExecutorRun -- The Tuple Pipeline

```
ExecutorRun(queryDesc, direction, count, execute_once)
  --> ExecutePlan(...)
        loop:
          slot = ExecProcNode(planstate)     /* pull one tuple */
          if TupIsNull(slot) break
          dest->receiveSlot(slot, dest)      /* send to client */
          count--
```

The first call to `ExecProcNode()` goes through `ExecProcNodeFirst()`, which
sets up instrumentation if needed, then replaces itself with the real function
pointer for subsequent calls. This avoids a branch on every tuple.

### 3. ExecutorFinish and ExecutorEnd

`ExecutorFinish()` fires deferred triggers and calls `ExecPostprocessPlan()`.
`ExecutorEnd()` calls `ExecEndNode()` recursively, which closes scan descriptors,
destroys hash tables, and frees sort state.

---

## Executor Node Taxonomy

```
Plan Nodes (~40 types)
 |
 +-- Control Nodes
 |     Result, ProjectSet, ModifyTable, Append, MergeAppend,
 |     RecursiveUnion, BitmapAnd, BitmapOr
 |
 +-- Scan Nodes
 |     SeqScan, IndexScan, IndexOnlyScan, BitmapIndexScan,
 |     BitmapHeapScan, TidScan, TidRangeScan, SubqueryScan,
 |     FunctionScan, ValuesScan, TableFuncScan, CteScan,
 |     NamedTuplestoreScan, WorkTableScan, ForeignScan, CustomScan
 |
 +-- Join Nodes
 |     NestLoop, MergeJoin, HashJoin
 |
 +-- Materialization Nodes
 |     Material, Sort, IncrementalSort, Memoize, Group, Agg,
 |     WindowAgg, Unique, Gather, GatherMerge, SetOp, LockRows,
 |     Limit, Hash
 |
 +-- DML Nodes
       ModifyTable (INSERT/UPDATE/DELETE/MERGE)
```

---

## Diagram: Executor Lifecycle

```
  Client sends query
        |
        v
  Parse --> Analyze --> Rewrite --> Plan
                                     |
                                     v
                              PlannedStmt
                                     |
        +----------------------------+
        |                            |
        v                            v
  ExecutorStart()              QueryDesc created
        |                      (plan + snapshot +
        v                       dest receiver)
  ExecInitNode()
  (build PlanState tree)
        |
        v
  ExecutorRun()
        |
        v
  ExecutePlan() loop  <--------+
        |                      |
        v                      |
  ExecProcNode(root)           |
        |                      |
   tuple returned?  --yes-->  send to client
        |                      |
        no                     |
        |                      |
        v                      |
  ExecutorFinish()             |
  (after triggers)             |
        |
        v
  ExecutorEnd()
  (cleanup)
```

---

## Connections

| Topic | Link |
|---|---|
| How plans are produced | [Query Optimizer](../07-query-optimizer/) |
| Volcano iterator model details | [Volcano Model](volcano-model) |
| Scan node internals | [Scan Nodes](scan-nodes) |
| Join algorithms | [Join Nodes](join-nodes) |
| Aggregation and window functions | [Aggregation](aggregation) |
| Sorting and materialization | [Sort and Materialize](sort-and-materialize) |
| Parallel query execution | [Parallel Query](parallel-query) |
| Expression compilation and JIT | [Expression Evaluation](expression-eval) |
| Buffer and storage layer | [Storage Engine](../01-storage/) |
| Transaction visibility (snapshots) | [Transactions](../03-transactions/) |
| Memory allocation contexts | [Memory Management](../10-memory/) |
