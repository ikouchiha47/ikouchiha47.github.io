---
active: true
layout: post
title: "beetledb"
subtitle: "A storage engine"
description: "Building a simple ondisk storage engine"
date: 2024-07-10 00:00:00
background: '/img/beetledb.jpg'
---

# Wassap

Why build another database? Well, to learn a bit more on databases, and it's pretty daunting.
I reckon __it would be fun__.

# Sqlite Love

```c
/*
**    May you do good and not evil.
**    May you find forgiveness for yourself and forgive others.
**    May you share freely, never taking more than you give.
*/
```

-- form [btreeInt.h](https://github.com/sqlite/sqlite/blob/master/src/btreeInt.h)


The initial inspiration comes from [sqlite3](https://www.sqlite.org/whentouse.html). There is more to the database.

- [WAL](https://www.sqlite.org/wal.html) mode.
- BEGIN vs BEGIN IMMEDIATE
- [Durability Tradeoff](https://www.sqlite.org/pragma.html#pragma_synchronous)
- Other `PRAGMA` directives:
  - Capping log file size
  - Increasing page cache size
  - Enabling memory mapping

fly.io has a good [article](https://fly.io/blog/sqlite-internals-wal/) on efficiently using WAL mode.

_We have seen memory mapping before in our emulator as well. Instead of copying the data from disk to application memory space, only the address is passed along._

__This blog is a work in progress. Additions would be made as I progress further__

## Seeding

First steps:

```shell
git clone https://github.com/sqlite/sqlite.git

sqlite test.sqlite3
```

```sql

CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username VARCHAR(32),
        email VARCHAR(255)
    );
```

`_populate.py`

```python
import sqlite3
import random
import string


# Function to generate random usernames and emails
def generate_random_user():
    username = "".join(random.choices(string.ascii_lowercase, k=8))
    email = username + "@mail.com"
    return (username, email)


conn = sqlite3.connect("test.sqlite3")
cursor = conn.cursor()

N = 100000

users_to_insert = [generate_random_user() for _ in range(N)]

# Use executemany for batch insertion
cursor.executemany("INSERT INTO users (username, email) VALUES (?, ?)", users_to_insert)

# Commit the changes and close the connection
conn.commit()
conn.close()

print(f"Inserted {N} user records successfully.")
```

We run this, and then open the file with any `hex editor`. (VScode has an extension to read it).

Head over to the [sqlite's btree internals](https://fly.io/blog/sqlite-internals-btree/). This and the WAL mode article above by fly.io, would give a pretty high level idea of what to deal with.

Database engines generally generate bytecode, which is then translated to equivalent machine instructions.
But my idea is to see, if we can eliminate that.


## Detour

Aaaaannyyyyeeewhooo. On other news. I recently got diagonised with the cliced `ADD` and `Social Anxiety Disorder`. I mean, at this point I am not really surprised, anyone who knows me, can pretty much vouch for my anxiety. The anxiety mostly comes from knowing what's the other person is grade me on what I say. I am also quite self-critical.

There is no shame in admitting that success pretty much defines who I am. So not only I am judging myself, I am also thinking of what I said, and how it didn't go the way I wanted to, and hence I am a failure. I wish it was some other way.

I got my `ADD` in control though, coz a man's gotta live. I have things in place to keep me sane. Of late, writing has helped slow down the thinking, although drawing is faster than writing. Sometimes there are so many variables to an asked question, that I just freeze and stare stupidly. As to help, I can do that to myself, has always been there.

The only good thing about all this. I got addicted to the computer and with its ups and down it has fed me and kept me alive, for me to do other stuff. (If you couldn't tell my now, other stuff is a constant in my life.)

[Dr. K](https://www.youtube.com/watch?v=FUj3-B4yI8U) videos have been helpful. But I already had some of them figured out.

__Those who help themselves, end up helping themselves and some more.__


# More sqlite love

This exercise, atleast for me, requires a whole lot of reading. So here is the list:

- [sqlite architecture](https://www.sqlite.org/arch.html)
- [a guy explaining the by example](https://www.compileralchemy.com/books/sqlite-internals/)
- [b-tree pages](https://sqlite.org/src4/doc/trunk/www/bt.wiki)
  There are index and data pages, and there is also a concept of overflow pages.
- [a good damn book](https://www.oreilly.com/library/view/database-internals/9781492040330/)
  This is again a whole lot of reading, but then you understand different types of indexes.


### A bit about indexes

[Wikipedia](https://en.wikipedia.org/wiki/B%2B_tree) is the best source.

{% preview "https://en.wikipedia.org/wiki/File:Bplustree.png" %}

Well, uptil now this has been my understanding. There are two popular indexing strategies that are used.
In terms of b+tree, the `intermediate nodes` are used to point to the child nodes.

`child nodes` are mostly like `router nodes`, used to keep the tree balanced, by ensuring each node has
optimal amount of keys. 

A `leaf node` is where database generally stores its data, rest all are used for quick lookup, depending on
indexes. In some databases, if you don't have a `primary key` the database `internally` creates one.
_How else, is it supposed to build the b+tree__

So, basically, you have a `key`/`rowid` and then the `value`. And keys are ordered. Great job.

#### two bits on fragmentation

Deletions involving strcutured data isn't instanteneous. In an ideal would, insertion and deletion should
retrigger some sort of rebalancing. But this rebalancings are time consuming. Hence most times, they are
marked as deleted.

Once we have a couple of deletions and updates, it's fairly possible that we can end up with wasted space.
During a DML, if the page size is full, or the size of the data doesn't fit the available page width,
the kernel has to now involve the MMU to get a page allocation.

This new page, can be a different part of the memory bank/sector, and hence, will require page jumps/inderections. (Not contigiiiuuous).

All this leads to what people called a `fragmented state`.

#### clustered index

Here, the values are stored along with keys. And the other secondary indexes point to the primary index.
This means, lookups using `primary keys` are pretty fast.

But for secondary indexes, it has to go via the primary key, so 2 lookups to get 1 data.

[Mysqueel's InnoDB](https://dev.mysql.com/doc/refman/8.4/en/storage-engines.html) is our warlord here.
ISAM behaves more like sqlite in default/journal mode, where for inserts and updates,
it locks the entire table.
Secondary indexes will have their own b+ tree.


My understanding roughly is, inside the leaf nodes, the data is kept in sorted order.

```
Primary B+ Tree:
     [10]
    /    \
 [1-5]  [11-15]
Leaf nodes contain: (1, row data), (2, row data), ..., (15, row data)
```

So, for insertion, first it needs to find the right page, in `log N` time.
Depending on if the page is full or not, the page is split and hence across pages
the ordering is maintained. So within a page,

__RANGE Queries are pretty efficient, and so is Search__

And somehow having ordered heap reduces fragmentation. Although MySQL advises you to run `OPTIMIZE ...`, to
reclaim and re-organise the data pages, and bring them closer.

__More contiguous than the last time__

#### non-clustered index

Rather called it secondary indexes, where there is always an `internal id`, and it points to a `tuple`.
The `tuple` is a combination of the `(page_number, page_offset)` on disk, much like how it works with filesystems
in general.
The data is loaded in the buffer cache, at various stages of execution.

The `secondary indexes` too, point to the same `tuple_id`. And `UPDATEs` and more like `INSERTs`.

__Postgres__ is what does this.

```
Index B+ Tree:
     [10]
    /    \
 [1, TID1-5, TID5]  [11, TID11-15, TID15]
Leaf nodes contain: (1, TID1), (2, TID2), ..., (15, TID15)

Heap:
Page 1: {TID1: (1, row data), TID2: (2, row data), ..., TID5: (5, row data)}
Page 2: {TID11: (11, row data), ..., TID15: (15, row data)}
```

Since the data in the leaf is not ordered like in case of Mysql or sqlite, the insertion process
doesn't need to find the proper data page.

__SELECTs on secondar indexes are therefore faster__, 


This however causes a problem, that the data on disk is not contigious. (Although I am not really sure, aside from using `bitmaps` are there any optimizations they use, this is just theoritical understanding from the book).
And "theoritically" it makes __RANGE queries slower compared to clusted indexes.

So, something, like using 8bit blocks to represent integer keys, so for a 32bit, divided in 4 blocks.

```
let block = num / 8;
let offset = num % 8;

file.seek(block, 0).read(&byte)

byte = byte | (1 << offset)
// 1 << offset, would move the 1 to the left offset number of time
// and the | would set it to 1, indicating its present.
```


The other problem is in case of __UPDATES__ if there are secondary indexes, and the tuple_id changes, all those
secondary indexes has to be updated.


Overall, non-clustered indexes perform good for range based queries, and queries which rely more on `PRIMARY` keys. Updates are bad for either of them, in their own way, one can only benchmark to choose.

```

This is no way to choose a database. Over a handfull of database blogs and newsletters,
I have realized this, if you don't have any specific requirement for a fancy database,
these days, most SQL databases can scale properly, if you get the topology right. There
are plethora of extensions and plugins available.

Both of them will sometimes call you up at night. All databases suffer from replication issues,
and everything is a work-around to keep the C-A-P on.
Your qouroum can fail as much as a semi-synchronous replica going down.

I think in the end it boils down to having the expertise or willingness to work the issues.

Figma and Discord are two contrasting example, (although they are in different points of time).
Discords speciality is database migration, they can create a cloud service to do that.
Figma on the other hand scaled their SQL database and wrote some cool tools and built the ecosystem.

Your data model means shit to me. At college we thought everything should be in 4NF.
```

### Get to work

There are a couple of things that needed to be done. And I will try to break them down. The code is on [github](https://github.com/ikouchiha47/brainiac/tree/master/beetledb).

The language of choice is [Zig](https://learnxinyminutes.com/docs/zig/). And the fastest way to learn zig, is still, `writing an emulator`.

- Write a parser for a subset of `CREATE`, `SELECT` and `INSERT` (done)
- Try to just save a simple b+ tree in file.
- Use the WAL log mode from start
- Try to use LSM tree, as a part of a pluggable storage engine
- Try to implement a geo-database storage engine.

## SkipList

Well after much thought I realized, instead of going for a btree first, lets try saving a skiplist to file. A skiplist, is an in memory data format, a sorted linked list
containing levels, So starting at the highest level, imagine playing snake and ladder. Travel horizontally to find an element greater than the target value,
and then move one level down, for finer grained. Since we are skipping some elements, from finding the next greater node at the higer levels. So instead of going
through this list [1,2,3,4,5], to find 4, lets say the max_level, has 3, in its list, so you have skipped, 1 and 2.

At the base level, the probability of any node to be found is 1. And it decreases up the level. The insert implementation goes, like:
- traversing the levels to find the place where the value needs to be inserted (target node).
- finding a new level for the new node to be inserted, and pointer them to head node
- treating it like a linked list, insert the node infront of the target node.

Below is a brief implementation in python:

```python
from typing import List, Self
import random
import struct


class SkipNode:
    def __init__(self, name, value=None, max_level=16):
        self.name = name
        self.value = value
        self.level = max_level + 1
        self.forwards: List[Self | None] = [None] * (max_level + 1)

    def to_bytes(self):
        result = bytearray()
        name_encoded = self.name.encode("utf-8")
        value_encoded = 0xFFFF if self.value is None else self.value

        # I has a standard size of 4bytes , so maybe to_bytes of 4 is not needed
        result.extend(struct.pack("<I", len(self.name)))  # key length
        result.extend(name_encoded)  # key
        result.extend(struct.pack("<I", value_encoded))  # value
        result.extend(struct.pack("<I", self.level))  # level

        return result

    @classmethod
    def from_bytes(cls, b, offset=0):
        key_len = struct.unpack_from("<I", b, offset)[0]  # or <4b
        offset += 4
        key = b[offset : offset + key_len].tobytes().decode("utf-8")
        offset += key_len
        value = struct.unpack_from("<I", b, offset)[0]
        offset += 4
        lvl = struct.unpack_from("<I", b, offset)[0]

        return SkipNode(
            name=key, value=value if value != 0xFFFF else None, max_level=lvl - 1
        )


class SkipList:
    def __init__(self, max_level, probab) -> None:
        self.max_level = max_level
        self.probab = probab
        self.head = SkipNode("head", max_level=max_level)
        self.level = 0
        self.size = 0

    def _random_level(self):
        if self.size % 2 == 0:
            level = random.randint(0, self.max_level // 2)
        else:
            level = random.randint(self.max_level // 2, self.max_level)
        return level
        # level = 0
        # while random.random() < self.probab and level < self.max_level:
        #     level += 1
        # return level

    def insert(self, key, value):
        # starting from max level
        # find the position for update
        curr = self.head
        if curr is None:
            raise Exception("Empty")

        updates: List[SkipNode | None] = [None] * (self.max_level + 1)

        # iterate the head to find the levels
        # to insert the node at
        for i in range(self.level, -1, -1):
            while curr and curr.forwards[i] and curr.forwards[i].value < value:
                curr = curr.forwards[i]

            updates[i] = curr

        new_lvl = self._random_level()

        # check if lvl > self.max_levels
        # then track new lanes to create for head
        if new_lvl > self.level:
            for i in range(self.level + 1, new_lvl + 1, 1):
                updates[i] = self.head
            self.level = new_lvl


        node = SkipNode(key, value=value, max_level=new_lvl)
        # add the nodes at all levels, starting from 0
        # add the new nodes to the head node as well
        for lvl in range(new_lvl + 1):
            replacing = updates[lvl]
            if replacing is None:
                print("warning: no entry found in updates")
                continue

            node.forwards[lvl] = replacing.forwards[lvl]
            replacing.forwards[lvl] = node

        self.size += 1

        return self

    def search(self, value):
        # check at each level starting from the maximum
        curr = self.head
        for i in range(self.level, -1, -1):
            while curr and curr.forwards[i] and curr.forwards[i].value < value:
                curr = curr.forwards[i]

        if curr is None:
            return False

        # precautionary
        curr = curr.forwards[0]
        return curr is not None and curr.value == value

    def remove(self, value):
        curr = self.head
        updates: List[SkipNode | None] = [None] * (self.max_level + 1)

        for i in range(self.level, -1, -1):
            while curr and curr.forwards[i] and curr.forwards[i].value < value:
                curr = curr.forwards[i]
            updates[i] = curr

        if curr is None or (curr and curr.forwards[0]) is None:
            return False

        curr = curr.forwards[0]
        if curr and curr.value != value:
            return False

        for i in range(self.max_level, -1, -1):
            replacement = updates[i]
            if not replacement:
                continue
            if replacement.forwards[i] != curr:
                raise Exception("node_mismatch")
            replacement.forwards[i] = curr.forwards[i]

        while self.level > 0 and self.head.forwards[self.max_level] is None:
            self.level -= 1
        self.size -= 1

    def print_list(self):
        from collections import defaultdict
        import json

        result = defaultdict(list)

        for level in range(self.level, -1, -1):
            curr = self.head
            level_repr = []
            while curr:
                level_repr.append(f"{curr.name}({curr.value})")
                curr = curr.forwards[level]
            result[f"Level {level}"] = level_repr

        print(json.dumps(result))

    def first(self):
        pass


if __name__ == "__main__":
    skipnode = SkipNode(name="a", value=10)
    data = skipnode.to_bytes()

    SkipNode.from_bytes(memoryview(data))
    skplist = SkipList(max_level=5, probab=0.5)
    skplist.insert("a", 10).insert("b", 20).insert("c", 15).insert("d", 6)
    skplist.print_list()
    
    nodes: Set[SkipNode] = set()
    queue: List[SkipNode] = [skplist.head]
    
    while len(queue) > 0:
        n = queue.pop(0)
        nodes.add(n)
    
        queue.extend([fwd for fwd in n.forwards if fwd])
    
    print(skplist.level, len(nodes))
    print(skplist.search(15), skplist.search(40))
```

## How data is written in the btree in sqlite.

In `btree.c#L4267` and `btree.c#L4339`, From the comments, (operating in rollback journal mode I assume). Has 2 phases of commit:

- Journal file creation with original state of db, and saving on disk, holding locks (indicating changes not yet done)
- The paging unit gets involved in this writing to disk.
- After, flushed to disk, zero out the journal headers indicating data is succesfully written, before droping the lock

The b+tree talks to the paging layer. And the paging unit to disk.

The database has commited, only when the state on disk and in memory is the same, otherwise its dirty. 

### Data Oriented Design

Alignment and Size of a struct matters in case of struct packing. Why is u32 4bytes? Well because that 64bit processor can do efficiently,
A 64bit cpu can load 64bits of data in memory at a time. So u64 is 8bytes, and so u32 is 4bytes. Or 1 WORD.

### Why Alignment matters

- CPUs are designed to read data from memory in chunks that are aligned to their size. 
  For example, a u32 (4 bytes) is most efficiently accessed when it starts at a memory address that is a multiple of 4.
- A u64 (8 bytes) is most efficiently accessed when it starts at a memory address that is a multiple of 8.
- If data is misaligned (not on these boundaries), the CPU might need multiple memory operations to read or write the data, which can significantly slow down performance.

So, when the struct has an alignment of u32, u64, u32., with alignment as 8 bytes.

- u32, so multiples of 4. but __alignment__ needs to be 8 bytes. so, 4 extra bytes needed to pad.
- so processor can load the memory is 8byte chunks, to avoid sequential access, to figure out boundaries.

compared to a, u32, u32, u64. The processor can load 8, bytes of memory twice, to get all the data.

```zig
struct Enemies {
  color: u32,
  power: u64,
  boost: u32,
};
```

So, the above has an alignment of 8, but a size of 8x3 = 24. 

```zig
struct Enemies {
  color: u32,
  boost: u32,
  power: u64,
};
```

This way, Alignment satisfies. It's still 8, But since, the two u32s are packed together,
The procesor can read, 64bits only twice. And hence, a size `16`.

This gets worse, when we use bool to represent stuff.

```zig
struct Enemies {
  color: u32,
  boost: u32,
  power: u64,
  dead: boolean,
};
```

We have 7bytes wasted, for each object. For 100 objects, 700Bytes Wasted. Compared to:

```zig
struct Enemies {
  color: u32,
  boost: u32,
  power: u64,
};

let alive = ArrayList<Enemies>();
let dead = ArrayList<Enemies>()
```

__Why this matters?__

Because we wan't to reduce the amount of wasted bytes, so that we can fit as much data in the cache lines.

```bash
$> lscpu

Caches (sum of all):      
  L1d:                    128 KiB (4 instances)
  L1i:                    128 KiB (4 instances)
  L2:                     1 MiB (4 instances)
  L3:                     8 MiB (1 instance)
```

So if we can fit more data in that `128KiB` cache line, we have more speed.



### Other work

This are the list of other places to look at:

- [rqlite](https://github.com/rqlite/rqlite)
- [cockroach db](https://github.com/cockroachdb/cockroach/tree/master/pkg/geo)
- [rocksdb](https://github.com/facebook/rocksdb/blob/main/db/memtable.cc) (too much c, written like my mom's grocery list)
- [leveldb's](https://github.com/google/leveldb/blob/main/db/memtable.cc) implementation of above memtable
- [some person's code on building sst table](https://dev.to/justinethier/log-structured-merge-trees-1jha)
- [some comparison list for god knows what](https://github.com/facebook/rocksdb/wiki/MemTable)
