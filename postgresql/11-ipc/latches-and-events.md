---
title: "Latches and Wait Events"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/postgresql-internals/"
chapter: "11-ipc"
chapter_title: "IPC"
chapter_url: "/postgresql/11-ipc/"
---

# Latches and Wait Events

Processes in PostgreSQL frequently need to sleep until something happens: a lock
becomes available, WAL is flushed, a client sends data, or the postmaster dies.
The **Latch** abstraction provides a reliable, portable sleep/wake mechanism that
avoids the classic race conditions of `signal` + `poll()`. The **WaitEventSet**
layer extends this to multiplex waiting on latches, sockets, timeouts, and
postmaster death in a single call.

---

## Overview

A latch is a boolean flag with three operations:

- **SetLatch** -- Sets the flag and wakes up the sleeping process.
- **ResetLatch** -- Clears the flag.
- **WaitLatch** -- Sleeps until the flag is set (or a timeout expires, or the
  postmaster dies).

The critical property: `SetLatch` is safe to call from a signal handler, and
there is no window between checking for work and sleeping where a signal could
be lost.

Under the hood, `WaitLatch` delegates to `WaitEventSetWait`, which uses the
best available OS primitive: `epoll` on Linux, `kqueue` on macOS/BSD, `poll`
as a portable fallback, or native events on Windows.

---

## Key Source Files

| File | Role |
|------|------|
| `src/include/storage/latch.h` | Latch struct definition, API prototypes |
| `src/backend/storage/ipc/latch.c` | `InitLatch`, `SetLatch`, `ResetLatch`, `WaitLatch` |
| `src/include/storage/waiteventset.h` | `WaitEventSet`, `WaitEvent`, `WL_*` flags |
| `src/backend/storage/ipc/waiteventset.c` | Platform-specific wait implementations |
| `src/backend/storage/ipc/pmsignal.c` | Postmaster death detection |
| `src/backend/storage/ipc/procsignal.c` | Inter-backend signaling via `SIGUSR1` / `SIGURG` |

---

## How It Works

### The Latch Struct

```c
/* src/include/storage/latch.h */
typedef struct Latch
{
    sig_atomic_t is_set;           /* The boolean flag */
    sig_atomic_t maybe_sleeping;   /* Hint: owner might be in WaitEventSetWait */
    bool         is_shared;        /* Shared (in shmem) or local? */
    int          owner_pid;        /* PID of the process that owns this latch */
} Latch;
```

Every `PGPROC` contains a `procLatch` -- a shared latch that any process can set
to wake that backend. Local latches (created with `InitLatch`) can only be set
from within the same process (typically from signal handlers).

### The Correct Wait Loop

The latch header documents two safe patterns. The canonical one:

```c
for (;;)
{
    ResetLatch(MyLatch);

    if (got_work)
        DoWork();

    WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
              timeout_ms, WAIT_EVENT_FOO);
}
```

The key rule: **reset before checking for work**. If you check first and then
reset, a `SetLatch` arriving between the check and the reset will be lost,
causing the process to sleep when it should be working.

### SetLatch Internals

`SetLatch` does the following (simplified):

```
1.  Write is_set = true    (with memory barrier)
2.  Read maybe_sleeping
3.  If maybe_sleeping:
        Send SIGURG to owner_pid   (Unix)
        -- or --
        SetEvent(latch->event)     (Windows)
```

The `maybe_sleeping` flag is an optimization. If the owner is not in
`WaitEventSetWait`, there is no need to send a signal. This avoids the overhead
of `kill()` in the common case where the target is already running.

On Unix, `SIGURG` is the signal used to wake processes. It was chosen because it
has no default action (unlike `SIGUSR1`/`SIGUSR2`, which PostgreSQL uses for other
purposes) and does not interfere with `poll()`/`select()` on all platforms.

### WaitEventSet: The Multiplexing Layer

`WaitLatch` is a convenience wrapper around `WaitEventSet`. For long-lived wait
loops, creating a `WaitEventSet` directly is more efficient because it avoids
repeated setup of the OS-level monitoring structures.

```c
/* Typical pattern for a long-lived WaitEventSet */
WaitEventSet *set = CreateWaitEventSet(CurrentResourceOwner, 3);
AddWaitEventToSet(set, WL_LATCH_SET, PGINVALID_SOCKET, MyLatch, NULL);
AddWaitEventToSet(set, WL_SOCKET_READABLE, client_sock, NULL, NULL);
AddWaitEventToSet(set, WL_EXIT_ON_PM_DEATH, PGINVALID_SOCKET, NULL, NULL);

for (;;)
{
    WaitEvent events[3];
    int nevents = WaitEventSetWait(set, timeout, events, 3, WAIT_EVENT_CLIENT_READ);

    for (int i = 0; i < nevents; i++)
    {
        if (events[i].events & WL_LATCH_SET)
        {
            ResetLatch(MyLatch);
            HandleLatchWakeup();
        }
        if (events[i].events & WL_SOCKET_READABLE)
            HandleClientData();
    }
}
```

### WL_* Event Flags

| Flag | Meaning |
|------|---------|
| `WL_LATCH_SET` | The associated latch has been set |
| `WL_SOCKET_READABLE` | Data is available to read on the socket |
| `WL_SOCKET_WRITEABLE` | The socket is ready for writing |
| `WL_SOCKET_CONNECTED` | An async connect has completed |
| `WL_SOCKET_CLOSED` | The remote end has closed the connection |
| `WL_SOCKET_ACCEPT` | A new connection is pending on a listening socket |
| `WL_TIMEOUT` | The specified timeout has elapsed |
| `WL_POSTMASTER_DEATH` | The postmaster process has died (returns event) |
| `WL_EXIT_ON_PM_DEATH` | The postmaster has died (calls `proc_exit` immediately) |

---

## Platform Implementations

`WaitEventSetWait` dispatches to one of several platform-specific implementations:

### epoll (Linux)

```
epoll_create1()          -- once per WaitEventSet
epoll_ctl(EPOLL_CTL_ADD) -- for each event source
epoll_pwait2()           -- blocks until event fires
```

Latch wakeups arrive via a `signalfd` descriptor that monitors `SIGURG`.
This avoids the self-pipe trick entirely. The signal is kept blocked in the
process signal mask, and `signalfd` delivers it as a readable file descriptor
that `epoll` can monitor.

### kqueue (macOS, FreeBSD)

```
kqueue()                 -- once per WaitEventSet
kevent(EV_ADD)           -- for each event source
kevent()                 -- blocks until event fires
```

Latch wakeups use `EVFILT_SIGNAL` for `SIGURG`, which is kqueue's native signal
monitoring. No self-pipe needed.

### poll (Portable Fallback)

```
poll()                   -- blocks on file descriptors
```

Uses the **self-pipe trick**: a pipe is created at startup, and the `SIGURG`
handler writes a byte to the pipe's write end. The pipe's read end is added to
the `poll()` set. When `SIGURG` arrives, the write wakes `poll()` from sleep.

After `poll()` returns, the pipe is drained.

### Windows

Uses `WaitForMultipleObjects()` on Windows event objects. Each latch has a
dedicated `HANDLE` created by `CreateEvent()`.

---

## Key Data Structures

### WaitEvent

```c
/* src/include/storage/waiteventset.h */
typedef struct WaitEvent
{
    int       pos;          /* Position in the WaitEventSet */
    uint32    events;       /* Which events fired (WL_* bitmask) */
    pgsocket  fd;           /* Socket fd, if applicable */
    void     *user_data;    /* Caller-supplied context pointer */
} WaitEvent;
```

### WaitEventSet (Opaque)

Internally, `WaitEventSet` contains:

- An array of registered events (latch, sockets, postmaster death)
- Platform-specific state (epoll fd, kqueue fd, poll array, or Windows handles)
- A reference to the associated latch (for `WL_LATCH_SET` events)
- The resource owner for cleanup tracking

---

## Diagram: Latch Wake Flow

```
Process A (sender)                    Process B (sleeper)
==================                    ====================

                                      ResetLatch(MyLatch)
                                      Check for work: none
                                      maybe_sleeping = true
                                      WaitEventSetWait(...)
                                         |
                                         | epoll_pwait() / kqueue() / poll()
                                         | (blocked)
                                         |
SetLatch(B->procLatch)                   |
  1. B->procLatch.is_set = true          |
  2. memory barrier                      |
  3. read maybe_sleeping == true         |
  4. kill(B->pid, SIGURG) ------------->-+
                                         |
                                      SIGURG arrives
                                         |
                                      [epoll] signalfd becomes readable
                                      [kqueue] EVFILT_SIGNAL fires
                                      [poll] self-pipe write wakes poll()
                                         |
                                      WaitEventSetWait returns
                                      events[0].events = WL_LATCH_SET
                                         |
                                      ResetLatch(MyLatch)
                                      Check for work: found!
                                      DoWork()
```

---

## Postmaster Death Detection

`WL_POSTMASTER_DEATH` and `WL_EXIT_ON_PM_DEATH` allow backends to detect when the
postmaster has crashed. On Unix, this is implemented by monitoring a **postmaster
death pipe**: the postmaster creates a pipe at startup and keeps the write end open.
All children inherit the read end. When the postmaster dies, the kernel closes the
write end, making the read end readable.

On Linux with `epoll`, the pipe fd is added to the epoll set. On other platforms,
it is added to the `poll()` or `kqueue()` set. When the fd becomes readable,
`WaitEventSetWait` reports `WL_POSTMASTER_DEATH`.

`WL_EXIT_ON_PM_DEATH` is a convenience flag that calls `proc_exit(1)` immediately
upon detecting postmaster death, so the caller does not need to handle it explicitly.

---

## Procsignal: Inter-Backend Signaling

`procsignal.c` provides a higher-level signaling mechanism built on top of latches.
A backend can send a **typed signal** to another backend:

```c
/* Signal types (from procsignal.h) */
PROCSIG_CATCHUP_INTERRUPT     /* Invalidation messages pending */
PROCSIG_NOTIFY_INTERRUPT      /* NOTIFY message arrived */
PROCSIG_PARALLEL_MESSAGE      /* Parallel worker message available */
PROCSIG_WALSND_INIT_STOPPING  /* WAL sender should begin stopping */
PROCSIG_BARRIER               /* Barrier processing needed */
PROCSIG_LOG_MEMORY_CONTEXT    /* Dump memory contexts to log */
PROCSIG_PARALLEL_APPLY_MESSAGE /* Parallel apply message available */
```

The implementation uses a shared memory array (`ProcSignalSlots`) indexed by
`ProcNumber`. To send a signal, the sender sets a flag in the target's slot and
then calls `SetLatch` on the target's `procLatch`. The target, upon waking, checks
its flags and dispatches accordingly.

---

## Connections

- **[Shared Memory](shared-memory.md)** -- Every `PGPROC` and its `procLatch` live
  in the main shared memory region. `WaitEventSet` objects are backend-local, but
  they reference shared latches.

- **[ProcArray](procarray.md)** -- `ProcArray` uses `SetLatch` to wake backends that
  are waiting for transaction completion or snapshot updates.

- **[Message Queues](message-queues.md)** -- `shm_mq` uses `SetLatch` to wake the
  reader when data is written to the ring buffer, and vice versa.

- **Chapter 5 (Locking)** -- LWLock waits use `PGPROC.sem` (a semaphore) rather than
  latches, but heavyweight lock waits use `ProcSleep` which does interact with the
  latch system for deadlock timeout handling.

- **Chapter 8 (Executor)** -- The parallel query leader uses `WaitEventSet` to monitor
  multiple `shm_mq` queues from different workers simultaneously.
