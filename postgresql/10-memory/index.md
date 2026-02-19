---
title: "Memory Management"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "10-memory"
chapter_title: "Memory Management"
is_chapter_index: true
---

# Chapter 10: Memory Management

> *PostgreSQL replaces malloc/free with a hierarchy of memory contexts that turn deallocation into a single reset call, making leak-free error recovery trivial in a language without garbage collection.*

## Why It Matters

In a long-running database backend that processes thousands of queries, memory leaks are
not just wasteful --- they are fatal. A slow leak of a few kilobytes per query becomes
gigabytes over a weekend. C provides no garbage collector, and manually pairing every
`malloc` with a `free` across every possible error path is a losing battle.

PostgreSQL solves this with **memory contexts**: arena-style allocators organized into a
tree. Each context represents a lifetime --- per-transaction, per-query, per-tuple. When
the lifetime ends, one call to `MemoryContextReset()` frees everything at once, regardless
of how many individual allocations were made. This design has three critical properties:

1. **Bulk deallocation is O(1) per block**, not O(n) per allocation.
2. **Error recovery is automatic**: aborting a transaction resets its context tree.
3. **No dangling pointers across lifetimes**: child contexts die with their parents.

Beyond process-local memory, PostgreSQL must also share memory between parallel workers.
The **Dynamic Shared Area (DSA)** system provides a heap allocator on top of dynamically
attached shared memory segments, enabling parallel hash joins, parallel sorts, and other
cooperative operations.

Finally, memory is only one of many resources that must be tracked per-query. Buffer pins,
locks, file descriptors, and cache references all need guaranteed cleanup.
**Resource owners** provide this guarantee using the same tree-of-lifetimes pattern that
memory contexts use for memory.

## Chapter Map

| Topic | File | What You Will Learn |
|-------|------|---------------------|
| Memory Contexts | [memory-contexts.md](memory-contexts.md) | The context tree hierarchy, the four allocator implementations (AllocSet, Slab, Generation, Bump), the MemoryChunk header, and `palloc`/`pfree` internals |
| Dynamic Shared Areas | [dsa.md](dsa.md) | How DSA builds a shared-memory heap on top of DSM segments, dsa_pointer encoding, size classes, superblocks, and span management for parallel query |
| Resource Owners | [resource-owners.md](resource-owners.md) | How PostgreSQL tracks buffers, locks, files, and cache references per transaction and portal, the three-phase release protocol, and the relationship to memory contexts |

## The Big Picture

```
  TopMemoryContext
  |
  +-- PostmasterContext
  +-- CacheMemoryContext
  |     +-- per-relcache-entry contexts
  +-- MessageContext
  +-- TopTransactionContext          <-- ResourceOwner: TopTransaction
  |     +-- CurTransactionContext    <-- ResourceOwner: CurTransaction
  |           +-- PortalContext      <-- ResourceOwner: Portal
  |                 +-- ExecutorState
  |                       +-- per-ExprContext (per-tuple)
  +-- ErrorContext (pre-allocated, reserved for OOM recovery)

  Shared Memory
  +-- dsa_area (parallel query)
  |     +-- segment 0 (control + first segment)
  |     +-- segment 1 (dynamically attached)
  |     +-- ...
```

The tree above shows the two parallel hierarchies. Memory contexts manage the *memory
itself*; resource owners manage *everything else* that has a query or transaction
lifetime. Both hierarchies mirror the nesting of transactions and portals, and both
support the same "release parent releases children" invariant.

## Key Design Principles

**Context-per-lifetime.** Rather than tracking individual allocations, group them by when
they should die. Per-tuple memory resets every row. Per-query memory resets at query end.
Per-transaction memory resets at commit or abort.

**The current context idiom.** The global `CurrentMemoryContext` lets `palloc()` work
without an explicit context parameter. Code that creates temporary allocations should
ensure `CurrentMemoryContext` points to a short-lived context. Pointing it at
`TopMemoryContext` risks permanent leaks.

**Pluggable allocators.** The `MemoryContextMethods` virtual function table allows
different allocation strategies (power-of-two freelists, fixed-size slabs, append-only
generations, headerless bumps) behind the same `palloc`/`pfree` API.

**Fail-safe cleanup.** On `ERROR`, PostgreSQL unwinds through `MemoryContextReset` of
the transaction context tree and `ResourceOwnerRelease` of the transaction resource
owner tree. Between these two mechanisms, all transient state is reclaimed without
requiring every code path to have explicit cleanup logic.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/include/utils/palloc.h` | Core allocation API: `palloc`, `pfree`, `MemoryContextSwitchTo` |
| `src/include/nodes/memnodes.h` | `MemoryContextData`, `MemoryContextMethods` structs |
| `src/include/utils/memutils.h` | Context creation macros, well-known contexts, size limits |
| `src/include/utils/memutils_internal.h` | `MemoryContextMethodID` enum, per-allocator function prototypes |
| `src/include/utils/memutils_memorychunk.h` | `MemoryChunk` header: 8-byte layout encoding block offset, value, and method ID |
| `src/backend/utils/mmgr/mcxt.c` | Dispatcher: `palloc` -> method lookup via `mcxt_methods[]` |
| `src/backend/utils/mmgr/aset.c` | AllocSet: general-purpose power-of-two freelist allocator |
| `src/backend/utils/mmgr/slab.c` | Slab: fixed-size chunk allocator |
| `src/backend/utils/mmgr/generation.c` | Generation: FIFO-lifetime allocator |
| `src/backend/utils/mmgr/bump.c` | Bump: headerless append-only allocator |
| `src/backend/utils/mmgr/dsa.c` | Dynamic Shared Areas: shared-memory heap |
| `src/include/utils/dsa.h` | DSA public API: `dsa_pointer`, `dsa_allocate`, `dsa_free` |
| `src/backend/utils/resowner/resowner.c` | Resource owner implementation |
| `src/include/utils/resowner.h` | Resource owner API: phases, priorities, `ResourceOwnerDesc` |

## Connections to Other Chapters

- **Chapter 0 (Architecture):** The process model dictates that each backend has its own
  context tree, while shared memory requires DSA for cross-process allocation.
- **Chapter 3 (Transactions):** Transaction commit and abort drive context resets and
  resource owner releases.
- **Buffer Manager:** Buffer pins are tracked by resource owners; buffer descriptors live
  in shared memory allocated at startup (not via DSA).
- **Executor:** `ExprContext` per-tuple memory contexts are the most frequently reset
  contexts in the system, directly affecting query throughput.
- **Parallel Query:** Parallel hash joins and sorts use DSA to share hash tables and
  tuple stores across workers.
