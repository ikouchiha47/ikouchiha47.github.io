---
active: false
layout: post
title: "Supercharge a platform backed by sqlite"
subtitle: "Partition, cleanup & backup your sqlite database"
description: "With better defaults and some tooling around sqlite can work really well."
date: 2024-12-16 21:00:00
background: 'blue'
---

# Epilogue

Sqlite has come a long way. Its an embedded database, which mean you don't need to
maintain any server client architecture.

Over the years, the addition of `WAL` mode, with introduction of `BEGIN IMMEDIATE`,
and other pragma directives.

There have been some work on sqlite derivatives. like `rqlite`, which is tries to
be distributed. The selling point is:

```log
It's ideal as a lightweight, distributed relational data store for
both developers and operators. 
Think Consul or etcd, but with relational modeling available.
```

There has been a mozilla backed/sponsored project called `sqlite-vec` which uses sqlite
for vector search. [sqlite-vec](https://github.com/asg017/sqlite-vec)

The goal here is to solve more of a infrastructural setup with sqlite.

# Structure of a sqlite file.

In our previous blog, we tried to understand quite a lot about indexing strategies,
referencing sqlite codebase for examples. 

Before going into the easy part, we will do a quick shallow dive, 
on how the sqlite file looks like, for sake of coolness. You are free to skip it.

We will need to create a sqlite file, and use hexedit to see what it looks
like under the hood.

```shell
sqlite3 test.sqlite3
```

```sql
create table users (id integer primary key autoincrement, email varchar(255) not null);
.quit
```

`hexedit test.sqlite`

Looks something like this:

```
00000000   53 51 4C 69  74 65 20 66  6F 72 6D 61  74 20 33 00  10 00 01 01  SQLite format 3.....
00000014   00 40 20 20  00 00 00 01  00 00 00 03  00 00 00 00  00 00 00 00  .@  ................
00000028   00 00 00 01  00 00 00 04  00 00 00 00  00 00 00 00  00 00 00 01  ....................
0000003C   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
00000050   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 01  00 2E 7A 71  ..................zq
00000064   0D 00 00 00  02 0F 40 00  0F 92 0F 40  00 00 00 00  00 00 00 00  ......@....@........
00000078   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
0000008C   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
000000A0   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
000000B4   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
000000C8   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
000000DC   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
000000F0   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
00000104   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
00000118   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
0000012C   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
00000140   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
00000154   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
00000168   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
0000017C   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
00000F14   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ............................................
00000F40   50 02 06 17  2B 2B 01 59  74 61 62 6C  65 73 71 6C  69 74 65 5F  73 65 71 75  65 6E 63 65  73 71 6C 69  74 65 5F 73  65 71 75 65  6E 63 65 03  P...++.Ytablesqlite_sequencesqlite_sequence.
00000F6C   43 52 45 41  54 45 20 54  41 42 4C 45  20 73 71 6C  69 74 65 5F  73 65 71 75  65 6E 63 65  28 6E 61 6D  65 2C 73 65  71 29 6C 01  07 17 17 17  CREATE TABLE sqlite_sequence(name,seq)l.....
00000F98   01 81 37 74  61 62 6C 65  75 73 65 72  73 75 73 65  72 73 02 43  52 45 41 54  45 20 54 41  42 4C 45 20  75 73 65 72  73 28 69 64  20 69 6E 74  ..7tableusersusers.CREATE TABLE users(id int
00000FC4   65 67 65 72  20 70 72 69  6D 61 72 79  20 6B 65 79  20 61 75 74  6F 69 6E 63  72 65 6D 65  6E 74 2C 20  65 6D 61 69  6C 20 76 61  72 63 68 61  eger primary key autoincrement, email varcha
00000FF0   72 28 32 35  35 29 20 6E  6F 74 20 6E  75 6C 6C 29  0D 00 00 00  00 10 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  r(255) not null)............................
0000101C   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ............................................
00001048   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ............................................
00001074   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ............................................
```

```sql
sqlite> insert into users(email) values('a@b.c'),('c@d.e');
sqlite> .quit
```

```logs
00001FCC   00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
00001FE0   00 00 00 00  00 00 00 00  00 00 00 00  08 02 03 00  17 63 40 64  .................c@d
00001FF4   2E 65 08 01  03 00 17 61  40 62 2E 63  0D 00 00 00  01 0F F5 00  .e.....a@b.c........
00002008   0F F5 00 00  00 00 00 00  00 00 00 00  00 00 00 00  00 00 00 00  ....................
```

Now on `hexedit`, Press `Ctrl+Space` to set mark, and use the arrow keys.
It should highlight the text corresponding to the hex codes selected, and
refer to the [docs](https://sqlite.org/fileformat2.html#the_database_header)

A SQLite database file is organized into a series of fixed-size pages. 
Each page serves as a fundamental unit of storage, typically **1024 bytes** (though other sizes like 4096 bytes are possible). 

The structure comprises:

- **Database Header (First 100 Bytes):** Contains metadata about the database.
- **Pages (Subsequent Blocks):** Each page can be a B-Tree node (table/index), freelist, or other special-purpose pages.

#### Database Header

The file starts with a Database Header, which reads to `SQLite format 3 null termination.`
Sometimes also called a magic number. 
Pretty common technique used. 

- A total of 100bytes is used out of which, the first `16`, makes up the text.

- **Following Bytes (Offset `0x10` onwards):**  
  These bytes encode critical metadata such as:
  - **Page Size:** Specifies the size of each page (commonly 1024 bytes).
  - **Write/Read Version Numbers:** Indicate the file format version.
  - **Other Parameters:** Control aspects like payload fractions, file change counters, etc.

#### Pages and Their Structure

After the 100-byte header, the file is segmented into pages. Each page starts at a multiple of the page size (e.g., `0x400` for `1024-byte pages`).

- **Empty Areas (`000000A0` to `00000F28`):**  
  These zeroed bytes represent **unused or free space** within the database. Reasons include:
  - **Freelist Pages:** Previously used pages that are now available for reuse.
  - **Reserved Space:** Anticipated future data insertions.
  - **Database Shrinking:** Data deletions may leave pages empty.

- **Offset `00000F40` to `00001074`:**  
  This region contains human-readable SQL statements like `CREATE TABLE` commands. Here's how SQLite organizes and accesses this information:

  1. **`sqlite_master` Table:**
     - Located on **Page 1**, which is the root B-Tree page for the schema.
     - Stores metadata about all database objects (tables, indexes, triggers, views).

  2. **B-Tree Structure:**
     - **Page Header:** Contains information like the number of cells (entries) and pointers to cell data.
     - **Cell Pointer Array:** An array of offsets pointing to the actual data (cells) within the page.

  3. **Cells:**
     - Each cell contains a record with fields such as `type`, `name`, `tbl_name`, `rootpage`, and `sql`.
     - For example, the `CREATE TABLE` statements you see are stored in the `sql` field of `sqlite_master`.

Key Components:

1. **Page Numbering:**
   - Pages are numbered starting from **1** (with **Page 1** being the schema root).
   - The **database header** contains the total number of pages and other relevant information.

2. **Page Headers:**
   - Each page begins with a header that specifies:
     - **Page Type:** Table B-Tree, Index B-Tree, freelist, etc.
     - **Number of Cells:** How many records are on the page.
     - **Cell Pointer Array Offset:** Where the array of cell pointers starts.

   **Example Insight:**

   ```log
   00001FE0   00 00 00 00  00 00 00 00  00 00 00 00  08 02 03 00  17 63 40 64  .................c@d
   ```

   - This could represent a page header with specific flags or pointers, indicating the type and structure of the page.

3. **Cell Pointers:**
   - After the page header, there's an array of **cell pointers**.
   - Each pointer is an **offset** from the start of the page to where the actual cell (record) data begins.

4. **Record Headers and Payloads:**
   - **Record Header:** Specifies the number of columns, types, and sizes.
   - **Payload:** Contains the actual data (e.g., row values).

5. **Referencing Other Pages:**
   - **Root Pages:** The `sqlite_master` table points to root pages of other tables and indexes.
   - **Traversing B-Trees:** For tables with multiple pages, SQLite traverses the B-Tree to locate specific records.

### How does it locate the data.

Given the structured layout, here's how SQLite efficiently locates any data segment:

- Understand the `Page size`, `total pages` in the file from the database header
- Identify the `Page Type`, B-Tree, Overflow etc. from `Page header`
- Use the `Cell Pointers` array to find where each record starts within the page
- The Cell Pointer values are used to locate the start of the records
- Use the same struct packing to decode the value, considering overflow pages

Here’s a simplified diagram to visualize the process:

```txt
[ Database Header (0x00000000 - 0x00000063) ]
                |
                v
        [ Page 1: sqlite_master ]
                |
                v
    [ Root Page for 'users' Table (e.g., Page 5) ]
                |
                v
    [ B-Tree Pages for 'users' Data ]
                |
                v
        [ Individual Records ]
```

1. **Schema Definition:**
   - In the hex dump, the `CREATE TABLE users(...)` statement is found around offset `00000F98`. This is part of the `sqlite_master` table on **Page 1**.
   - The `sqlite_master` entry for `users` includes a `rootpage` value, indicating where the `users` table's B-Tree starts.

2. **Locating the `users` B-Tree:**
   - Suppose the `rootpage` for `users` is **Page 2**.
   - SQLite calculates the byte offset for **Page 2**:  
     `Offset = (Page Number - 1) * Page Size`  
     If Page Size is 1024 bytes:  
     `Offset = (2 - 1) * 1024 = 1024 bytes = 0x400`

3. **Accessing Page 2:**
   - SQLite jumps to `0x0400` in the file.
   - Reads the **page header** to understand how many cells (records) are present and where each cell starts.

4. **Reading Records:**
   - For each cell pointer, SQLite jumps to the specified offset within Page 2.
   - Decodes the **record header** and **payload** to retrieve the actual row data (e.g., `id`, `email` fields).

5. **Navigating Through Records:**
   - If the table spans multiple pages, SQLite traverses the B-Tree structure, accessing additional pages as needed to retrieve all records.

## Performance 101

The above has little to do with what we are trying to do. There are few common optimizations
that can be done. 

```
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA temp_store=MEMORY;
PRAGMA cache_size=-2000;
PRAGMA busy_timeout=5000;
PRAGMA mmap_size = 30000000000;
PRAGMA journal_size_limit = 104857600;
PRAGMA threads = 10
PRAGMA analysis_limit=1000;
```

- Set the journal mode to WAL. This will allow multiple readers to read independently
  - however only one writer can write to the WAL file at a time, it does not block readers.
- The NORMAL mode means SQLite syncs the WAL file during checkpoints but doesn't sync after every write operation.
- Given the amount of available RAM these days, SQLite can store temporary tables and other temporary data (e.g., sorting, indexes) in memory rather than on disk.
- Increase the database page cache size can certainly help reducing disk I/O
- The WAL log size, if kept unchecked, can grow to large. So once a WAL log, exceeds a given size limit. SQL triggers a checkpoint merge.
- Limits the size of the WAL journal file to 100 MB (104857600 bytes).
- mmap is memory mapping, essentially loading the file/pages into the process'es virtual memory. This way it saves a lot of disk i/o.
- busy timeout, is essetially to allow queries to timeout, rather than holding up the resources, waiting for locks etc.

Another performance improvemen can be done with the use of internal analyis tables, which can be generated using a PRAGMA.

> The ANALYZE command gathers statistics about tables and indices and stores the collected information in internal tables of the database where the query optimizer can access the information and use it to help make better query planning choices.

More on [Analyze, here](https://www.sqlite.org/lang_analyze.html) .

By default we have `sqlite_stats1`, and there is `sqlite_stats4`, which uses more information. The suggested improvement says.

1. Applications that use long-lived database connections should run "PRAGMA optimize=0x10002;" when the connection is first opened, 
and then also run "PRAGMA optimize;" periodically, perhaps once per day, or more if the database is evolving rapidly.

2. All applications should run "PRAGMA optimize;" after a schema change, especially after one or more CREATE INDEX statements. 


## DB management tools
