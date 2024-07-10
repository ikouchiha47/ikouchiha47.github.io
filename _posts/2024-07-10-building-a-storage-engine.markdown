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

### Other work

This are the list of other places to look at:

- [rqlite](https://github.com/rqlite/rqlite)
- [cockroach db](https://github.com/cockroachdb/cockroach/tree/master/pkg/geo)
- [rocksdb](https://github.com/facebook/rocksdb/blob/main/db/memtable.cc) (too much c, written like my mom's grocery list)
- [leveldb's](https://github.com/google/leveldb/blob/main/db/memtable.cc) implementation of above memtable
- [some person's code on building sst table](https://dev.to/justinethier/log-structured-merge-trees-1jha)
- [some comparison list for god knows what](https://github.com/facebook/rocksdb/wiki/MemTable)
