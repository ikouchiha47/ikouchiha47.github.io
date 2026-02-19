---
title: "Plan Creation"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "07-query-optimizer"
chapter_title: "Query Optimizer"
chapter_url: "/postgresql/07-query-optimizer/"
---

# Plan Creation

After the optimizer has found the cheapest Path tree, it must convert it into a `Plan` tree that the executor can run. This is a mostly mechanical translation, but with important post-processing: target-list construction, qual ordering for security, and -- critically -- fixing up all Var references so that each plan node references the output columns of its child nodes rather than the original range table. These steps are handled by `createplan.c` and `setrefs.c`.

---

## Summary

Plan creation has two phases:

1. **Path-to-Plan conversion** (`createplan.c`): recursively walk the Path tree, creating the corresponding Plan nodes. Each Path type maps to a Plan node type (SeqScan, IndexScan, NestLoop, HashJoin, Sort, etc.). The translation fills in executor-specific details that Paths omit: target lists, qual expression trees, plan node parameters.

2. **Reference fixing** (`setrefs.c`): a final pass over the complete Plan tree that replaces table-level Var references with INNER_VAR / OUTER_VAR references to child plan node output columns, resolves regproc OIDs for operators, and performs other executor-oriented cleanups.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/optimizer/plan/createplan.c` | `create_plan()`, `create_plan_recurse()`, and all per-node-type creators |
| `src/backend/optimizer/plan/setrefs.c` | `set_plan_references()`, Var fixup, subplan linking |
| `src/backend/optimizer/plan/planner.c` | `subquery_planner()` calls `create_plan()` then `set_plan_references()` |
| `src/include/nodes/plannodes.h` | Plan, SeqScan, IndexScan, NestLoop, HashJoin, etc. |
| `src/include/nodes/pathnodes.h` | Path types that are converted |

---

## How It Works

### Phase 1: create_plan()

The entry point is `create_plan()` in `createplan.c`, which calls `create_plan_recurse()`:

```c
Plan *
create_plan(PlannerInfo *root, Path *best_path)
{
    Plan *plan;

    plan = create_plan_recurse(root, best_path, CP_EXACT_TLIST);

    /* Post-creation adjustments */
    ...

    return plan;
}
```

`create_plan_recurse()` dispatches on the Path node type:

```
create_plan_recurse(root, path, flags):
  switch path->pathtype:

    T_SeqScan:       create_seqscan_plan()
    T_IndexScan:     create_indexscan_plan()
    T_IndexOnlyScan: create_indexonlyscan_plan()
    T_BitmapHeapScan: create_bitmap_subplan()
    T_TidScan:       create_tidscan_plan()
    T_SubqueryScan:  create_subqueryscan_plan()
    T_FunctionScan:  create_functionscan_plan()

    T_NestLoop:      create_nestloop_plan()
    T_MergeJoin:     create_mergejoin_plan()
    T_HashJoin:      create_hashjoin_plan()

    T_Material:      create_material_plan()
    T_Memoize:       create_memoize_plan()
    T_Sort:          create_sort_plan()
    T_IncrementalSort: create_incrementalsort_plan()
    T_Group:         create_group_plan()
    T_Agg:           create_agg_plan()
    T_WindowAgg:     create_windowagg_plan()
    T_Unique:        create_unique_plan()
    T_Gather:        create_gather_plan()
    T_GatherMerge:   create_gather_merge_plan()
    T_SetOp:         create_setop_plan()
    T_LockRows:      create_lockrows_plan()
    T_ModifyTable:   create_modifytable_plan()
    T_Limit:         create_limit_plan()
    T_Result:        create_result_plan()
    T_Append:        create_append_plan()
    T_MergeAppend:   create_merge_append_plan()
    T_RecursiveUnion: create_recursiveunion_plan()
```

#### Target List Construction

Each plan node needs a target list (`plan->targetlist`) specifying which columns it outputs. The function `build_path_tlist()` creates this from the Path's `pathtarget`:

```c
static List *
build_path_tlist(PlannerInfo *root, Path *path)
{
    /* Convert each expression in path->pathtarget->exprs
     * into a TargetEntry */
}
```

For scan nodes, `use_physical_tlist()` checks whether we can use a "physical" tlist that simply returns all columns of the table (avoiding projection overhead). This is possible when no expressions need to be computed and when the node does not need to match a specific column layout.

#### Qual Ordering

`order_qual_clauses()` sorts the qual list for each plan node. The ordering respects:
1. **Security levels** -- barrier quals (from RLS or security-barrier views) must be evaluated before leaky quals.
2. **Cost** -- cheaper quals are evaluated first (to short-circuit expensive ones via AND semantics).
3. **Stability** -- when security levels and costs are equal, the original order is preserved.

#### Join Plan Creation

For join nodes, the creator functions do the following:

**create_nestloop_plan():**
- Recursively create plans for outer and inner paths.
- Separate join quals into join clauses and filter clauses.
- For parameterized inner paths, convert join clauses into index conditions (they were already matched during path generation).

**create_hashjoin_plan():**
- Create a Hash node wrapping the inner plan.
- Extract hash join clauses from the RestrictInfo list.
- The Hash node's startup cost represents building the hash table.

**create_mergejoin_plan():**
- If the input paths are not already sorted on the merge keys, insert Sort nodes.
- Extract merge join clauses and their sort operators.
- Set up mark/restore positions for handling non-unique merge keys.

### Phase 2: set_plan_references() (setrefs.c)

After the Plan tree is built, `set_plan_references()` performs a critical transformation: it converts all Var nodes from table-level references to execution-level references.

#### The Problem

During planning, a Var node like `{varno=2, varattno=3}` means "column 3 of range-table entry 2." But the executor doesn't scan range-table entries directly -- it receives tuples from child plan nodes. A join node's inner child outputs some columns, its outer child outputs others, and the join node must know which of its children provides each column.

#### The Solution

`set_plan_references()` walks the Plan tree bottom-up. For each plan node, it:

1. **Builds an indexed target list** for each child plan node, mapping `(varno, varattno)` pairs to output column positions.

2. **Replaces Vars in quals and target lists** using this mapping:
   - In a join node: Vars from the outer child become `OUTER_VAR` references (varno = 65001). Vars from the inner child become `INNER_VAR` references (varno = 65000).
   - In a scan node: Vars reference the scan's range-table entry directly (no change needed).
   - In an upper node (Sort, Agg, etc.): Vars reference the child's output columns.

3. **Resolves operator OIDs.** During planning, operators may be referenced by name or opclass. `setrefs.c` ensures all `OpExpr` nodes have concrete `opfuncid` values (regproc OIDs) for the executor.

4. **Flattens subplan references.** SubPlan nodes in the Plan tree are linked to their actual plan trees, and parameter mappings are finalized.

```
Before setrefs:
  HashJoin
    qual: Var(t1.x) = Var(t2.y)      -- table-level references
    ->  SeqScan on t1
          targetlist: Var(t1.x), Var(t1.z)
    ->  SeqScan on t2
          targetlist: Var(t2.y), Var(t2.w)

After setrefs:
  HashJoin
    qual: Var(OUTER_VAR, 1) = Var(INNER_VAR, 1)  -- positional references
    ->  SeqScan on t1
          targetlist: Var(1, 1), Var(1, 3)        -- (rtindex, attnum)
    ->  SeqScan on t2
          targetlist: Var(2, 2), Var(2, 4)
```

---

## Key Data Structures

### Plan (base type)

```c
typedef struct Plan
{
    NodeTag     type;
    Cost        startup_cost;   /* cost before first tuple */
    Cost        total_cost;     /* total cost */
    double      plan_rows;      /* estimated output rows */
    int         plan_width;     /* estimated average row width */
    bool        parallel_aware;
    bool        parallel_safe;
    int         plan_node_id;   /* unique ID within PlannedStmt */
    List       *targetlist;     /* target list of TargetEntry nodes */
    List       *qual;           /* filter conditions (implicit AND) */
    Plan       *lefttree;       /* outer (left) input plan */
    Plan       *righttree;      /* inner (right) input plan */
    List       *initPlan;       /* init SubPlan nodes */
    Bitmapset  *extParam;       /* external PARAM_EXEC parameters needed */
    Bitmapset  *allParam;       /* all PARAM_EXEC parameters */
} Plan;
```

### PlannedStmt

The top-level output of the planner:

```c
typedef struct PlannedStmt
{
    NodeTag     type;
    CmdType     commandType;    /* SELECT, INSERT, UPDATE, DELETE */
    bool        hasReturning;
    bool        hasModifyingCTE;
    bool        canSetTag;
    bool        transientPlan;  /* should plan be cached? */
    bool        dependsOnRole;
    bool        parallelModeNeeded;
    int         jitFlags;       /* JIT compilation flags */
    Plan       *planTree;       /* the actual plan tree */
    List       *rtable;         /* range table */
    List       *permInfos;      /* permission check info */
    List       *resultRelations;
    List       *appendRelations;
    List       *subplans;       /* list of SubPlan plan trees */
    Bitmapset  *rewindPlanIDs;  /* plans needing rewind capability */
    List       *rowMarks;       /* FOR UPDATE/SHARE info */
    List       *relationOids;   /* OIDs of relations referenced */
    List       *invalItems;     /* plan cache invalidation triggers */
    int         nParamExec;     /* number of PARAM_EXEC parameters */
} PlannedStmt;
```

### Path-to-Plan Type Mapping

| Path Type | Plan Type |
|-----------|-----------|
| `Path` (T_SeqScan) | `SeqScan` |
| `IndexPath` | `IndexScan` or `IndexOnlyScan` |
| `BitmapHeapPath` | `BitmapHeapScan` + `BitmapIndexScan`/`BitmapAnd`/`BitmapOr` |
| `NestPath` | `NestLoop` |
| `MergePath` | `MergeJoin` (+ `Sort` nodes if needed) |
| `HashPath` | `HashJoin` + `Hash` |
| `SortPath` | `Sort` |
| `AggPath` | `Agg` |
| `GroupPath` | `Group` |
| `WindowAggPath` | `WindowAgg` |
| `LimitPath` | `Limit` |
| `MaterialPath` | `Material` |
| `MemoizePath` | `Memoize` |
| `GatherPath` | `Gather` |
| `GatherMergePath` | `GatherMerge` |
| `AppendPath` | `Append` |
| `ModifyTablePath` | `ModifyTable` |

---

## Diagram: Path-to-Plan Conversion

```
Path Tree (optimizer output)          Plan Tree (executor input)
================================      ================================

HashPath                              HashJoin
  pathtype: T_HashJoin                  jointype: JOIN_INNER
  total_cost: 192.75                    hash_qual: t2.y = t1.x
  pathkeys: NIL                         ┌───────────┴───────────┐
  ┌────────┴────────┐                   v                       v
  v                 v                 SeqScan on t2          Hash
Path(T_SeqScan)  Path(T_SeqScan)       targetlist:           ┌──┘
  parent: t2       parent: t1           [t2.y, t2.w]         v
                                                           SeqScan on t1
                                                             targetlist:
                                                             [t1.x, t1.z]
                                                             qual: t1.z > 100

After setrefs:

HashJoin
  hash_qual: OUTER_VAR.1 = INNER_VAR.1
  ┌───────────┴───────────┐
  v                       v
SeqScan on t2          Hash
  tlist: [col2, col4]     |
                        SeqScan on t1
                          tlist: [col1, col3]
                          qual: col3 > 100
```

---

## Special Cases

### Projection Nodes

If a plan node needs to compute expressions (not just pass through columns), and its child node cannot do the projection, a `Result` node is inserted as a projection step. The `CP_EXACT_TLIST` flag in `create_plan_recurse()` controls when this is necessary.

### Gating Conditions

If a qual can be determined false at plan creation time (e.g., contradictory EquivalenceClass constants), a `Result` node with a `One-Time Filter: false` is inserted. This short-circuits execution immediately, returning no rows.

### SubPlan Linking

`set_plan_references()` finalizes the connection between SubPlan nodes in the main plan and their plan trees in `PlannedStmt.subplans`. Each SubPlan references its plan by index into the subplans list.

### Parallel Plan Finalization

For parallel plans, `create_gather_plan()` or `create_gather_merge_plan()` wraps the partial plan. The Gather node specifies `num_workers` and whether the leader participates. `set_plan_references()` ensures that parallel-safe expressions are used throughout.

---

## The Complete Pipeline

```
subquery_planner()
  │
  ├── preprocessing (prepjointree, prepqual, etc.)
  ├── grouping_planner()
  │     ├── query_planner()
  │     │     └── make_one_rel() -> best Path tree
  │     └── handle upper-level processing (agg, sort, limit)
  │           └── final best Path
  │
  ├── create_plan(best_path)              <-- THIS SECTION
  │     └── create_plan_recurse()
  │           ├── create_seqscan_plan()
  │           ├── create_hashjoin_plan()
  │           │     ├── recurse for outer
  │           │     └── recurse for inner (wrapped in Hash)
  │           └── ... other plan types ...
  │
  └── set_plan_references(plan)           <-- THIS SECTION
        ├── fix Var references (OUTER_VAR, INNER_VAR)
        ├── resolve operator OIDs
        ├── link SubPlan references
        └── return PlannedStmt
              │
              v
          Executor
```

---

## Connections

| Subsystem | Relationship |
|-----------|-------------|
| [Path Generation](path-generation) | Produces the Path tree that plan creation converts |
| [Join Ordering](join-ordering) | Determines which Path tree wins (cheapest at top level) |
| [Cost Model](cost-model) | Plan nodes carry the cost estimates from their source Paths |
| [Executor](../08-executor/) | Consumes the Plan tree; each Plan node type has a corresponding executor node |
| [Caches](../09-caches/) | The finished PlannedStmt may be stored in the plan cache for reuse |
| [Preprocessing](preprocessing) | SubPlan nodes originate from sublinks that could not be pulled up |
