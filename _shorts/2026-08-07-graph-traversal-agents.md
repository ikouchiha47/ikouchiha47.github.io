---
date: 2026-08-07 10:30
tags: [ai, agents]
---
Most agent frameworks treat "reasoning" as a straight line — think, act, observe, repeat. But an agent's decision space **is a graph**: states, transitions, branches that dead-end, branches worth revisiting. Game AI solved most of this decades ago, and none of it made it into the agentic-AI toolbox.

Concretely, what's sitting there unused:

- **BFS/DFS as retrieval strategy, not just a data structure exercise.** CRAG-style iterative retrieval (retrieve → critique → expand → retrieve again) is already a graph walk in disguise. Choosing BFS-shaped exploration (wide, shallow, cheap to prune early) vs DFS-shaped (commit to a branch, go deep, backtrack on failure) should be a deliberate call based on the query shape — not whatever the framework's default loop happens to do.
- **A\* and heuristic search, for tool selection.** A\* is just "BFS with a cost function telling you which branch is worth expanding first." An agent choosing which tool/sub-agent to call next is the same problem — a cheap heuristic (expected relevance, expected token cost, past success rate) should prune the search instead of trying every tool in sequence and hoping.
- **GOAP (Goal-Oriented Action Planning).** Game AI has used this since the mid-2000s — an agent picks actions by working backward from a goal state through preconditions, not forward from the current state guessing what to try next. Most agent loops still plan forward. Planning backward from "what does success actually look like" is a different, often better-constrained search.
- **Bottleneck-finding.** Game engines profile the decision tree to find which node actually gates the outcome — same instinct as profiling a request path for the slow span. Agent frameworks rarely do this: which step in a reasoning chain is the one actually worth more compute, more retries, a bigger model? Right now most systems spend the same budget everywhere instead of finding the bottleneck node first.
- **Parallelization at the right places, not everywhere.** Hierarchical/parallel A* only parallelizes independent frontiers — it doesn't fan out blindly. `ParallelReACT` should mean the same discipline: parallelize branches that are provably independent (no shared state, no ordering dependency), not just "call five tools at once because we can."

None of this is novel — it's a "AI 101 for games" chapter most agent-framework authors never read, because they came from NLP/ML, not from game engineering. The vocabulary already exists: frontier, heuristic, admissibility, backward chaining, critical path. Borrowing it directly would save agent frameworks from re-deriving badly, by trial and error, what search theory already worked out.
