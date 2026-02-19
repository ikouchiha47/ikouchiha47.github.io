---
title: "GEQO"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "07-query-optimizer"
chapter_title: "Query Optimizer"
chapter_url: "/postgresql/07-query-optimizer/"
---

# Genetic Query Optimizer (GEQO)

When a query involves many tables (default threshold: 12), the dynamic programming join search becomes impractical -- the number of possible join orders grows super-exponentially. PostgreSQL switches to a **Genetic Algorithm (GA)** that explores the search space stochastically, trading optimality guarantees for bounded planning time. This is the Genetic Query Optimizer, or GEQO.

---

## Summary

GEQO models the join-ordering problem as a variant of the Traveling Salesman Problem. Each candidate solution (a "chromosome") encodes a permutation of the query's tables, which is decoded into a join tree. A population of chromosomes evolves over multiple generations through selection, crossover, and mutation. The fitness of each chromosome is the cost of the resulting plan. After a configurable number of generations, the best chromosome found is returned.

Critically, GEQO only decides the **join order**. For each proposed join pair, it still calls the standard `add_paths_to_joinrel()` machinery to enumerate all join methods (nested loop, merge, hash) and uses the normal cost model. GEQO is a heuristic wrapper around the exhaustive path-generation code.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/optimizer/geqo/geqo_main.c` | `geqo()` -- top-level entry point, GA loop |
| `src/backend/optimizer/geqo/geqo_eval.c` | `geqo_eval()` -- decode chromosome into join tree, compute cost |
| `src/backend/optimizer/geqo/geqo_pool.c` | Population management (initialization, replacement) |
| `src/backend/optimizer/geqo/geqo_selection.c` | Parent selection (linear bias) |
| `src/backend/optimizer/geqo/geqo_recombination.c` | Common crossover infrastructure |
| `src/backend/optimizer/geqo/geqo_erx.c` | Edge Recombination Crossover (ERX) -- the default |
| `src/backend/optimizer/geqo/geqo_ox1.c` | Order Crossover variant 1 |
| `src/backend/optimizer/geqo/geqo_ox2.c` | Order Crossover variant 2 |
| `src/backend/optimizer/geqo/geqo_pmx.c` | Partially Mapped Crossover |
| `src/backend/optimizer/geqo/geqo_cx.c` | Cycle Crossover |
| `src/backend/optimizer/geqo/geqo_px.c` | Position Crossover |
| `src/backend/optimizer/geqo/geqo_mutation.c` | Mutation operator (swap two genes) |
| `src/backend/optimizer/geqo/geqo_random.c` | Deterministic pseudo-random number generator |
| `src/backend/optimizer/geqo/geqo_copy.c` | Chromosome copy routines |
| `src/backend/optimizer/geqo/geqo_misc.c` | Debugging/printing utilities |
| `src/include/optimizer/geqo.h` | GEQO data types and configuration |

---

## How It Works

### When GEQO Activates

The decision is made in `make_rel_from_joinlist()` in `allpaths.c`:

```c
if (enable_geqo && list_length(joinlist) >= geqo_threshold)
    return geqo(root, list_length(joinlist), initial_rels);
else
    return standard_join_search(root, levels_needed, initial_rels);
```

Default `geqo_threshold` is 12 tables. Below this, exhaustive DP search is used. Above it, the factorial growth of join orders makes DP impractical.

### The Genetic Algorithm Loop

```
geqo(root, number_of_rels, initial_rels):

  1. Determine pool_size and number_of_generations from GUC params
  2. Initialize population: pool_size random chromosomes
     Each chromosome = random permutation of [1..number_of_rels]

  3. Evaluate each chromosome:
     For each chromosome in pool:
       cost = geqo_eval(chromosome)
       chromosome.fitness = cost

  4. Sort pool by fitness (lowest cost first)

  5. Evolution loop:
     For generation = 1 to number_of_generations:
       a. Select two parents (momma, daddy) via linear bias
       b. Create offspring via crossover (ERX by default)
       c. Evaluate offspring: cost = geqo_eval(offspring)
       d. If offspring is better than worst in pool:
            Replace worst chromosome with offspring
            Re-sort pool

  6. Return the best chromosome's RelOptInfo
```

### Chromosome Encoding

A chromosome is an array of integers representing a permutation of the relation indices:

```c
typedef struct Chromosome
{
    Gene   *string;     /* array of Gene (= int) values */
    Cost    worth;      /* fitness = total plan cost */
} Chromosome;
```

For a 5-table query, a chromosome might be `[3, 1, 4, 2, 5]`, meaning: start with relation 3, then join relation 1, then join relation 4, etc.

### Decoding: gimme_tree() in geqo_eval.c

The chromosome is decoded into an actual join tree by `gimme_tree()`:

```
gimme_tree(chromosome, num_rels):
  clumps = empty list

  For each gene in chromosome:
    new_clump = the base RelOptInfo for this gene

    Repeatedly try to merge new_clump with existing clumps:
      For each existing clump C:
        If new_clump and C share a join clause:
          joined = make_join_rel(new_clump, C)
          Replace C with joined, continue merging

    If no merge possible:
      Add new_clump to clumps list

  If clumps has more than one entry:
    Force clauseless joins to combine them

  Return the final single clump's RelOptInfo
```

The "clump" approach is important: it prefers joining relations that have join clauses between them, avoiding Cartesian products when possible. The chromosome order only determines tie-breaking when multiple join partners are available.

Each `make_join_rel()` call inside `gimme_tree()` invokes the full `add_paths_to_joinrel()` machinery, generating all possible join methods and keeping only Pareto-optimal paths. This means GEQO does not sacrifice join-method quality -- only join-order optimality.

### Crossover Operators

The default crossover is **Edge Recombination Crossover (ERX)**, which preserves adjacency relationships from both parents. This is appropriate because the TSP-like nature of the problem means that which relations are adjacent in the join order matters more than their absolute positions.

Available crossover operators (selected at compile time via `#define` in `geqo.h`):

| Operator | Description |
|----------|-------------|
| ERX | Edge Recombination -- preserves adjacency edges from both parents |
| PMX | Partially Mapped -- preserves absolute position of some genes |
| CX | Cycle Crossover -- preserves position via cycles |
| PX | Position Crossover -- direct position inheritance |
| OX1 | Order Crossover 1 -- preserves relative order |
| OX2 | Order Crossover 2 -- variant of OX1 |

### Selection

Parent selection uses **linear bias**: chromosomes are ranked by fitness, and the probability of being selected as a parent is linearly proportional to rank. The bias is controlled by `geqo_selection_bias` (default 2.0, range 1.5--2.0). Higher bias favors fitter individuals more strongly.

### Mutation

When `CX` crossover is enabled, a mutation operator is also applied: it randomly swaps two genes in the chromosome. With the default ERX crossover, mutation is not used because ERX already introduces sufficient diversity.

---

## Configuration Parameters

| GUC | Default | Description |
|-----|---------|-------------|
| `geqo` | on | Enable/disable GEQO |
| `geqo_threshold` | 12 | Minimum FROM items to trigger GEQO |
| `geqo_effort` | 5 | Controls pool size and generations (1--10) |
| `geqo_pool_size` | 0 | Pool size (0 = auto from effort and num_rels) |
| `geqo_generations` | 0 | Number of generations (0 = auto from pool_size) |
| `geqo_selection_bias` | 2.0 | Selection pressure (1.5--2.0) |
| `geqo_seed` | 0.0 | Random seed for reproducibility (0.0 = use PID) |

### Auto-Sizing

When `geqo_pool_size = 0` (default), pool size is computed as:

```c
pool_size = 2 * pow(2.0, rint(log(number_of_rels) / log(2.0)));
/* Clamped to range [128, 1024] for geqo_effort = 5 */
```

When `geqo_generations = 0` (default):

```c
generations = pool_size;  /* one generation per pool member */
```

Higher `geqo_effort` values increase both pool size and generations, spending more planning time to explore more of the search space.

---

## Memory Management

GEQO creates a temporary memory context for each chromosome evaluation:

```c
/* From geqo_eval.c */
mycontext = AllocSetContextCreate(CurrentMemoryContext,
                                   "GEQO",
                                   ALLOCSET_DEFAULT_SIZES);
oldcxt = MemoryContextSwitchTo(mycontext);

/* Build join tree for this chromosome */
joinrel = gimme_tree(root, tour, num_gene);

/* Copy the surviving path out of the temp context */
MemoryContextSwitchTo(oldcxt);
MemoryContextDelete(mycontext);
```

This ensures that the many intermediate RelOptInfos and Paths created during evaluation of rejected chromosomes are freed promptly, rather than accumulating for the entire planning phase.

---

## Diagram: GEQO Evolution

```
Generation 0 (random initialization):

  Chromosome 1: [3,1,4,2,5]  cost=1500
  Chromosome 2: [1,2,3,4,5]  cost=1200  <-- current best
  Chromosome 3: [5,4,3,2,1]  cost=1800
  Chromosome 4: [2,5,1,3,4]  cost=1350
  ...

Generation 1:
  Select parents: #2 (best) and #4 (good)
  Crossover (ERX): offspring [1,2,5,3,4]
  Evaluate: cost=1100  <-- new best!
  Replace worst (#3) with offspring

Generation 2:
  Select parents: offspring and #2
  Crossover: [1,5,2,3,4]
  Evaluate: cost=1250
  Replace worst remaining
  ...

Final:
  Best chromosome: [1,2,5,3,4]  cost=1100
  Decode to join tree:
    ((rel1 JOIN rel2) JOIN rel5) JOIN (rel3 JOIN rel4)
```

---

## GEQO vs. Standard Search: Trade-offs

| Aspect | Standard DP | GEQO |
|--------|------------|------|
| Optimality | Guaranteed optimal for the cost model | Heuristic -- may miss the true optimum |
| Planning time | O(2^N) for N tables | O(pool_size * generations * join_cost) |
| Reproducibility | Deterministic | Deterministic if `geqo_seed` is fixed |
| Small queries | Fast and optimal | Not used (below threshold) |
| Large queries | Impractical (12+ tables) | Practical for hundreds of tables |
| Join methods | All considered | All considered (only join ORDER is heuristic) |

---

## Practical Considerations

1. **Raise geqo_threshold** if planning time is acceptable. For data warehouse queries with 15--20 tables, DP often finishes in reasonable time and finds better plans than GEQO.

2. **Fix geqo_seed** for reproducibility. By default, GEQO uses a seed derived from the PID, so the same query can produce different plans across connections. Set `geqo_seed` to a nonzero constant to get deterministic behavior.

3. **GEQO and explicit JOINs.** If parts of the join tree are constrained by explicit JOIN syntax (not flattened due to `join_collapse_limit`), those sub-trees are planned with DP before GEQO sees them. Only the top-level FROM list enters the GA.

4. **Plugin hook.** `join_search_hook` allows extensions to replace both `standard_join_search()` and `geqo()` with custom join-order algorithms.

---

## Connections

| Subsystem | Relationship |
|-----------|-------------|
| [Join Ordering](join-ordering) | GEQO is the alternative to standard_join_search() for the same problem |
| [Path Generation](path-generation) | GEQO calls add_paths_to_joinrel() for every join it considers |
| [Cost Model](cost-model) | Chromosome fitness is the total_cost of the resulting plan |
| [Preprocessing](preprocessing) | join_collapse_limit determines how many tables enter GEQO |
| [Memory Management](../10-memory/) | GEQO uses temporary memory contexts to avoid leaking intermediate paths |
