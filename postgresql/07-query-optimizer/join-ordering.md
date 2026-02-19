---
title: "Join Ordering"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "07-query-optimizer"
chapter_title: "Query Optimizer"
chapter_url: "/postgresql/07-query-optimizer/"
---

# Join Ordering

Given N tables, there are exponentially many possible join orders and join methods. PostgreSQL uses **dynamic programming** to exhaustively search this space for small queries (up to `geqo_threshold` tables, default 12). The search is guided by equivalence classes, pathkeys, and the add_path() Pareto filter. This section covers the standard join search, equivalence classes, and pathkeys.

---

## Summary

The join-ordering problem: given N base relations with their Paths, find the cheapest way to combine them all into a single result. PostgreSQL's standard planner uses a bottom-up dynamic programming algorithm:

- **Level 1:** All base relations (already have paths).
- **Level 2:** Consider all pairs that share a join clause. Generate join paths for each pair.
- **Level 3:** Combine level-2 results with base rels to form 3-way joins.
- ...
- **Level N:** The final join relation including all base rels.

At each level, only Pareto-optimal paths survive (via `add_path()`), which keeps the search tractable.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/optimizer/path/joinrels.c` | `standard_join_search()`, `join_search_one_level()`, `make_join_rel()` |
| `src/backend/optimizer/path/joinpath.c` | `add_paths_to_joinrel()` -- generate NestLoop/MergeJoin/HashJoin paths |
| `src/backend/optimizer/path/allpaths.c` | `make_rel_from_joinlist()` -- entry point for join planning |
| `src/backend/optimizer/path/equivclass.c` | EquivalenceClass creation, merging, clause generation |
| `src/backend/optimizer/path/pathkeys.c` | PathKey management, sort-order comparisons |
| `src/backend/optimizer/plan/initsplan.c` | `deconstruct_jointree()` -- distribute quals, build ECs |
| `src/backend/optimizer/plan/analyzejoins.c` | Join removal optimization |
| `src/backend/optimizer/util/relnode.c` | `build_join_rel()` -- create/find join RelOptInfos |
| `src/include/nodes/pathnodes.h` | EquivalenceClass, EquivalenceMember, PathKey definitions |

---

## How It Works

### The Dynamic Programming Algorithm

`standard_join_search()` in `joinrels.c` implements the DP search:

```c
RelOptInfo *
standard_join_search(PlannerInfo *root, int levels_needed, List *initial_rels)
{
    /* Level 1: initial_rels already have paths from set_base_rel_pathlists */

    for (lev = 2; lev <= levels_needed; lev++)
    {
        join_search_one_level(root, lev);

        /* For each newly created joinrel, apply set_cheapest() */
        foreach(lc, root->join_rel_level[lev])
        {
            rel = (RelOptInfo *) lfirst(lc);
            generate_useful_gather_paths(root, rel, false);
            set_cheapest(rel);
        }
    }

    /* Return the single rel at the top level */
    return (RelOptInfo *) linitial(root->join_rel_level[levels_needed]);
}
```

### join_search_one_level()

For each level, this function considers three categories of join combinations:

```
join_search_one_level(root, level):

  1. Left-handed joins: join a (level-1) joinrel with a level-1 base rel
     For each joinrel R of level (level-1):
       make_rels_by_clause_joins(R, other_rels)
         -- join R to each base rel that shares a join clause with R

  2. Bushy joins: join a level-K joinrel with a level-(level-K) joinrel
     For K = 2 to level/2:
       For each joinrel R of level K:
         For each joinrel S of level (level-K):
           if R and S don't overlap and share a join clause:
             make_join_rel(R, S)

  3. Cartesian products (clauseless joins):
     For any (level-1) joinrel with no clause-based partners at this level:
       make_rels_by_clauseless_joins(R, other_rels)
```

**Key insight:** The algorithm considers left-deep, right-deep, and bushy plan trees. A join between {A,B} and {C,D} is a bushy join. The dynamic programming property ensures that by the time we consider joining {A,B} to {C,D}, we have already found the optimal paths for both sub-joins.

### Join Legality

Not all join orders are legal. Outer joins constrain the order:

```sql
SELECT * FROM A LEFT JOIN B ON (A.x = B.y)
                INNER JOIN C ON (B.z = C.w)
```

Here, B must be joined to A before it can be joined to C (because the LEFT JOIN requires A on the left and B on the right). The function `join_is_legal()` in `joinrels.c` checks every proposed join against the list of `SpecialJoinInfo` nodes to enforce these constraints.

The `SpecialJoinInfo` records:
- `min_lefthand` / `min_righthand` -- minimum sets of rels that must be on each side.
- `jointype` -- LEFT, RIGHT, FULL, SEMI, ANTI.
- Whether the join can be commuted with other outer joins (identity 3 from the optimizer README).

### make_join_rel()

When a legal join pair is found:

```
make_join_rel(root, rel1, rel2):
  1. Check join_is_legal() -- verify outer-join constraints
  2. Build or find the join RelOptInfo for {rel1.relids UNION rel2.relids}
  3. Call add_paths_to_joinrel() with rel1 as outer, rel2 as inner
  4. Call add_paths_to_joinrel() with rel2 as outer, rel1 as inner
     (except for SEMI/ANTI where only one direction makes sense)
```

All generated paths for the same set of base rels end up in the same `RelOptInfo`, regardless of the join order used to produce them. This is a key property: `{A JOIN B} JOIN C` and `{A JOIN C} JOIN B` both contribute paths to the joinrel `{A,B,C}`, and `add_path()` keeps only the cheapest.

---

## Equivalence Classes

Equivalence classes (ECs) are one of the most powerful optimizations in PostgreSQL. They represent sets of expressions known to be equal, enabling:

1. **Transitive closure of join predicates.** If `a.x = b.y` and `b.y = c.z`, then `a.x = c.z` is available as a join clause even though the user never wrote it.
2. **Constant propagation.** If `a.x = b.y` and `a.x = 42`, then `b.y = 42` can be pushed down as a restriction on `b`.
3. **Sort-order reasoning.** If the output is sorted by `a.x` and `a.x = b.y`, then the output is also sorted by `b.y`.

### EC Construction

During `deconstruct_jointree()` in `initsplan.c`, every mergejoinable equality clause (`A = B` where the operator belongs to a btree operator family) is processed:

```
process_equivalence(root, restrictinfo):
  left_expr = left side of the clause
  right_expr = right side of the clause

  Find existing ECs containing left_expr or right_expr.
  If both are found in different ECs:
    Merge the two ECs into one.
  Else if one is found:
    Add the other expression to that EC.
  Else:
    Create a new EC with both expressions.
```

After all quals are processed, the EC list is finalized. No further merging occurs.

### EC-Derived Clauses

When building paths for a join between relations A and C, the optimizer calls `generate_join_implied_equalities()`. If an EC contains members from both A and C, a join clause is generated even if no explicit `A.col = C.col` existed in the original query.

For restriction clauses, if an EC contains a constant, `generate_base_implied_equalities()` produces `var = const` clauses for each non-constant member that can be evaluated at the base-relation level.

### Join Domains

Outer joins complicate ECs because equivalences established inside an outer join's ON clause are not valid everywhere. PostgreSQL handles this with **join domains**:

- The top-level query forms a join domain.
- Each outer join's nullable side forms a new join domain.
- Constants only match EC members from the same join domain, preventing incorrect cross-domain constant propagation.

---

## PathKeys

PathKeys represent the sort ordering of a Path's output. They are used to:

1. Avoid explicit sorts when an input is already sorted for a merge join.
2. Satisfy ORDER BY without a top-level sort.
3. Detect redundant sort keys.

### Structure

```c
typedef struct PathKey
{
    NodeTag         type;
    EquivalenceClass *pk_eclass;    /* the value being sorted on */
    Oid             pk_opfamily;    /* btree opfamily for comparison */
    int             pk_strategy;    /* BTLessStrategyNumber or BTGreaterStrategyNumber */
    bool            pk_nulls_first; /* NULLs sorting direction */
} PathKey;
```

A PathKey references an EquivalenceClass rather than a specific expression. This means that if `a.x = b.y` are in the same EC, a path sorted by `a.x` is also considered sorted by `b.y`. This is how merge joins can avoid sorts even when the join clause expressions differ from the index expressions.

### Pathkey Canonicalization

PathKey lists are canonicalized:
- Redundant entries (same EC appearing twice) are removed.
- If an EC contains a constant, its PathKey is dropped entirely (all rows have the same value, so sorting by it is a no-op).

These simplifications let the optimizer discover that an index on `(x, y)` satisfies `ORDER BY x` even when there is a `WHERE y = 5` clause -- the PathKey for `y` is dropped because it is constant.

### Sort-Order Propagation Through Joins

| Join Method | Output Ordering |
|-------------|----------------|
| Nested Loop | Preserves outer path's pathkeys |
| Merge Join | Sorted by the merge keys (via the ECs) |
| Hash Join | No guaranteed ordering (pathkeys = NIL) |

This means merge join output can feed directly into a higher-level merge join or satisfy ORDER BY without an additional sort, while hash join output always requires an explicit sort if ordering is needed.

---

## Diagram: Dynamic Programming Join Search

```
Level 1 (base rels):  {A}  {B}  {C}  {D}
                        │    │    │    │
                        v    v    v    v
                      paths paths paths paths

Level 2 (pairs):     {A,B}      {B,C}      {C,D}
  Join clauses:      A.x=B.y    B.y=C.z    C.z=D.w
  Methods tried:     NL/MJ/HJ   NL/MJ/HJ   NL/MJ/HJ
  add_path() keeps Pareto-optimal survivors

  Also considered via EC: {A,C} (because A.x=B.y and B.y=C.z => A.x=C.z)

Level 3 (triples):  {A,B,C}              {B,C,D}
  Built from:       {A,B}+{C}            {B,C}+{D}
                    {A,C}+{B}            {C,D}+{B}
                    {A}+{B,C}            {B}+{C,D}

Level 4 (final):   {A,B,C,D}
  Built from:      {A,B,C}+{D}
                   {A,B,D}+{C}    (if exists)
                   {A,B}+{C,D}    (bushy)
                   etc.
```

---

## Join Removal

`analyzejoins.c` implements an optimization that removes joins entirely when they are provably unnecessary:

```sql
SELECT a.* FROM a LEFT JOIN b ON a.x = b.y;
-- If b.y is UNIQUE and no columns from b are used in the output,
-- the LEFT JOIN is guaranteed to produce at most one match per row of a.
-- The join can be removed entirely.
```

This is detected by `remove_useless_joins()` and works for:
- LEFT JOINs where the inner side has a unique key matching the join condition and no inner columns are referenced in the output.
- INNER JOINs under similar conditions (the inner side just validates existence without affecting cardinality).

---

## Key Data Structures

### EquivalenceClass

```c
typedef struct EquivalenceClass
{
    NodeTag     type;
    List       *ec_members;    /* list of EquivalenceMember */
    List       *ec_sources;    /* RestrictInfos that created this EC */
    List       *ec_derives;    /* RestrictInfos derived from this EC */
    Relids      ec_relids;     /* union of all member relids */
    bool        ec_has_const;  /* does the EC contain a pseudo-constant? */
    bool        ec_has_volatile; /* contains volatile expression? */
    bool        ec_broken;     /* failed to generate a needed derived clause? */
    bool        ec_merged;     /* has this EC been merged into another? */
    Oid         ec_collation;  /* collation for comparison */
    List       *ec_opfamilies; /* btree opfamilies for equality */
    JoinDomain *ec_max_security; /* highest security_level source */
    struct EquivalenceClass *ec_merged_into; /* if merged, points to survivor */
} EquivalenceClass;
```

### EquivalenceMember

```c
typedef struct EquivalenceMember
{
    NodeTag     type;
    Expr       *em_expr;       /* the expression */
    Relids      em_relids;     /* rels contributing to em_expr */
    bool        em_is_const;   /* is this a pseudo-constant? */
    bool        em_is_child;   /* is this a child-relation member? */
    Oid         em_datatype;   /* data type of the expression */
    JoinDomain *em_jdomain;    /* join domain of the source clause */
} EquivalenceMember;
```

---

## Practical Example: EC-Driven Join Discovery

```sql
SELECT * FROM orders o
JOIN customers c ON o.cust_id = c.id
JOIN addresses a ON c.id = a.cust_id
WHERE o.cust_id = 42;
```

After EC construction:

**EC = {o.cust_id, c.id, a.cust_id, 42}**

This single EC enables:
1. `o.cust_id = 42` pushed to scan of `orders`
2. `c.id = 42` pushed to scan of `customers`
3. `a.cust_id = 42` pushed to scan of `addresses`
4. All three tables can now be joined to each other without explicit join conditions -- each has been filtered to rows matching the constant. The join is effectively validated by the EC.
5. If there are indexes on `customers.id` and `addresses.cust_id`, the optimizer can use them with the constant 42, even though the original query only mentioned `o.cust_id = 42`.

---

## Connections

| Subsystem | Relationship |
|-----------|-------------|
| [Path Generation](path-generation) | join_search calls add_paths_to_joinrel() to populate each joinrel with paths |
| [Cost Model](cost-model) | add_path() uses cost comparisons to maintain the Pareto frontier |
| [GEQO](geqo) | Alternative search strategy when the number of tables exceeds geqo_threshold |
| [Preprocessing](preprocessing) | Join-tree flattening determines how many tables enter the DP search |
| [Plan Creation](plan-creation) | The cheapest path from the top-level joinrel becomes the plan |
| [Statistics](../13-statistics/) | Selectivity estimates drive the row-count estimates that determine which join orders are cheapest |
