---
title: "Resource Owners"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "10-memory"
chapter_title: "Memory Management"
chapter_url: "/postgresql/10-memory/"
---

# Resource Owners

> *Memory contexts prevent memory leaks; resource owners prevent everything-else leaks --- buffer pins, locks, file descriptors, cache references, and DSM segments are all guaranteed to be released at transaction end, even if the query fails mid-execution.*

## Summary

A `ResourceOwner` is a container that tracks non-memory resources acquired during query
execution. Just like memory contexts form a tree of lifetimes for memory, resource owners
form a parallel tree of lifetimes for resources such as buffer pins, heavyweight and
lightweight locks, relation cache references, catalog cache references, tuple
descriptors, file descriptors, and DSM segments.

When a portal closes or a transaction ends, `ResourceOwnerRelease()` walks the tree and
releases all tracked resources in a well-defined three-phase order: first resources that
are visible to other backends (buffer pins, DSM segments), then locks, then
backend-internal resources (cache references, files). This guarantees that when a lock
is released, no externally-visible state depends on it.

## Overview

### The Problem

Consider a query that pins three buffers, acquires two locks, opens a file for a
sort run, and grabs several catalog cache references. If the query fails at any point,
all of these resources must be released. Without centralized tracking, every function in
the call chain would need error-handling code to release the specific resources it
acquired. This is fragile and error-prone.

### The Solution

The `ResourceOwner` acts as a ledger. When a buffer is pinned, the pin is registered
with `CurrentResourceOwner`. When the pin is released normally, it is deregistered.
If the transaction aborts before the pin is released, `ResourceOwnerRelease()` finds
the orphaned pin and releases it, emitting a WARNING at commit (since resources should
have been properly released).

Resource owners mirror the transaction/subtransaction/portal nesting:

```
TopTransactionResourceOwner
+-- CurTransactionResourceOwner (same as Top at top level)
|     +-- Portal ResourceOwner
|     +-- Portal ResourceOwner
+-- Subtransaction ResourceOwner
      +-- Portal ResourceOwner
```

When a child resource owner is released (e.g., portal closes), its remaining resources
transfer to the parent (for locks on commit) or are released outright (for most
resources on abort).

## Key Source Files

| File | Role |
|------|------|
| `src/include/utils/resowner.h` | Public API: `ResourceOwnerDesc`, phases, priorities, `ResourceOwnerRemember`/`Forget` |
| `src/backend/utils/resowner/resowner.c` | Implementation: `ResourceOwnerData`, hash table, release logic |
| `src/backend/utils/resowner/README` | Design rationale and usage guide |

## How It Works

### Registering and Releasing Resources

Every tracked resource type is described by a `ResourceOwnerDesc`:

```c
typedef struct ResourceOwnerDesc
{
    const char *name;                       /* for debugging */
    ResourceReleasePhase release_phase;     /* BEFORE_LOCKS, LOCKS, or AFTER_LOCKS */
    ResourceReleasePriority release_priority; /* ordering within phase */
    void (*ReleaseResource)(Datum res);     /* cleanup callback */
    char *(*DebugPrint)(Datum res);         /* optional: for leak warnings */
} ResourceOwnerDesc;
```

Resources are tracked through three operations:

```c
/* Before acquiring a resource, ensure the hash table has space */
ResourceOwnerEnlarge(CurrentResourceOwner);

/* After acquiring the resource, register it */
ResourceOwnerRemember(CurrentResourceOwner, PointerGetDatum(myresource), &myresource_desc);

/* When releasing the resource normally */
ResourceOwnerForget(CurrentResourceOwner, PointerGetDatum(myresource), &myresource_desc);
```

The `Enlarge` / `Remember` / `Forget` pattern exists because `Remember` must not fail
(it may be called after a resource is already acquired), so `Enlarge` pre-allocates
hash table space while failure is still safe.

### The Three Release Phases

`ResourceOwnerRelease()` must be called three times, once per phase:

**Phase 1: RESOURCE_RELEASE_BEFORE_LOCKS**

Resources that are visible to other backends must be released before locks. If locks
were released first, another backend could see inconsistent state.

| Resource | Priority | Why Before Locks |
|----------|----------|-----------------|
| Buffer I/O (in-progress) | 100 | Must complete or cancel I/O before unpinning |
| Buffer pins | 200 | Other backends may be waiting to evict the page |
| Relcache references | 300 | Must close relation before releasing lock on it |
| DSM segments | 400 | Shared memory visible to other processes |
| JIT contexts | 500 | Backend-internal but involves shared state |
| Crypto/HMAC contexts | 600-700 | May hold OS resources |

**Phase 2: RESOURCE_RELEASE_LOCKS**

Lock release is handled specially. On **commit**, locks transfer to the parent resource
owner (they persist until end of transaction). On **abort**, locks are actually released.

**Phase 3: RESOURCE_RELEASE_AFTER_LOCKS**

Backend-internal resources that no other process can see:

| Resource | Priority | Description |
|----------|----------|-------------|
| Catcache references | 100 | Catalog cache entry reference counts |
| Catcache list references | 200 | Catalog cache list reference counts |
| Plan cache references | 300 | Cached plan reference counts |
| Tuple descriptor references | 400 | Reference-counted tuple descriptors |
| Snapshot references | 500 | Registered snapshots |
| Files | 600 | Open file descriptors |
| Wait event sets | 700 | Event monitoring handles |

### Internal Data Structure

The `ResourceOwnerData` struct uses a hybrid storage strategy optimized for the common
case (few resources, short-lived):

```c
struct ResourceOwnerData
{
    ResourceOwner parent;
    ResourceOwner firstchild;
    ResourceOwner nextchild;
    const char   *name;

    bool          releasing;      /* true during ResourceOwnerRelease */
    bool          sorted;         /* true after sorting for release */

    uint8         nlocks;         /* locks in the local cache */
    uint8         narr;           /* items in the fixed array */
    uint32        nhash;          /* items in the hash table */

    /* Fixed-size array for most-recently-added resources (fast path) */
    ResourceElem  arr[RESOWNER_ARRAY_SIZE];   /* 32 entries */

    /* Open-addressing hash table for overflow */
    ResourceElem *hash;
    uint32        capacity;       /* allocated slots */
    uint32        grow_at;        /* resize threshold */

    /* Separate fast cache for local locks */
    LOCALLOCK    *locks[MAX_RESOWNER_LOCKS];  /* 15 entries */

    /* AIO handles (registered in critical sections) */
    dlist_head    aio_handles;
};
```

**Why a fixed array plus a hash table?** The most common pattern is: acquire a
resource, use it briefly, release it (e.g., pin a buffer, read a tuple, unpin).
The fixed array of 32 entries handles this fast path with a simple linear scan.
Only when the array fills up do entries spill into the hash table.

**Why a separate lock cache?** Lock operations are extremely frequent. Rather than
storing locks in the general-purpose array/hash, each resource owner has a dedicated
15-entry cache. When this overflows, the lock manager's own hash table is used as
fallback, but the per-owner cache speeds up the common case of a handful of locks
per query.

### Release Ordering Within a Tree

When releasing, the tree is processed **children before parents** within each phase.
The full sequence for a three-phase release of a parent with one child:

```
Phase 1 (BEFORE_LOCKS):
  child:  release buffer I/Os       (priority 100)
  child:  release buffer pins       (priority 200)
  child:  release relcache refs     (priority 300)
  ...
  parent: release buffer I/Os       (priority 100)
  parent: release buffer pins       (priority 200)
  parent: release relcache refs     (priority 300)
  ...

Phase 2 (LOCKS):
  child:  release/transfer locks
  parent: release/transfer locks

Phase 3 (AFTER_LOCKS):
  child:  release catcache refs     (priority 100)
  child:  release plan cache refs   (priority 300)
  child:  release files             (priority 600)
  ...
  parent: release catcache refs     (priority 100)
  parent: release plan cache refs   (priority 300)
  parent: release files             (priority 600)
  ...
```

### Leak Detection

At **commit**, if `ResourceOwnerRelease` finds any resources still registered, it emits
a WARNING for each one (using the `DebugPrint` callback if available). This indicates a
bug: the code that acquired the resource should have released it before commit. At
**abort**, finding unreleased resources is expected and normal --- that is the entire
point of the resource owner mechanism.

### Adding a New Resource Type

Extensions can track custom resources by defining a `ResourceOwnerDesc`:

```c
static const ResourceOwnerDesc myresource_desc = {
    .name = "MyFancyResource",
    .release_phase = RESOURCE_RELEASE_AFTER_LOCKS,
    .release_priority = RELEASE_PRIO_FIRST,
    .ReleaseResource = ReleaseMyFancyResource,
    .DebugPrint = NULL   /* use default format */
};
```

Then use `ResourceOwnerEnlarge`, `ResourceOwnerRemember`, and `ResourceOwnerForget`
as shown above. The alternative `RegisterResourceReleaseCallback` API still exists
for legacy compatibility but is less convenient.

## Key Data Structures

### ResourceOwnerData

```
ResourceOwnerData
+-- parent / firstchild / nextchild   (tree linkage, same pattern as MemoryContextData)
+-- arr[32]                            (fixed array of ResourceElem)
|     Each entry: { Datum item, const ResourceOwnerDesc *kind }
+-- hash (dynamically allocated)       (open-addressing hash table)
|     Initial capacity: 64 slots
|     Grows at 75% fill (minus array size headroom)
+-- locks[15]                          (LOCALLOCK* fast cache)
+-- aio_handles                        (dlist for async I/O handles)
```

### ResourceElem

```c
typedef struct ResourceElem
{
    Datum                    item;   /* the tracked resource (pointer, fd, etc.) */
    const ResourceOwnerDesc *kind;   /* NULL means empty slot in hash table */
} ResourceElem;
```

### Release Phase and Priority

```
RESOURCE_RELEASE_BEFORE_LOCKS
    priority 100: Buffer I/Os
    priority 200: Buffer Pins
    priority 300: Relcache Refs
    priority 400: DSM Segments
    priority 500: JIT Contexts
    priority 600: Crypto Hash Contexts
    priority 700: HMAC Contexts

RESOURCE_RELEASE_LOCKS
    (locks handled specially: transfer on commit, release on abort)

RESOURCE_RELEASE_AFTER_LOCKS
    priority 100: Catcache Refs
    priority 200: Catcache List Refs
    priority 300: Plan Cache Refs
    priority 400: Tuple Descriptor Refs
    priority 500: Snapshot Refs
    priority 600: Files
    priority 700: Wait Event Sets
```

## Diagrams

### Resource Owner Tree and Transaction Lifecycle

```
BEGIN;                                    TopTransactionResourceOwner
                                           |
  SAVEPOINT sp1;                           +-- SubtransactionResourceOwner
                                           |     |
    SELECT * FROM t WHERE ...;             |     +-- PortalResourceOwner
    (pins buffers, acquires locks)         |     |     pins: [buf#42, buf#99]
                                           |     |     locks: [rel 16384 AccessShareLock]
    -- query completes normally --         |     |     (all forgotten on normal release)
    -- portal closes --                    |     +-- (deleted, locks transfer to parent)
                                           |
  RELEASE SAVEPOINT sp1;                   +-- (subtxn resources merge into parent)
                                           |
COMMIT;                                    (release all: pins WARNING if leaked,
                                            locks released, cache refs released)
```

### The Remember/Forget Fast Path

```
ReadBuffer(rel, blockno)
    |
    v
PinBuffer(buf)
    |
    v
ResourceOwnerEnlarge(CurrentResourceOwner)   <-- pre-allocate space
    |
    v
ResourceOwnerRemember(owner, buf, &buffer_pin_desc)
    |
    v
narr < 32?
   |
  YES --> arr[narr++] = {buf, &buffer_pin_desc}   (fast path, no hashing)
   |
  NO  --> move all arr entries to hash table, then arr[0] = {buf, &buffer_pin_desc}
    |
    v
... use buffer ...
    |
    v
ReleaseBuffer(buf)
    |
    v
ResourceOwnerForget(owner, buf, &buffer_pin_desc)
    |
    v
Scan arr[] for matching (buf, kind)
   |
  FOUND --> swap with arr[narr-1], narr--    (fast path)
   |
  NOT FOUND --> scan hash table, remove entry
```

## Connections

- **Memory Contexts** ([memory-contexts.md](memory-contexts.md)): Resource owners and
  memory contexts are parallel hierarchies with corresponding lifetimes. A transaction
  has both a `TopTransactionContext` and a `TopTransactionResourceOwner`. They are
  separate because their usage patterns differ: memory contexts manage bulk allocation
  and deallocation; resource owners track individual countable resources.
- **Buffer Manager:** Every buffer pin is tracked by the current resource owner. This is
  the most frequent use of the resource owner system --- a sequential scan pins and
  unpins thousands of buffers per second.
- **Lock Manager:** Lock ownership transfers to the parent resource owner on commit
  (locks persist until end of transaction) but actually releases on abort. This special
  behavior is why locks have their own release phase.
- **DSA / DSM** ([dsa.md](dsa.md)): DSM segment attachments are tracked as
  BEFORE_LOCKS resources (priority 400). When a transaction that created a DSA area
  aborts, the DSM segments are automatically detached and freed.
- **Catalog Cache:** Catalog cache pins (`SearchSysCache` results) are tracked as
  AFTER_LOCKS resources. They must be released after locks because the cache entries
  are backend-local and invisible to other processes.
- **Error Handling:** `AbortTransaction` calls `ResourceOwnerRelease` in all three
  phases on `TopTransactionResourceOwner`, ensuring complete cleanup regardless of
  where the error occurred.
