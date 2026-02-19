---
title: "Hash Index"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "02-access-methods"
chapter_title: "Access Methods"
chapter_url: "/postgresql/02-access-methods/"
---

# Hash Index

## Summary

The hash index provides O(1) equality lookups using **linear hashing**, a
technique that expands the hash table incrementally (one bucket at a time)
rather than doubling all at once. Since PostgreSQL 10, hash indexes are
WAL-logged and crash-safe. They excel at single-column equality predicates
(`WHERE col = value`) but do not support range scans, ordering, or
multi-column indexes in practice.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `src/backend/access/hash/hash.c` | Entry points: `hashhandler()`, `hashbuild()`, `hashinsert()`, `hashgettuple()` |
| `src/backend/access/hash/hashsearch.c` | `_hash_first()`, `_hash_next()` -- scan within a bucket |
| `src/backend/access/hash/hashinsert.c` | `_hash_doinsert()` -- insert into the correct bucket |
| `src/backend/access/hash/hashpage.c` | Bucket management, split operations, page allocation |
| `src/backend/access/hash/hashovfl.c` | Overflow page allocation and management |
| `src/backend/access/hash/hashsort.c` | Bulk loading support using tuplesort |
| `src/backend/access/hash/hashfunc.c` | Built-in hash functions for standard types |
| `src/backend/access/hash/hashutil.c` | Hash value computation, bucket mapping |
| `src/backend/access/hash/hash_xlog.c` | WAL redo routines |
| `src/backend/access/hash/README` | Design document |
| `src/include/access/hash.h` | `HashPageOpaqueData`, `HashMetaPageData`, macros |

---

## How It Works

### Linear Hashing

Unlike traditional hash tables that double in size, linear hashing splits
**one bucket at a time** in round-robin order:

1. The hash table has `2^N` buckets at any point (the "low mask").
2. A **split pointer** `hashm_lowmask` / `hashm_highmask` tracks which
   buckets have been split in the current round.
3. When a split is triggered (by space pressure), the bucket at the split
   pointer is split: entries are redistributed between the original bucket and
   a new bucket at position `original + 2^N`.
4. The split pointer advances. When it reaches `2^N`, a new round begins with
   `2^(N+1)` buckets.

Bucket mapping for a hash value `h`:
```
bucket = h & highmask;
if (bucket > max_bucket)
    bucket = h & lowmask;
```

### Page Organization

```
 Meta page (block 0)
 +-------------------------------------------+
 | HashMetaPageData                           |
 | hashm_nmaps, hashm_ntuples, hashm_ffactor |
 | hashm_maxbucket, hashm_highmask,          |
 | hashm_lowmask, hashm_spares[]             |
 +-------------------------------------------+

 Bitmap pages (blocks 1..N)
 +-------------------------------------------+
 | Track which overflow pages are in use      |
 +-------------------------------------------+

 Bucket pages
 +-------------------------------------------+
 | Primary bucket page for bucket K           |
 | -> overflow page -> overflow page -> ...   |
 +-------------------------------------------+
```

Each bucket has a **primary page** and zero or more **overflow pages** linked
through `hasho_nextblkno` in `HashPageOpaqueData`.

### Insert Path

```
_hash_doinsert(rel, itup)
  -> _hash_hashkey()           // compute hash value
  -> _hash_getbucketbuf()     // map hash to bucket, lock primary page
  -> _hash_pgaddtup()          // add tuple to bucket page
       if no space:
         -> _hash_addovflpage()   // allocate and link overflow page
  -> if too many tuples:
       -> _hash_expandtable()     // split one bucket (linear hashing step)
```

### Search Path

```
_hash_first(scan)
  -> compute hash value from scan key
  -> map to bucket number
  -> lock and read primary bucket page
  -> scan all tuples on page, check for match
  -> follow overflow chain via hasho_nextblkno
  -> _hash_next() continues through overflow pages
```

---

## Key Data Structures

### HashMetaPageData

```c
// src/include/access/hash.h
typedef struct HashMetaPageData
{
    uint32      hashm_magic;
    uint32      hashm_version;
    double      hashm_ntuples;      // number of tuples in index
    uint16      hashm_ffactor;      // fill factor (tuples per bucket target)
    uint16      hashm_bsize;        // bucket page size
    uint16      hashm_bmsize;       // bitmap page size
    uint16      hashm_bmshift;      // shift for bitmap page addressing
    uint32      hashm_maxbucket;    // highest bucket number allocated
    uint32      hashm_highmask;     // mask for current round
    uint32      hashm_lowmask;      // mask for previous round
    uint32      hashm_ovflpoint;    // current overflow split point
    uint32      hashm_firstfree;    // first free overflow page
    uint32      hashm_nmaps;        // number of bitmap pages
    RegProcedure hashm_procid;      // hash function OID
    uint32      hashm_spares[HASH_MAX_SPLITPOINTS];  // spare pages per split point
    BlockNumber hashm_mapp[HASH_MAX_BITMAPS];        // bitmap page block numbers
} HashMetaPageData;
```

### HashPageOpaqueData

```c
// src/include/access/hash.h
typedef struct HashPageOpaqueData
{
    BlockNumber hasho_prevblkno;  // previous page in bucket chain
    BlockNumber hasho_nextblkno;  // next page in bucket chain
    Bucket      hasho_bucket;     // bucket number this page belongs to
    uint16      hasho_flag;       // LH_OVERFLOW_PAGE, LH_BUCKET_PAGE, LH_BITMAP_PAGE, LH_META_PAGE
    uint16      hasho_page_id;    // for identification (HASHO_PAGE_ID)
} HashPageOpaqueData;
```

---

## Diagram: Bucket Chain

```
  hash(key) = 0x7A3F
       |
       v
  bucket = 0x7A3F & highmask = 5
       |
       v
  +------------------+     +------------------+     +------------------+
  | Bucket page 5    | --> | Overflow page    | --> | Overflow page    |
  | (primary)        |     |                  |     |                  |
  | hasho_bucket=5   |     | hasho_bucket=5   |     | hasho_bucket=5   |
  | hasho_flag=      |     | hasho_flag=      |     | hasho_nextblkno= |
  |   LH_BUCKET_PAGE |     |   LH_OVERFLOW    |     |   InvalidBlock   |
  | entries...       |     | entries...       |     | entries...       |
  +------------------+     +------------------+     +------------------+
```

---

## Splitting a Bucket

When `_hash_expandtable()` is called:

1. Lock the meta page exclusively.
2. Increment `hashm_maxbucket`.
3. Allocate a new primary page for the new bucket.
4. Acquire cleanup lock on the old (splitting) bucket.
5. Scan all tuples in the old bucket (primary + overflow pages).
6. For each tuple, recompute `hash & new_highmask`:
   - If it maps to the new bucket, move it there.
   - Otherwise, keep it in the old bucket.
7. Free any now-empty overflow pages.

This is a **heavyweight operation** that holds locks on the splitting bucket
for the duration, but only affects one bucket -- all other buckets remain
readable and writable.

---

## Limitations

- **Equality only**: Hash indexes only support the `=` operator. No range
  scans, no `ORDER BY`, no pattern matching.
- **No multi-column**: While syntactically allowed, hash indexes on multiple
  columns are rarely useful since the hash is computed over the combined value.
- **No unique constraints**: `amcanunique = false`.
- **Write amplification on splits**: Splitting reads and rewrites entire bucket
  chains under exclusive locks.
- **Overflow chains**: Under skewed distributions, some buckets accumulate long
  overflow chains, degrading to O(n) within a bucket.

---

## When to Use Hash Indexes

Hash indexes are beneficial when:
- The column has high cardinality and queries are exclusively `=` lookups.
- The index keys are very wide (hash reduces them to 4-byte hash values).
- You want a smaller index footprint than a B-tree for equality-only workloads.

Since PostgreSQL 10+, hash indexes are crash-safe (WAL-logged). Before that,
they were considered unsafe and rarely recommended.

---

## Connections

- **B-tree**: For most equality lookups, B-tree is competitive with hash and
  also supports range scans. Hash is preferred only for very specific workloads.
- **Heap AM**: Hash index entries contain TIDs pointing to heap tuples, like
  all index AMs.
- **WAL**: `hash_xlog.c` provides redo support for inserts, splits, overflow
  page operations, and bitmap changes.
- **Planner**: Hash indexes set `amcanhash = true` and are considered for
  equality predicates. The planner uses `hashcostestimate()` for costing.
