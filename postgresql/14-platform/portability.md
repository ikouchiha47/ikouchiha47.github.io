---
title: "Portability and OS Abstraction"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "14-platform"
chapter_title: "Platform Layer"
chapter_url: "/postgresql/14-platform/"
---

# Portability: Win32, Semaphore Backends, and the VFD Layer

## Summary

PostgreSQL's portability layer bridges the gap between its UNIX-native process
model and the diverse operating systems it supports. Three subsystems carry most
of the weight: the **Virtual File Descriptor (VFD)** cache that prevents
file-descriptor exhaustion, the **semaphore backends** that abstract away the
differences between POSIX, System V, and Win32 synchronization primitives, and
the **Win32 compatibility shims** that emulate `fork()`, POSIX signals, and
UNIX filesystem semantics on Windows.

## Overview

PostgreSQL was born on UNIX and its architecture reflects that heritage:
multi-process (not multi-threaded), `fork()`-based, reliant on POSIX signals
for inter-process communication, and assuming a filesystem that supports
`fsync()`, `fdatasync()`, and file-descriptor inheritance across `fork()`.

Porting this to Windows, and even accommodating differences between Linux,
FreeBSD, and macOS, requires a substantial compatibility layer. The key
challenges are:

1. **File descriptor limits.** UNIX systems typically limit processes to 1024
   open FDs (or a configurable `ulimit`). A busy backend opening base tables,
   indexes, toast tables, sort temp files, and WAL segments can easily exceed
   this.

2. **Semaphore flavor wars.** POSIX unnamed semaphores, POSIX named semaphores,
   System V semaphores, and Win32 Event objects all have different creation,
   limits, and cleanup semantics.

3. **Windows differences.** No `fork()`, no POSIX signals, different path
   separators, different `stat()` behavior, different socket APIs, and
   case-insensitive filenames.

## Key Source Files

| File | Role |
|------|------|
| `src/backend/storage/file/fd.c` | VFD cache: LRU pool of virtual file descriptors |
| `src/backend/port/posix_sema.c` | POSIX semaphore backend |
| `src/backend/port/sysv_sema.c` | System V semaphore backend |
| `src/backend/port/win32_sema.c` | Win32 Event object semaphore backend |
| `src/backend/port/sysv_shmem.c` | System V shared memory |
| `src/backend/port/win32_shmem.c` | Win32 shared memory via file mappings |
| `src/include/port/win32_port.h` | Windows compatibility macros and includes |
| `src/include/port/win32.h` | Win32 signal emulation declarations |
| `src/port/kill.c` | `kill()` emulation for Windows |
| `src/port/open.c` | `open()` wrapper for Windows share modes |
| `src/port/dirmod.c` | Directory operations, `rename()` shims |
| `src/include/port/darwin.h` | macOS-specific defines |
| `src/include/port/linux.h` | Linux-specific defines |
| `src/include/port/freebsd.h` | FreeBSD-specific defines |

## How It Works

### The Virtual File Descriptor (VFD) Cache

The VFD layer interposes between PostgreSQL code and the OS `open()` /
`close()` system calls. Every file opened through VFD APIs receives a `File`
handle (an integer index into the `VfdCache` array) rather than a raw OS file
descriptor. The VFD layer manages an LRU pool of actual OS file descriptors,
transparently opening and closing them as needed.

```c
typedef struct vfd
{
    int         fd;               /* Current OS FD, or VFD_CLOSED */
    unsigned short fdstate;       /* Bitflags: DELETE_AT_CLOSE, etc. */
    ResourceOwner resowner;       /* For automatic cleanup */
    File        nextFree;         /* Free-list link */
    File        lruMoreRecently;  /* Doubly-linked LRU list */
    File        lruLessRecently;
    pgoff_t     fileSize;         /* Tracked for temp files */
    char       *fileName;         /* Path, for reopening */
    int         fileFlags;        /* open(2) flags, for reopening */
    mode_t      fileMode;         /* mode, for reopening */
} Vfd;
```

The critical insight is that `fileName`, `fileFlags`, and `fileMode` are
preserved so that a VFD whose OS descriptor has been reclaimed can be
**transparently reopened** when next accessed:

```
  Backend calls FileRead(vfd, buf, len)
       |
       v
  Is VfdCache[vfd].fd == VFD_CLOSED?
       |                    |
      No                   Yes
       |                    |
       v                    v
  Use fd directly      Need to reopen:
                        1. If nfile >= max_safe_fds:
                           evict LRU VFD (close its OS fd)
                        2. fd = open(fileName, fileFlags, fileMode)
                        3. Insert into LRU as most-recently-used
                        4. Now use fd
```

**FD budget management.** The VFD layer tracks three categories of file
descriptors:

```
  max_safe_fds  (set by postmaster at startup via getrlimit)
       |
       +--- VFD pool (nfile): relation files, temp files, WAL segments
       +--- Counted "external" FDs: ReserveExternalFD() / AcquireExternalFD()
       +--- NUM_RESERVED_FDS (10): headroom for system(), dynamic loader, etc.
```

The `set_max_safe_fds()` function probes the actual FD limit at startup by
repeatedly calling `open()` until it fails, then subtracts the reserved count.

### Semaphore Backends

PostgreSQL uses semaphores as the "slow path" for its locking infrastructure.
When a lightweight lock cannot be acquired on the fast path (via atomics), the
backend sleeps on a per-process semaphore. Three implementations exist:

| Backend | Platform | Mechanism | Limit |
|---------|----------|-----------|-------|
| `posix_sema.c` | Linux, macOS, FreeBSD | `sem_init()` (unnamed, in shmem) | Per-process: typically 256+ |
| `sysv_sema.c` | Older UNIX, fallback | `semget()` / `semop()` | System-wide: often 128 sets of 250 |
| `win32_sema.c` | Windows | `CreateEvent()` + `SetEvent()` / `WaitForSingleObject()` | Effectively unlimited |

**POSIX semaphores** are preferred on modern systems. They are allocated in
shared memory (using `sem_init()` with `pshared=1`) so they survive across
`fork()`. Each backend gets one semaphore for sleeping on locks.

**System V semaphores** are a legacy fallback. They are allocated in sets
(arrays), and PostgreSQL must carefully manage creation and cleanup because SysV
semaphores persist in the kernel even after the creating process exits. The
postmaster registers `on_shmem_exit` hooks to clean them up, and
`IpcSemaphoreKill()` removes individual sets.

**Win32** uses auto-reset Event objects. `PGSemaphoreCreate()` calls
`CreateEvent()`, `PGSemaphoreUnlock()` calls `SetEvent()`, and
`PGSemaphoreTimedLock()` calls `WaitForSingleObjectEx()`. This integrates
with the Win32 `EXEC_BACKEND` model where processes are created with
`CreateProcess()` rather than `fork()`.

### Win32 Compatibility Layer

Windows support requires extensive shimming. The major areas:

**Process creation.** Windows has no `fork()`. PostgreSQL uses `EXEC_BACKEND`
mode, where the postmaster calls `CreateProcess()` to spawn each backend as a
new process that re-executes `postgres.exe` with special arguments. The child
process re-attaches to shared memory and reconstructs its state from
information passed via the command line and inherited handles.

**Signal emulation.** POSIX signals (`SIGHUP`, `SIGTERM`, `SIGINT`, etc.) do
not exist on Windows. PostgreSQL emulates them using a per-process signal-
handling thread and event objects:

```
win32_port.h redefines:
  kill(pid, sig)  -->  pgkill(pid, sig)

pgkill() on Windows:
  1. Open the target process's named pipe or event
  2. Write the signal number
  3. The target's signal-handler thread reads it
  4. Dispatches to the registered handler function
```

**File operations.** Windows requires several wrappers:

| POSIX | Windows issue | PostgreSQL workaround |
|-------|--------------|----------------------|
| `open()` | No `O_DSYNC`, sharing modes differ | `pgwin32_open()` with `FILE_SHARE_*` flags |
| `rename()` | Fails if destination exists | `pgrename()` with retry loop |
| `unlink()` | Fails on open files | Mark for delete-on-close |
| `fsync()` | `_commit()` behavior differs | `pg_fsync()` abstraction |
| `ftruncate()` | `_chsize_s()` semantics | Wrapped in `src/port/` |
| `mkdir(path, mode)` | No mode argument | `#define mkdir(a,b) mkdir(a)` |
| `stat()` | Different struct layout | Redefined in `win32_port.h` |

**Socket operations.** Winsock requires `WSAStartup()` initialization and uses
`SOCKET` handles rather than file descriptors. PostgreSQL's `pgsocket` type and
the `pgwin32_*` socket wrappers handle the translation.

### Platform Detection Headers

Each supported OS has a header in `src/include/port/` that defines
platform-specific quirks:

```c
/* linux.h */
#define DEFAULT_FILE_EXTEND_METHOD FILE_EXTEND_METHOD_FALLOCATE

/* darwin.h */
/* macOS-specific: shared memory and semaphore defaults */

/* freebsd.h */
/* FreeBSD-specific: POSIX semaphore config */

/* win32_port.h */
/* Massive: redefines half of POSIX for Windows */
```

These headers are included early in the build, typically via `c.h` or
`postgres.h`, and set preprocessor defines that the rest of the code checks.

### Data Sync Methods

PostgreSQL must ensure data durability via `fsync()` or equivalent. The
`recovery_init_sync_method` GUC and related code handle platform differences:

```
  pg_fsync(fd)
       |
       +--- Linux: fdatasync(fd)  [if available, preferred over fsync]
       +--- macOS: fcntl(fd, F_FULLFSYNC)  [ensures controller cache flush]
       +--- Windows: _commit(fd) or FlushFileBuffers()
       +--- FreeBSD: fsync(fd)

  pg_flush_data(fd, offset, nbytes)
       |
       +--- Linux: sync_file_range(fd, offset, nbytes, WRITE)
       +--- Others: msync() or posix_fadvise(DONTNEED) as fallback
```

The `F_FULLFSYNC` on macOS is particularly important: regular `fsync()` on
macOS only flushes to the disk controller's volatile write cache, not to
persistent media. `F_FULLFSYNC` issues a cache-flush command to the drive.

## Key Data Structures

### VFD Cache Layout

```
VfdCache[] (dynamically grown array)

Index 0:  Sentinel / LRU list head (not a real file)
           lruMoreRecently --> most recently used VFD
           lruLessRecently --> least recently used VFD

Index 1..N:  Actual VFD entries
  +--------+----+----------+---------+--------+-------+
  | fd     | st | fileName | flags   | lruMR  | lruLR |
  +--------+----+----------+---------+--------+-------+
  | 17     | 0  | base/... | O_RDWR  |  <---> |  VFD  |
  | CLOSED | 0  | base/... | O_RDWR  |  (not in LRU)  |
  | 23     | 1  | pg_wal/  | O_RDWR  |  <---> |  VFD  |
  +--------+----+----------+---------+--------+-------+

Free list: nextFree links chain unused VFD slots
LRU list:  doubly-linked through lruMoreRecently/lruLessRecently
           Only VFDs with fd != VFD_CLOSED are in the LRU
```

### Semaphore Backend Selection

```
  Configure / meson build
       |
       +--- HAVE_POSIX_SEMAPHORES --> posix_sema.c (preferred)
       +--- !HAVE_POSIX_SEMAPHORES
       |       +--- USE_SYSV_SEMAPHORES --> sysv_sema.c
       |       +--- WIN32 --> win32_sema.c
       |
       v
  PGSemaphore (opaque type)
       |
       +--- PGSemaphoreCreate()   : allocate in shared memory
       +--- PGSemaphoreReset()    : set to zero
       +--- PGSemaphoreLock()     : decrement / wait
       +--- PGSemaphoreUnlock()   : increment / signal
       +--- PGSemaphoreTimedLock(): wait with timeout
```

### Win32 Process Model vs UNIX

```
  UNIX (default):                 Windows (EXEC_BACKEND):
  ==============                  =======================

  postmaster                      postmaster
       |                               |
       | fork()                        | CreateProcess("postgres.exe",
       v                               |   "--fork=backend", ...)
  child inherits:                      v
  - shared memory mapping         child process:
  - file descriptors               1. Parse command line
  - signal handlers                 2. Re-attach to shared memory
  - all process state                  (via named file mapping)
                                    3. Reconstruct backend state
                                    4. Resume execution
```

## Connections

- **Chapter 4 (Buffer Manager):** Every relation file access goes through the VFD layer. When the buffer manager reads a page, it calls `FileRead()` on a VFD, which may transparently reopen the file if its OS descriptor was reclaimed.
- **Chapter 6 (Lock Manager):** The semaphore backends provide the sleep/wake mechanism for `ProcSleep()` and `ProcWakeup()`. When an LWLock cannot be acquired via the atomic fast path, the backend calls `PGSemaphoreLock()` on its per-process semaphore.
- **Chapter 5 (WAL):** WAL segment files are opened through the VFD layer. The `pg_fsync()` / `pg_fdatasync()` wrappers ensure platform-correct durability guarantees for WAL flushes.
- **Chapter 12 (Shared Memory):** On UNIX, shared memory is inherited via `fork()`. On Windows, `win32_shmem.c` uses `CreateFileMapping()` / `MapViewOfFile()` to create a named mapping that child processes can attach to.
- **Chapter 14 (this chapter), AIO:** The AIO worker method's file-reopening mechanism depends on the VFD layer storing `fileName` and `fileFlags`, since worker processes need to open their own file descriptors for I/O targets.
