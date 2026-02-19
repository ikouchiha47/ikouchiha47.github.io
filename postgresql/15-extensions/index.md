---
title: "Extensions"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "15-extensions"
chapter_title: "Extensions"
is_chapter_index: true
---

# Chapter 15: Extensions

> *PostgreSQL's extension architecture transforms the database from a fixed application into a programmable platform -- every hook, callback API, and worker slot is a seam where external code can alter behavior without touching a single line of core source.*

## Why This Matters

Most databases are closed systems. You can configure them, but you cannot change how the planner costs a join, how the executor runs a scan, or how authentication validates a password. PostgreSQL is different. Through a combination of global function-pointer hooks, pluggable access method APIs, background worker slots, and the Foreign Data Wrapper protocol, external shared libraries can intercept, replace, or extend nearly every stage of query processing and server operation.

Understanding these extension points is essential for three audiences. Extension authors need to know which callbacks exist and how to register them safely. DBAs evaluating extensions (pg_stat_statements, timescaledb, citus, postgis) need to understand what those extensions are actually doing to the server process. And core hackers proposing new hooks need to see the existing patterns and their trade-offs.

This chapter covers the four major extension mechanisms: **hooks** (function pointers that intercept planner, executor, and authentication paths), **custom access methods** (the Table AM and Index AM callback structs that let you replace heap storage or btree indexing), **background workers** (long-running processes forked by the postmaster that can run arbitrary code), and **Foreign Data Wrappers** (the full planning-through-execution callback protocol for accessing external data sources as if they were local tables).

## Chapter Map

| Topic | File | What You Will Learn |
|-------|------|---------------------|
| Hooks | [hooks.md](hooks.md) | How `planner_hook`, `ExecutorStart_hook`, `ClientAuthentication_hook`, and dozens of other global function pointers let extensions intercept core code paths |
| Custom Access Methods | [custom-access-methods.md](custom-access-methods.md) | The `TableAmRoutine` and `IndexAmRoutine` callback structs that define the contract between the executor and pluggable storage engines |
| Background Workers | [background-workers.md](background-workers.md) | How to register, start, monitor, and terminate background worker processes using the `BackgroundWorker` struct and the postmaster's worker management slots |
| Foreign Data Wrappers | [fdw.md](fdw.md) | The `FdwRoutine` callback protocol covering planning, scanning, modification, and parallel execution of foreign tables |

## Extension Loading: The Entry Point

Every PostgreSQL extension begins life as a shared library (`.so` / `.dll`) loaded into the server process. The loading mechanism and initialization protocol are the same regardless of whether the extension installs hooks, access methods, background workers, or FDW handlers.

### The _PG_init Contract

When PostgreSQL loads a shared library, it looks for and calls a function named `_PG_init`:

```c
/* src/include/fmgr.h */
extern PGDLLEXPORT void _PG_init(void);
```

This is where extensions perform all setup: installing hook functions, registering background workers, defining custom GUCs, and requesting shared memory. The function runs exactly once per library load, in the postmaster process (for `shared_preload_libraries`) or in a backend process (for `session_preload_libraries` or `LOAD`).

### Library Loading Paths

```
                    +--------------------------+
                    |   postgresql.conf        |
                    |                          |
                    |  shared_preload_libraries|----> Loaded at postmaster start
                    |  session_preload_libraries|---> Loaded at session start
                    |  local_preload_libraries |----> Loaded at session start
                    +--------------------------+
                              |
                              v
                    +--------------------------+
                    |  process_shared_preload_ |
                    |  libraries()             |
                    |                          |
                    |  For each library:       |
                    |    dlopen(libname)        |
                    |    dlsym("_PG_init")     |
                    |    _PG_init()            |
                    +--------------------------+
```

The critical distinction: only `shared_preload_libraries` runs in the postmaster before any backends are forked. This is the only path that allows:

- Registering background workers (they need postmaster to fork them)
- Requesting shared memory via `shmem_request_hook`
- Installing hooks that must be active for all sessions

```c
/* src/include/miscadmin.h */
extern PGDLLIMPORT bool process_shared_preload_libraries_in_progress;
extern PGDLLIMPORT bool process_shared_preload_libraries_done;

typedef void (*shmem_request_hook_type) (void);
extern PGDLLIMPORT shmem_request_hook_type shmem_request_hook;
```

### A Minimal Extension Skeleton

```c
/* myext.c -- minimal extension that installs a planner hook */

#include "postgres.h"
#include "fmgr.h"
#include "optimizer/planner.h"

PG_MODULE_MAGIC;

static planner_hook_type prev_planner_hook = NULL;

static PlannedStmt *
my_planner(Query *parse, const char *query_string,
           int cursorOptions, ParamListInfo boundParams,
           ExplainState *es)
{
    /* Pre-planning logic here */

    if (prev_planner_hook)
        return prev_planner_hook(parse, query_string,
                                 cursorOptions, boundParams, es);
    else
        return standard_planner(parse, query_string,
                                cursorOptions, boundParams, es);
}

void
_PG_init(void)
{
    prev_planner_hook = planner_hook;
    planner_hook = my_planner;
}
```

The pattern of saving the previous hook value and chaining to it (or falling back to the `standard_*` function) is universal across all PostgreSQL hooks. It allows multiple extensions to coexist on the same hook point.

## The Extension Control File

Beyond the C shared library, PostgreSQL's `CREATE EXTENSION` system uses a `.control` file to declare metadata and a SQL script to create the extension's database objects:

```
# myext.control
comment = 'My extension description'
default_version = '1.0'
module_pathname = '$libdir/myext'
relocatable = true
```

This infrastructure (managed by `src/backend/commands/extension.c`) handles versioning, upgrade paths, and dependency tracking -- but the actual power of extensions comes from the C-level APIs described in the following pages.

## Connections to Other Chapters

| Chapter | Connection |
|---------|-----------|
| [Chapter 7: Query Optimizer](../07-query-optimizer/) | Planner hooks intercept the optimization pipeline; custom access methods provide cost estimates via their callback APIs |
| [Chapter 8: Executor](../08-executor/) | Executor hooks wrap every stage from `ExecutorStart` through `ExecutorEnd`; table and index AMs provide the scan/modify callbacks the executor calls |
| [Chapter 2: Access Methods](../02-access-methods/) | Custom index and table AMs extend the same framework that implements btree, hash, GiST, GIN, and the heap |
| [Chapter 11: IPC](../11-ipc/) | Background workers use shared memory and the latch/signal infrastructure for coordination with backends |
| [Chapter 0: Architecture](../00-architecture/) | Background workers are full server processes forked by the postmaster, following the same lifecycle as regular backends |
