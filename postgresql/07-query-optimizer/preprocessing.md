---
title: "Preprocessing"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "07-query-optimizer"
chapter_title: "Query Optimizer"
chapter_url: "/postgresql/07-query-optimizer/"
---

# Preprocessing

Before the optimizer can search for the best plan, it must simplify and normalize the `Query` tree. Preprocessing transforms the query into a form that is easier and more efficient to optimize. This phase handles subquery pullup, sublink conversion, WHERE-clause canonicalization, join-tree flattening, and constant folding.

---

## Summary

Preprocessing is the first thing `subquery_planner()` does after receiving a `Query` from the rewriter. The key transformations are:

1. **Sublink pullup** -- convert `EXISTS` and `ANY` sublinks into semi-joins or anti-joins.
2. **Subquery pullup** -- pull simple subqueries in `FROM` up into the parent query's join tree.
3. **Join tree flattening** -- merge nested `FROM` lists to give the optimizer maximum freedom in join ordering.
4. **Qual canonicalization** -- flatten nested AND/OR trees and detect duplicate OR branches.
5. **Constant folding** -- evaluate constant sub-expressions at plan time.
6. **Outer join reduction** -- remove outer joins that provably produce no null-extended rows.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/optimizer/plan/planner.c` | `subquery_planner()` orchestrates all preprocessing steps |
| `src/backend/optimizer/prep/prepjointree.c` | Subquery pullup, join-tree flattening, outer-join reduction |
| `src/backend/optimizer/prep/prepqual.c` | AND/OR flattening, duplicate-OR detection |
| `src/backend/optimizer/plan/subselect.c` | SubLink-to-join conversion |
| `src/backend/optimizer/util/clauses.c` | `eval_const_expressions()` -- constant folding |
| `src/backend/optimizer/prep/preptlist.c` | Target list preprocessing |
| `src/backend/optimizer/prep/prepagg.c` | Aggregate preprocessing |
| `src/backend/optimizer/prep/prepunion.c` | UNION/INTERSECT/EXCEPT handling |

---

## How It Works

### Preprocessing Order in subquery_planner()

The function `subquery_planner()` in `planner.c` calls the preprocessing steps in a carefully ordered sequence. The comments in `prepjointree.c` document the intended order:

```
preprocess_relation_rtes      -- expand inheritance, partition hierarchies
replace_empty_jointree        -- handle empty FROM by inserting a dummy RTE
pull_up_sublinks              -- convert EXISTS/ANY SubLinks to joins
preprocess_function_rtes      -- inline SQL functions in FROM
pull_up_subqueries            -- flatten simple subqueries into parent
flatten_simple_union_all      -- optimize UNION ALL as append
preprocess_expression         -- constant folding, function inlining
reduce_outer_joins            -- remove unnecessary outer joins
remove_useless_result_rtes    -- clean up trivial Result RTEs
```

### 1. SubLink Pullup (pull_up_sublinks)

A `SubLink` is the parser's representation of a subquery appearing in a WHERE or HAVING clause. The optimizer can sometimes convert these to joins, which is far more efficient because the join-ordering machinery can then consider all tables together.

**Before pullup:**
```sql
SELECT * FROM t1 WHERE EXISTS (SELECT 1 FROM t2 WHERE t2.x = t1.x)
```

The parser represents this as a sequential scan on `t1` with a SubPlan filter. For every row of `t1`, the executor would run the subquery.

**After pullup:**
```sql
SELECT * FROM t1 SEMI JOIN t2 ON (t2.x = t1.x)
```

Now the optimizer can choose hash semi-join, merge semi-join, or nestloop semi-join and can consider either table as outer or inner.

The conversion rules:

| SubLink Type | Conversion |
|-------------|-----------|
| `EXISTS_SUBLINK` | Semi-join (or anti-join if under NOT) |
| `ANY_SUBLINK` (= ANY) | Semi-join |
| `ALL_SUBLINK` | Anti-join (after negation) |
| Correlated scalar | Left as SubPlan (cannot be pulled up) |
| Uncorrelated scalar | Converted to `InitPlan` (evaluated once) |

The code is in `convert_EXISTS_sublink_to_join()` and `convert_ANY_sublink_to_join()` in `subselect.c`, called from `pull_up_sublinks()` in `prepjointree.c`.

### 2. Subquery Pullup (pull_up_subqueries)

A subquery in `FROM` (a `RangeTblEntry` of type `RTE_SUBQUERY`) is normally planned as a black box: the optimizer plans it independently, then treats its output as a single relation. This prevents the optimizer from considering join orders that interleave the subquery's tables with the outer query's tables.

`pull_up_subqueries()` detects simple subqueries that can be merged into the parent:

**Conditions for pullup:**
- No aggregation, GROUP BY, HAVING, DISTINCT, or window functions
- No set operations (UNION, INTERSECT, EXCEPT)
- No LIMIT or OFFSET
- Not a volatile function in FROM
- Not a FULL JOIN target that would change semantics
- `from_collapse_limit` not exceeded

**What happens during pullup:**
1. The subquery's range table entries are appended to the parent's range table.
2. The subquery's join tree is substituted into the parent's join tree in place of the `RTE_SUBQUERY` reference.
3. Var references to the subquery outputs are replaced with the underlying expressions.
4. PlaceHolderVars may be introduced when expressions from inside the subquery need to be nullable due to outer joins above.

```
Before:  SELECT * FROM t1, (SELECT a, b FROM t2 WHERE t2.c > 5) sub
                             WHERE t1.x = sub.a

After:   SELECT * FROM t1, t2
                             WHERE t1.x = t2.a AND t2.c > 5
```

### 3. Join Tree Flattening

After subquery pullup, the join tree may have nested `FromExpr` (FROM lists) or `JoinExpr` nodes. The optimizer flattens these to give maximum freedom for join reordering.

**Rules:**
- A `FromExpr` nested inside another `FromExpr` can be merged (their FROM-lists concatenated).
- Explicit `INNER JOIN` nodes can be flattened into the parent FROM-list (the ON clause becomes a WHERE clause).
- `LEFT JOIN`, `RIGHT JOIN` can sometimes be flattened (the ON clause is preserved in a `SpecialJoinInfo`).
- `FULL OUTER JOIN` is never flattened -- the optimizer cannot reorder it.

Flattening is controlled by `join_collapse_limit` (for explicit JOINs) and `from_collapse_limit` (for subquery FROM-lists). When either limit is exceeded, the optimizer preserves the syntactic join structure, constraining the search space but bounding planning time.

### 4. Qual Canonicalization (prepqual.c)

The function `canonicalize_qual()` normalizes the WHERE clause:

**AND/OR flattening:**
```
Before:  (A AND (B AND C)) OR (D AND E)
After:   (A AND B AND C) OR (D AND E)
```
The functions `pull_ands()` and `pull_ors()` recursively flatten nested AND/OR trees into flat N-argument lists.

**Duplicate OR detection:**
```
Before:  (A AND B) OR (A AND C) OR (A AND D)
After:   A AND (B OR C OR D)
```
The function `find_duplicate_ors()` identifies common factors across OR branches and factors them out. This is critical because it can turn a filter that could only be applied after a join into a restriction that can be pushed down to a single table scan.

### 5. Constant Folding (eval_const_expressions)

`eval_const_expressions()` in `clauses.c` walks the expression tree and:

- Evaluates `OpExpr` and `FuncExpr` nodes when all arguments are constants.
- Simplifies `CASE WHEN true THEN x ELSE y` to just `x`.
- Reduces `COALESCE(const, ...)` when the first argument is non-null.
- Applies boolean simplification (`TRUE AND x` becomes `x`, `FALSE OR x` becomes `x`).
- Inlines simple SQL functions (single SELECT body, immutable).
- Flattens nested AND/OR as a side effect.

### 6. Outer Join Reduction (reduce_outer_joins)

If a WHERE clause effectively filters out NULLs from the nullable side of a LEFT JOIN, the LEFT JOIN can be reduced to an INNER JOIN:

```sql
-- Before (LEFT JOIN):
SELECT * FROM t1 LEFT JOIN t2 ON t1.x = t2.y WHERE t2.z > 10

-- After (reduced to INNER JOIN):
SELECT * FROM t1 INNER JOIN t2 ON t1.x = t2.y WHERE t2.z > 10
```

The `WHERE t2.z > 10` is strict (rejects NULLs), so any null-extended rows from the LEFT JOIN would be filtered out anyway. Converting to an inner join gives the optimizer more freedom in join ordering.

---

## Key Data Structures

### FromExpr

Represents a FROM clause: a list of tables/joins plus a WHERE qualification.

```c
typedef struct FromExpr
{
    NodeTag     type;
    List       *fromlist;   /* List of join subtrees */
    Node       *quals;      /* WHERE conditions (implicit AND) */
} FromExpr;
```

### JoinExpr

Represents an explicit JOIN:

```c
typedef struct JoinExpr
{
    NodeTag     type;
    JoinType    jointype;   /* JOIN_INNER, JOIN_LEFT, JOIN_FULL, etc. */
    bool        isNatural;
    Node       *larg;       /* left subtree */
    Node       *rarg;       /* right subtree */
    List       *usingClause;
    Alias      *join_using_alias;
    Node       *quals;      /* ON clause */
    Alias      *alias;
    int         rtindex;    /* RT index assigned to this join */
} JoinExpr;
```

### SpecialJoinInfo

Created for each outer, semi, or anti join. Survives join-tree flattening to constrain legal join orders:

```c
typedef struct SpecialJoinInfo
{
    NodeTag     type;
    Relids      min_lefthand;   /* minimum relids on LHS */
    Relids      min_righthand;  /* minimum relids on RHS */
    Relids      syn_lefthand;   /* syntactic LHS relids */
    Relids      syn_righthand;  /* syntactic RHS relids */
    JoinType    jointype;
    bool        lhs_strict;     /* does ON clause reject nulls from LHS? */
    bool        semi_can_btree; /* can use btree for semi-join? */
    bool        semi_can_hash;  /* can use hash for semi-join? */
    List       *semi_operators; /* equality operators for semi-join */
    List       *semi_rhs_exprs; /* RHS expressions for semi-join */
} SpecialJoinInfo;
```

### SubLink and SubPlan

`SubLink` is the parser representation of a subquery in a WHERE/HAVING clause. After sublink processing, unflattened subqueries become `SubPlan` nodes (for correlated) or `InitPlan` nodes (for uncorrelated).

---

## Diagram: Preprocessing Pipeline

```
┌─────────────────────────────────────────────────────────┐
│                    Query from rewriter                   │
└───────────────────────┬─────────────────────────────────┘
                        │
            ┌───────────v───────────┐
            │  pull_up_sublinks()   │  EXISTS/ANY -> semi/anti joins
            └───────────┬───────────┘
                        │
            ┌───────────v───────────┐
            │ pull_up_subqueries()  │  Flatten simple FROM subqueries
            └───────────┬───────────┘
                        │
            ┌───────────v───────────┐
            │  flatten join tree    │  Merge nested FROM-lists
            │  (join_collapse_limit)│  up to threshold
            └───────────┬───────────┘
                        │
            ┌───────────v───────────┐
            │ preprocess_expression │  Constant folding, function
            │ eval_const_expressions│  inlining, boolean simplification
            └───────────┬───────────┘
                        │
            ┌───────────v───────────┐
            │  canonicalize_qual()  │  AND/OR flattening,
            │  find_duplicate_ors() │  duplicate-OR factoring
            └───────────┬───────────┘
                        │
            ┌───────────v───────────┐
            │ reduce_outer_joins()  │  LEFT JOIN -> INNER JOIN
            │                       │  when WHERE is strict
            └───────────┬───────────┘
                        │
            ┌───────────v───────────┐
            │ remove_useless_result │  Clean up trivial RTEs
            │          _rtes()      │
            └───────────┬───────────┘
                        │
                        v
              Simplified Query tree
              ready for path generation
```

---

## Practical Examples

### Sublink Pullup in Action

```sql
-- Original query:
SELECT e.name FROM employees e
WHERE e.dept_id IN (SELECT d.id FROM departments d WHERE d.budget > 1000000);

-- After preprocessing:
-- The IN sublink becomes a semi-join:
SELECT e.name FROM employees e
SEMI JOIN departments d ON (e.dept_id = d.id AND d.budget > 1000000);
```

### Subquery Pullup in Action

```sql
-- Original query:
SELECT * FROM orders o
JOIN (SELECT customer_id, count(*) as cnt
      FROM returns GROUP BY customer_id) r
ON o.customer_id = r.customer_id;

-- This subquery CANNOT be pulled up because it has GROUP BY.
-- It is planned independently as a black box.

-- But this one CAN be pulled up:
SELECT * FROM orders o
JOIN (SELECT * FROM returns WHERE return_date > '2025-01-01') r
ON o.order_id = r.order_id;

-- After pullup:
SELECT * FROM orders o JOIN returns r
ON o.order_id = r.order_id
WHERE r.return_date > '2025-01-01';
```

---

## Connections

| Subsystem | Relationship |
|-----------|-------------|
| [Parsing & Rewriting](../06-query-parser/) | Produces the Query tree that preprocessing transforms |
| [Path Generation](path-generation) | Receives the simplified query tree and builds access paths |
| [Join Ordering](join-ordering) | Benefits from join-tree flattening: more tables in the search space |
| [Statistics](../13-statistics/) | Constant folding may use catalog lookups; outer-join reduction uses strictness analysis |
| [Cost Model](cost-model) | A well-preprocessed query leads to more accurate cost estimates |
