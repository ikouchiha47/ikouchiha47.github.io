---
active: true
layout: post
title: "A Quick rundown on concurrency and gc"
subtitle: "Go, Kotlin, BEAM, JVM/HotSpot, GraalVM, and the GC algorithms underneath them"
description: "How Go, Kotlin coroutines, and BEAM handle preemption safely, why GC safe-points exist, and a source-grounded tour of tricolor GC, G1, ZGC, Shenandoah, C4, and more."
date: 2026-08-12
---


## Abstract

Three languages — Go, Kotlin, and Erlang/Elixir (running on BEAM) — solve the
same problem (run many logical tasks on few OS threads) with three different
answers to one question: **who controls the switch between tasks, and what
does that controller need to know to do it safely?**

The answer to that question determines everything downstream: whether the
model is cooperative or preemptive, whether GC pauses one thread or the whole
process, and whether a crash is contained or catastrophic.

This document derives each model from its constraints rather than describing
it as a list of features. Each section ends with a checkpoint question you
should be able to answer before moving to the next section.

---

## Background: the problem all three are solving

A CPU core runs one instruction stream at a time. OS threads are the
kernel's abstraction for time-slicing a core across many instruction
streams, but they are expensive:

- ~8MB stack per thread (Linux default)
- A context switch saves/restores the full register file and disturbs the
  cache and TLB
- 10,000 OS threads means gigabytes of stack space before any work is done

So every runtime that wants cheap concurrency builds an **M:N scheduler**:
M logical tasks multiplexed onto N OS threads (typically N ≈ number of
cores). The three systems below are three different M:N schedulers, and
they differ because they made different decisions about who owns the
switching logic.

**Checkpoint:** before continuing, state in one sentence why an OS thread is
too expensive to use one-per-logical-task at scale.

---

## Part 1 — Go

Sources read directly for this section (not paraphrased from memory):
`src/runtime/preempt.go`, `src/runtime/signal_unix.go`, `src/runtime/proc.go`,
`src/runtime/mgc.go` — golang/go, master branch, fetched from
raw.githubusercontent.com.

### 1.1 Key concept: this is CSP, not fork-join

Go's concurrency model is explicitly an implementation of Hoare's
**Communicating Sequential Processes (CSP, 1978)** — independent sequential
processes that interact *only* through message passing over channels, not
shared mutable state accessed via locks. This is a design lineage, stated
directly in Go's own materials: "Don't communicate by sharing memory;
share memory by communicating."

**Where CSP itself came from.** Tony Hoare published "Communicating
Sequential Processes" in *Communications of the ACM*, 1978. The problem he
was working on wasn't concurrency in the modern web-service sense — it was
correctness of concurrent programs at a time when shared-variable
concurrency (semaphores, monitors) was the dominant model and was proving
extremely hard to reason about formally: with shared mutable state, the
number of possible interleavings of two processes explodes, and proving a
program correct meant proving it correct under *all* of them.

Hoare's move was to make the *only* interaction between processes an
explicit, synchronous, named event — a process names who it's sending
to/receiving from, and the send/receive pair is the entire synchronization
primitive, with no separate lock needed. This has a real mathematical
payoff: because processes share nothing, you can reason about each process
in isolation and about the communication events between them as a
separate, much smaller problem — closer to algebra than to exhaustive
case analysis of shared-memory interleavings. CSP was formalized further
into a full process algebra in Hoare's own later work and independently
alongside Robin Milner's CCS (Calculus of Communicating Systems, also late
1970s) — the two are usually cited together as the origin of process
algebras generally.

Go's designers (Rob Pike, in particular, who had earlier worked on
Newsqueak and Alef — direct experimental predecessors that already used
CSP-style channels) took the *communication primitive* from CSP —
synchronous, named-channel message passing — without adopting Hoare's full
formal process algebra or his original synchronous-only restriction (Go's
buffered channels allow asynchronous sends up to the buffer size, which
Hoare's original calculus didn't have). So "Go implements CSP" is accurate
at the level of the core idea — channels as the unit of synchronization,
not locks — and imprecise if taken to mean Go implements the full formal
calculus.

This matters because it's easy to conflate with two other models that are
*not* what Go does:

- **Fork-join** (Java's `ForkJoinPool`, Cilk, OpenMP): a task explicitly
  splits into subtasks, waits for all of them, then joins. The parallelism
  is structured around a single computation's divide-and-conquer shape.
  Go has nothing built into the language for this — you'd hand-roll it
  with a `sync.WaitGroup`. Goroutines are not spawned with an implicit
  join; `go f()` returns immediately and nothing waits for it unless you
  add that synchronization yourself.
- **Shared-memory threading with locks** (raw pthreads, Java `synchronized`):
  the default coordination primitive is a shared address space guarded by
  mutual exclusion. Go supports this too (`sync.Mutex` exists and is used
  heavily inside the runtime itself), but it's not the idiomatic surface
  the language pushes you toward.

Channels (`chan`) are the CSP primitive: a goroutine sends a value into a
channel, another receives it, and the transfer itself is the
synchronization point — no separate lock is needed for that handoff.

**Checkpoint:** if goroutines don't implicitly join, what actually
guarantees a `go f()` call's side effects are visible before `main()`
returns? (Answer: nothing, by default — this is why programs that don't
explicitly wait via a channel or `WaitGroup` can exit before spawned
goroutines finish; it's a common bug source, not a language guarantee.)

### 1.2 The GMP scheduler

From `proc.go`'s own top-of-file doc comment (line ~24 onward):

> The scheduler's job is to distribute ready-to-run goroutines over worker
> threads.
> G - goroutine.
> M - worker thread, or machine.
> P - processor, a resource that is required to execute Go code. M must
> have an associated P to execute Go code, however it can be blocked or in
> a syscall w/o an associated P.
> Design doc at https://golang.org/s/go11sched.

This is the go11sched design (Dmitry Vyukov, 2012) — the M:N:P model exists
specifically to solve the problem of per-P local run queues: without P as a
separate scheduling resource, every M contending for work would need to hit
a global queue, which doesn't scale past a few cores. Each P owns a local
run queue; an M must acquire a P to run Go code at all, which is why a
goroutine blocked in a syscall releases its P for another M to pick up
(`handoffp` in `proc.go`) rather than leaving a core idle.

### 1.3 Preemption: how it evolved, and why GC is the reason it changed at all

**Go ≤1.10 — cooperative, at function prologues.** Every function call
checked a "please yield" flag (implemented by poisoning the stack-bound
check, per `preempt.go`'s header comment: "Synchronous safe-points are
implemented by overloading the stack bound check in function prologues").
A goroutine with no function calls in its loop body (`for {}`) never
triggered that check and could never be preempted this way.

**Why this is a GC problem, specifically, and not just a scheduling
fairness problem:** `mgc.go` calls `stopTheWorldWithSema` at both mark
termination and sweep termination (`gcMarkTermination`, `gcStart` —
`mgc.go` lines ~835, ~1066 in the current source). STW literally means
every goroutine must reach a state the GC considers safe before the GC
phase can proceed — the mark/sweep transition cannot begin with even one
goroutine still running arbitrary code, because the GC needs a globally
consistent view of what's reachable. A goroutine stuck in a tight loop
with no function calls blocked this indefinitely. This was the actual,
measured production problem that motivated the 2019 proposal
(golang/proposal `24543-non-cooperative-preemption.md`) — not a general
desire for "fair" scheduling.

**Go 1.14 — non-cooperative, signal-based.** `preempt.go`'s own comment
distinguishes three safe-point categories precisely:

1. **Blocked safe-points** — a goroutine descheduled, blocked on sync, or
   in a syscall. Cheap: the runtime already has full knowledge of its stack.
2. **Synchronous safe-points** — a running goroutine voluntarily checks for
   a pending preemption request (the stack-bound-check trick above).
3. **Asynchronous safe-points** — *any* instruction in user code where a
   conservative stack/register scan can still find all roots. The runtime
   can stop a goroutine here using a signal, without the goroutine's
   cooperation.

`signal_unix.go` (lines 44–74) states the SIGURG rationale directly, as
four numbered criteria the signal had to satisfy:

1. Must be a signal debuggers pass through by default (on Linux: `SIGALRM`,
   `SIGURG`, `SIGCHLD`, `SIGIO`, `SIGVTALRM`, `SIGPROF`, `SIGWINCH`).
2. Must not be claimed internally by libc in mixed Go/C binaries (rules out
   `SIGCANCEL`, `SIGSETXID`).
3. Must be safe to receive spuriously — ruling out `SIGALRM` (ambiguous
   cause) and `SIGUSR1`/`SIGUSR2` (commonly used by applications for real
   things).
4. Must exist on platforms without real-time signals (rules out macOS's
   missing RT signal range).

`SIGURG` won because out-of-band TCP data is essentially unused in
practice, the signal doesn't even report which socket triggered it (making
it nearly useless for its literal purpose), and any correctly-written
application already has to tolerate a spurious `SIGURG`.

The mechanism, traced through the actual call path:
`suspendG` (`preempt.go`) drives a goroutine toward suspension — if it's
`_Grunning`, it sets `gp.preemptStop`/`gp.preempt` and calls `preemptM`,
which calls `signalM(mp, sigPreempt)` (`signal_unix.go` line ~386) to
deliver `SIGURG` to that specific OS thread. The signal handler
(`doSigPreempt`, `signal_unix.go` line ~342) inspects the interrupted PC
and only acts if it lands on a recognized async safe-point; if not, it
leaves the goroutine to continue and retries. Once accepted, the handler
rewrites the signal context so execution resumes at `asyncPreempt`, which
spills all potentially-pointer-holding registers to the stack before
handing off to the scheduler — this is what makes the stack scannable by
the GC afterward.

An intermediate fix — inserting checks at loop back-edges so tight loops
without function calls would still hit synchronous safe-points — was
measured and **rejected**: 7.8% throughput regression, considered too
expensive to pay unconditionally across all Go programs just to close this
gap. Signal-based async preemption was strictly cheaper because it costs
nothing until actually invoked.

### 1.3a The actual GC algorithm: tricolor mark-sweep with a hybrid write barrier

Everything above (1.3) covers *when* goroutines get stopped for GC. This
subsection covers what the GC is actually doing — read directly from
[`src/runtime/mgc.go`](https://github.com/golang/go/blob/master/src/runtime/mgc.go)
(top-of-file doc comment) and
[`src/runtime/mbarrier.go`](https://github.com/golang/go/blob/master/src/runtime/mbarrier.go)
(top-of-file doc comment), not summarized from memory.

**What `mgc.go` states directly, line for line:**

```go
// The GC runs concurrently with mutator threads, is type accurate (aka precise), allows multiple
// GC threads to run in parallel. It is a concurrent mark and sweep that uses a write barrier. It is
// non-generational and non-compacting.
```

**Takeaway:**
- "concurrent mark and sweep" — the mark phase (finding live objects) and
  sweep phase (reclaiming dead ones) both run alongside your program's own
  goroutines, not just alongside each other.
- "non-generational" — Go's GC does *not* separate young/old objects into
  different heaps swept at different rates, unlike HotSpot's G1 or the
  young/old generation split most JVM/V8 GCs use. Every GC cycle scans the
  whole live set. This is a stated design tradeoff, not an oversight; the
  source doesn't give the rationale for the choice.
- "non-compacting" — dead objects are freed in place; Go doesn't move
  live objects around to defragment the heap the way a compacting
  collector does. This is also why Go's stack-map / pointer-tracking
  machinery (Part 1.3) doesn't need to handle objects moving mid-flight —
  one less category of complexity than a moving collector like ZGC.

**The three-color abstraction, sourced from the mark-phase walkthrough
(`mgc.go`, steps 2b–2d) plus the explicit invariant comment further down
the same file:**

```go
// At this point all Ps have enabled the write
// barrier, thus maintaining the no white to
// black invariant.
```

Objects are conceptually white (not yet visited — presumed garbage),
grey (visited, but its own pointers not yet scanned), or black (visited
*and* all its pointers scanned). The mark phase's job is to walk grey
objects until none remain — at that point everything reachable is black,
everything still white is garbage. The **invariant being protected** —
"no white to black" — is: a black object (already fully scanned) must
never gain a pointer directly to a white object without that white object
getting shaded first. If that invariant were violated, the GC could finish
marking, still see the object as white, and free something the mutator
(your running program) still holds a live reference to. That's the
correctness property the write barrier mechanism below exists to uphold.

**The write barrier itself, from `mbarrier.go`'s pseudocode:**

```go
// Go uses a hybrid barrier that combines a Yuasa-style deletion
// barrier—which shades the object whose reference is being
// overwritten—with Dijkstra insertion barrier—which shades the object
// whose reference is being written.
//
//     writePointer(slot, ptr):
//         shade(*slot)
//         if current stack is grey:
//             shade(ptr)
//         *slot = ptr
```

And the reasoning for why *both* halves are needed, stated as three
numbered cases in the source:

```go
// 1. shade(*slot) prevents a mutator from hiding an object by moving
// the sole pointer to it from the heap to its stack.
// 2. shade(ptr) prevents a mutator from hiding an object by moving
// the sole pointer to it from its stack into a black object in the heap.
// 3. Once a goroutine's stack is black, the shade(ptr) becomes
// unnecessary.
```

That's the pseudocode from the file's doc comment. The actual code that
runs it — `typedmemmove`, the function every pointer-containing struct
copy in Go goes through — shows the same idea gated by a real runtime
check, not just documented intent:

```go
//go:linkname typedmemmove
//go:nosplit
func typedmemmove(typ *abi.Type, dst, src unsafe.Pointer) {
	if dst == src {
		return
	}
	if writeBarrier.enabled && typ.Pointers() {
		// This always copies a full value of type typ so it's safe
		// to pass typ along as an optimization. See the comment on
		// bulkBarrierPreWrite.
		bulkBarrierPreWrite(uintptr(dst), uintptr(src), typ.PtrBytes, typ)
	}
	// There's a race here: if some other goroutine can write to
	// src, it may change some pointer in src after we've
	// performed the write barrier but before we perform the
	// memory copy. This safe because the write performed by that
	// other goroutine must also be accompanied by a write
	// barrier, so at worst we've unnecessarily greyed the old
	// pointer that was in src.
	memmove(dst, src, typ.Size_)
}
```

Two things this shows that the pseudocode alone doesn't: the check is
`writeBarrier.enabled && typ.Pointers()` — the barrier only runs at all if
the type being copied actually contains pointers, so copying a struct of
plain integers pays nothing. And the barrier call (`bulkBarrierPreWrite`,
which does the `shade(*slot)`/`shade(ptr)` work from the pseudocode above)
happens strictly *before* the `memmove` that performs the real copy — the
comment directly under it explains why a race on `src` between the
barrier and the copy is still safe: the other goroutine's own write to
`src` would have gone through its own barrier already, so at worst an
object gets greyed unnecessarily, never missed.

**Takeaway:** a write barrier is code the compiler inserts around
*every* pointer write during the concurrent mark phase — not a hardware
mechanism like the JVM's poll page (Part 3.5.2), but a software
instrumentation cost paid only while `gcphase == _GCmark` (confirmed by
`mgc.go`'s phase-transition code, which flips `gcBlackenEnabled`/enables
the barrier at mark start and disables it at sweep start). The two halves
guard the two directions an object could otherwise get "lost": deleting
the only pointer to it from an already-scanned (black) part of the heap
(case 1, Yuasa-style), or the mutator itself moving a pointer from its own
unscanned stack into a black object before the GC ever sees it (case 2,
Dijkstra-style). Case 3 is the source explaining its own optimization —
once a goroutine's *whole stack* has been scanned (turned black), the
insertion half becomes redundant, because nothing on that stack can be
hiding an unshaded pointer anymore.

**Open question:** the mark-work-stealing/distributed-termination
algorithm in `gcMarkDone` (mentioned but not shown above), and the
concurrent sweep's per-span locking scheme — not covered by these two
files.

### 1.4 Checkpoint

Trace the actual failure this fixed: before 1.14, `for {}` with no
function calls inside it. What specifically blocked, and for how long?
(Answer: any `stopTheWorldWithSema` call in `mgc.go` — i.e. every GC mark
or sweep termination phase — blocked indefinitely, because the goroutine
never reached the stack-bound check that synchronous preemption relies on.
This wasn't a latency inconvenience; it was an unbounded stall.)

---

## Part 2 — Kotlin

Sources read directly for this section: `kotlin.coroutines.Continuation`
and `kotlin.coroutines.intrinsics` (JetBrains/kotlin, stdlib — this part is
**language-level**), and `kotlinx.coroutines.CoroutineDispatcher` /
`kotlinx.coroutines.scheduling.CoroutineScheduler` (Kotlin/kotlinx.coroutines
— this part is a **library**, not the compiler or the language spec).

This split is the correction from the previous draft: `suspend` and the
CPS transform are compiler + stdlib. `Dispatchers`, `Job`,
`CoroutineScope`, structured concurrency, and the actual thread-pool
scheduler are **kotlinx.coroutines**, a library published by JetBrains but
not part of Kotlin itself — you can write `suspend` functions with zero
dependency on kotlinx.coroutines; it only becomes necessary once you want
dispatchers, structured cancellation, `async`/`await`-style builders, or
`Flow`.

### 2.1 Compiler + stdlib layer: what `suspend` actually is

Kotlin runs primarily on the JVM. It cannot change the JVM's thread model —
JVM threads are OS threads. The lever available is using fewer of them,
which means: don't let a suspended computation hold a thread's stack.

The mechanism is CPS (Continuation-Passing Style), and the actual
interface it compiles against is `kotlin.coroutines.Continuation`, defined
in stdlib:

```kotlin
public interface Continuation<in T> {
    public val context: CoroutineContext
    public fun resumeWith(result: Result<T>)
}
```

That's the entire primitive. A `suspend` function, at the ABI level, is a
regular JVM method that takes an extra trailing `Continuation` parameter
and returns `Any?` — either the real result, or the sentinel
`COROUTINE_SUSPENDED` (defined in `kotlin.coroutines.intrinsics`,
stdlib) if it suspended. `suspendCoroutineUninterceptedOrReturn` is the
stdlib intrinsic that exposes the raw continuation to library authors
building suspension primitives on top.

The compiler transforms a `suspend` function's body into a state machine
object implementing `Continuation`, with a `label` field tracking progress
and local variables lifted into fields, roughly:

```kotlin
suspend fun fetchAndProcess() {
    val data = fetch()
    val result = process(data)
    save(result)
}
```

```kotlin
class FetchAndProcessContinuation(val completion: Continuation<Unit>) : Continuation<Any?> {
    var label = 0
    var data: Data? = null

    override fun resumeWith(result: Result<Any?>) {
        when (label) {
            0 -> { label = 1; fetch(this) }
            1 -> { data = result.getOrThrow() as Data; label = 2; process(data, this) }
            2 -> { save(result.getOrThrow() as Result); completion.resumeWith(Result.success(Unit)) }
        }
    }
}
```

The function returns (freeing the thread) instead of blocking; the
continuation object on the heap carries the state needed to resume. All of
this — `Continuation`, the CPS transform, `suspend` as a keyword — is
**part of the Kotlin language and compiler**, independent of any
concurrency library. This is why `suspend` functions work fine in, say, a
minimal environment with no kotlinx.coroutines dependency at all, as long
as something implements `Continuation` to drive them.

### 2.2 Why this makes suspension cooperative

The compiler must know, at compile time, every point where execution might
suspend — that's the entire reason `suspend` is a keyword rather than a
runtime annotation. If a coroutine body never calls a suspend function
inside a loop, the compiler never inserts a state-machine transition
there, so there is no return/yield point to force. There's no external
mechanism analogous to Go's `SIGURG` that could interrupt it, because
nothing external to the continuation object was ever created to interrupt
*into* — the compiler-generated state machine, not raw thread register
state, is the unit of suspension, and it only exists at points the source
code actually marked as suspendable.

### 2.3 Library layer: kotlinx.coroutines and what it adds

Continuation alone gives you suspension; it gives you nothing about *where*
code resumes, cancellation, or structured lifetimes. That's what
kotlinx.coroutines is for:

- **`CoroutineDispatcher`** implements `ContinuationInterceptor` — it's
  what decides *which thread* a continuation resumes on.
  `Dispatchers.Default` and `Dispatchers.IO` are the common ones.
- **`CoroutineScheduler`** (`kotlinx-coroutines-core/jvm/.../scheduling/`)
  is the actual thread pool behind `Dispatchers.Default`/`IO`. Its own doc
  comment is explicit about the design lineage:
  > "The original idea with a single-slot LIFO buffer comes from Golang
  > runtime scheduler by D. Vyukov. It was proven to be 'fair enough',
  > performant and generally well accepted and initially was a significant
  > inspiration source for the coroutine scheduler."

  Concretely: per-worker local run queues, work-stealing when a worker's
  queue empties, and a global queue for tasks submitted from outside the
  pool — the same shape as Go's per-P local run queues plus work-stealing
  (`findRunnable` in `proc.go`). This is convergent evolution *by direct
  admission*, not independent design — Kotlin's authors read Go's
  scheduler and reused the shape for a completely different substrate (JVM
  threads instead of goroutines).

  The actual `dispatch` function, not just the doc comment describing it:

  ```kotlin
  fun dispatch(block: Runnable, taskContext: TaskContext = NonBlockingContext, fair: Boolean = false) {
      trackTask() // this is needed for virtual time support
      val task = createTask(block, taskContext)
      val isBlockingTask = task.isBlocking
      val stateSnapshot = if (isBlockingTask) incrementBlockingTasks() else 0
      // try to submit the task to the local queue and act depending on the result
      val currentWorker = currentWorker()
      val notAdded = currentWorker.submitToLocalQueue(task, fair)
      if (notAdded != null) {
          if (!addToGlobalQueue(notAdded)) {
              throw RejectedExecutionException("$schedulerName was terminated")
          }
      }
      if (isBlockingTask) {
          signalBlockingWork(stateSnapshot)
      } else {
          signalCpuWork()
      }
  }
  ```

  This is the local-queue-first, global-queue-as-overflow policy the doc
  comment describes, made concrete: `submitToLocalQueue` tries the calling
  worker's own queue first (the cheap, no-contention path); only if that
  fails (`notAdded != null` — the local queue is full) does the task fall
  back to `addToGlobalQueue`, the shared, contended queue every idle
  worker also checks. The blocking-vs-CPU distinction
  (`signalBlockingWork`/`signalCpuWork`) is Kotlin-specific — Go's GMP
  model has no equivalent split, since a goroutine that blocks in a
  syscall just releases its P (Part 1.2) rather than being classified
  ahead of time by the scheduler.
- **`Job`, `CoroutineScope`, structured concurrency** — the parent/child
  cancellation tree that ensures a scope can't complete while children are
  still running, and that cancelling a parent cancels all children. This
  is the closest thing Kotlin has to fork-join semantics, but it's opt-in
  library behavior layered on top of continuations, not a language feature.

### 2.4 GC consequence

Kotlin/JVM's GC is whatever the underlying JVM GC is (G1, ZGC, etc.).
Coroutines don't change the GC algorithm — they change what's running on a
given OS thread at a given moment, and they add continuation objects to
the heap (one allocation per suspend point per invocation, though the JVM
JIT can sometimes eliminate short-lived ones). Suspension does not create
a GC safe-point problem analogous to Go's, because JVM safe-points are a
separate, JIT-inserted polling mechanism entirely orthogonal to coroutine
suspension — see Part 4 for how HotSpot's safepoint polling actually works,
which is the real GC-relevant mechanism on this stack, not the coroutine
machinery itself.

### 2.4a Continuation and DispatchedContinuation, from source

Read directly:
[`kotlin/libraries/stdlib/src/kotlin/coroutines/Continuation.kt`](https://github.com/JetBrains/kotlin/blob/master/libraries/stdlib/src/kotlin/coroutines/Continuation.kt),
[`kotlin/libraries/stdlib/src/kotlin/coroutines/intrinsics/Intrinsics.kt`](https://github.com/JetBrains/kotlin/blob/master/libraries/stdlib/src/kotlin/coroutines/intrinsics/Intrinsics.kt),
[`kotlinx.coroutines/kotlinx-coroutines-core/common/src/internal/DispatchedContinuation.kt`](https://github.com/Kotlin/kotlinx.coroutines/blob/master/kotlinx-coroutines-core/common/src/internal/DispatchedContinuation.kt).

**`Continuation.kt`, the entire interface, quoted in full because it's short
enough that summarizing it would lose information:**

```kotlin
public interface Continuation<in T> {
    public val context: CoroutineContext
    public fun resumeWith(result: Result<T>)
}
```

**Takeaway:** the stdlib's contract for "a suspended computation" is
exactly two things — a context bag, and one method to call when a result
is ready. Nothing here mentions threads, dispatchers, or scheduling:
thread placement is not a compiler-level concern, since the interface the
compiler generates against has no slot for it.

**`Intrinsics.kt`, the actual suspension primitive:**

```kotlin
public suspend inline fun <T> suspendCoroutineUninterceptedOrReturn(
    crossinline block: (Continuation<T>) -> Any?
): T {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    throw NotImplementedError("Implementation of suspendCoroutineUninterceptedOrReturn is intrinsic")
}
```

**Takeaway:** the body is a `throw` — this function has no real
implementation in Kotlin source at all. The comment above it in the file
(not reproduced above) states the implementation is intrinsic: the
compiler recognizes this specific function by name and replaces the call
with generated bytecode directly. The CPS transform is not a library
trick built on top of ordinary language features — the compiler has
special-cased knowledge of this function.

**Open question:** the compiler's codegen for the intrinsic itself is not
visible from this file — only the signature and doc-comment stating that
special-casing happens.

**`DispatchedContinuation.kt`, confirming the wrapping claim from
checkpoint 2.5:**

```kotlin
internal class DispatchedContinuation<in T>(
    @JvmField internal val dispatcher: CoroutineDispatcher,
    @JvmField val continuation: Continuation<T>
) : DispatchedTask<T>(MODE_UNINITIALIZED), CoroutineStackFrame, Continuation<T> by continuation {
```

**Takeaway:** `DispatchedContinuation` holds both a `dispatcher` field and
the original compiler-generated `continuation` as a delegate
(`Continuation<T> by continuation`). It wraps the compiler's continuation
rather than replacing it — the compiler produces the plain `Continuation`;
kotlinx.coroutines wraps it in a dispatcher-aware class before anything
calls `resumeWith`.

The actual dispatch decision — where the thread-hop the field declarations
above only imply actually happens — is `DispatchedContinuation`'s own
`resumeWith` override:

```kotlin
override fun resumeWith(result: Result<T>) {
    val state = result.toState()
    if (dispatcher.safeIsDispatchNeeded(context)) {
        _state = state
        resumeMode = MODE_ATOMIC
        dispatcher.safeDispatch(context, this)
    } else {
        executeUnconfined(state, MODE_ATOMIC) {
            withCoroutineContext(context, countOrElement) {
                continuation.resumeWith(result)
            }
        }
    }
}
```

Every time the wrapped operation completes, this is what actually runs
(not the plain `Continuation.resumeWith` interface method from stdlib,
Part 2.4a). It asks the dispatcher `safeIsDispatchNeeded(context)` — if
the current thread is already the right one (e.g. an unconfined
dispatcher, or resuming on the same thread that's already correct), it
calls straight through to the wrapped `continuation.resumeWith(result)`
in place, no thread hop. Otherwise it stashes the result in `_state` and
calls `dispatcher.safeDispatch(context, this)`, which schedules this same
object onto the dispatcher's thread pool (Part 2.3's `CoroutineScheduler`)
to be resumed there. This is the concrete mechanism behind "the dispatcher
decides what thread to resume on" (checkpoint 2.5's answer) — a runtime
branch inside `resumeWith`, not something the compiler's state machine
knows anything about.

**Open question:** the exact call site in kotlinx.coroutines'
coroutine-builder code (`launch`, `async`) where a `DispatchedContinuation`
gets constructed and handed the raw compiler-generated continuation — not
covered here, only its `resumeWith` behavior once constructed.

### 2.5 Checkpoint

Two continuations exist for a suspending coroutine call: the compiler
generates one automatically. Where does the *dispatcher* decide what
thread to resume on — inside `Continuation.resumeWith`, or somewhere
kotlinx.coroutines wraps around it? (Answer: kotlinx.coroutines wraps the
compiler-generated continuation with `ContinuationInterceptor.interceptContinuation`,
producing a `DispatchedContinuation` that routes the actual `resumeWith`
call through the dispatcher's thread pool. The compiler's state machine
has no thread-affinity logic of its own — that's entirely library-layer.)

---

## Part 3 — BEAM

Sources read directly for this section:
[`erts/emulator/beam/erl_process.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_process.c),
[`erts/emulator/beam/erl_vm.h`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_vm.h),
[`erts/emulator/beam/emu/beam_emu.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/emu/beam_emu.c),
[`erts/emulator/beam/erl_gc.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_gc.c)
— erlang/otp, master branch.

### 3.1 Constraint

Erlang's original design question (Joe Armstrong) was not about
performance — it was: how do you build a system that can run essentially
forever without going down? The answer: faults must be contained, which
requires isolation, which requires sharing nothing.

### 3.2 Design: per-process heap, no shared memory

BEAM processes (VM-managed, not OS processes) share no memory. Each has
its own heap and its own GC. `beam_emu.c`'s `process_main` makes this
concrete — the interpreter loop's registers are literally per-process
state, not per-OS-thread:

```c
/* Pointer to X registers: x(0)..x(N). */
register Eterm* reg REG_xregs = NULL;

/* Top of heap (next free location); grows upwards. */
register Eterm* HTOP REG_htop = NULL;

/* Stack pointer. Grows downwards; points
 * to last item pushed (normally a saved
 * continuation pointer). */
register Eterm* E REG_stop = NULL;
```

Each process being swapped onto a scheduler thread brings its own heap
pointer (`HTOP`), its own stack pointer (`E`), and its own register file
(`reg`) — nothing here is shared across processes the way a JVM heap or Go
heap is shared across threads/goroutines. Sending a message to another
process copies the data into the target's heap (large binaries are the
exception — reference-counted in a shared binary heap to avoid the copy).

Because no process can see another's stack or heap, there's no shared
safe-point problem: the scheduler never needs to reason about pointer
validity in *another* process's memory to preempt one process, which is
exactly the constraint Go's stack maps (Part 1.3) and HotSpot's poll pages
(Part 3.5) both exist to satisfy and BEAM structurally doesn't need to.

### 3.3 Key concept: what a reduction actually is

Before the mechanism, the term itself. "Reduction" is not BEAM-specific
jargon invented for scheduling — it comes from **term rewriting /
reduction semantics** in programming language theory: evaluating an
expression is a sequence of "reduction steps," each rewriting the term
closer to a final value (the same root sense as "beta reduction" in lambda
calculus — Erlang's interpreter is, structurally, a term-rewriting
machine, and BEAM is literally short for "Bogdan/Björn's Erlang Abstract
Machine," an abstract machine executing that rewriting). A BEAM reduction
is the *scheduling* projection of that idea: one accounting unit charged
per unit of interpreter work — approximately one function call, one BIF
(built-in function) call, or one comparable primitive operation — deducted
from a process's budget every time the interpreter dispatches one.

It is deliberately **not** a fixed wall-clock unit. It's an abstraction
that lets the scheduler compare "how much work has this process done"
across processes without needing a hardware timer interrupt (contrast Part
0's OS timer-interrupt preemption) — the interpreter itself is the thing
counting, inline, as part of doing the work. That's what makes it cheap:
there's no separate polling instruction (contrast HotSpot's poll page,
Part 3.5.2) or external interrupt (contrast Go's SIGURG, Part 1.3) —
the decrement is folded into instruction dispatch that was happening
anyway.

Confirming this isn't purely a scheduling-only concept, `erl_process.h`
also uses reductions as a genuine unit of measurement, converting elapsed
wall-clock time into an equivalent reduction count (used, among other
things, to charge a process for time spent blocked so the scheduler's
accounting stays consistent):

```c
ErtsMonotonicTime time = end - start;
...
time = ERTS_MONOTONIC_TO_USEC(time);
if (time == 0)
    return (Sint64) 1; /* At least one reduction */
/* Currently two reductions per micro second */
time *= (CONTEXT_REDS-1)/1000 + 1;
return (Sint64) time;
```

And the process struct itself (`erl_process.h`) documents `fcalls`
precisely as the live budget:

```c
Sint32 fcalls;   /* Number of reductions left to execute.
                  * Only valid for the current process while it
                  * is executing. */
```

So: a reduction is BEAM's unit of "work done," inherited in name from
term-rewriting theory, made concrete as roughly one function/BIF call in
the interpreter, and used both to decide *when to preempt* (3.3 below) and
to convert real elapsed time into comparable scheduling accounting.

### 3.3a Reduction vs. safepoint

They answer different questions, and that difference is exactly why the
comparison is useful:

- A **safepoint** (Go, Part 1.3; JVM, Part 3.5) answers *"where in the
  code is it valid to inspect/pause this thread's state?"* — a spatial
  question. Most instructions are *not* safe-points; the compiler/runtime
  has to specially mark or detect the few that are, because in a
  shared-heap, register-based execution model most points mid-instruction
  don't have a fully-known, GC-inspectable machine state.
- A **reduction** answers *"has this process done enough work that it
  should yield?"* — a budget question, not a location question.

The reason reductions don't need a *separate* safepoint concept is that in
BEAM's interpreter, **every reduction boundary already is a valid
safepoint** — process state (heap pointer, stack pointer, registers) is
always fully known and consistent between BEAM instructions, because the
interpreter loop (`process_main`, 3.2) never leaves execution in a
partially-updated state across an instruction dispatch. There's no
"mid-instruction, a pointer is briefly stored as a raw integer" hazard
(Go's `unsafe.Pointer`→`uintptr` case, Part 1.3) to guard against, because
there's no equivalent unsafe low-level escape hatch in normal BEAM
bytecode execution the way there is in compiled machine code.

So the precise relationship is: **in Go and the JVM, safe-points are a
sparse subset of execution points, specially constructed at compile time
because most points aren't safe. In BEAM, every point between instructions
is already safe, so the only remaining question is scheduling policy — how
often to actually act on that safety — and that's exactly what the
reduction counter answers.** Reduction counting is the "when to act"
policy layered on top of an execution model where "where is it safe to
act" was never a hard problem to begin with. This is a direct consequence
of Part 3.2's isolation constraint: shared, GC-managed memory is what
makes "where is it safe" hard in the first place, and BEAM opted out of
that at the memory-model level, not at the scheduling level.

### 3.3.1 Preemption: reduction counting, with the actual constant

`erl_vm.h` defines the budget directly:

```c
#define CONTEXT_REDS 4000            /* Swap process out after this number */
```

(Note: this is the current source value. Older Erlang documentation and
blog posts commonly cite ~2000 reductions — that number is stale; always
check the constant in the version you're targeting rather than trusting a
remembered figure, including this document a year from now.)

The decrement mechanism is the interpreter's own reduction counter,
`FCALLS`, documented directly at its declaration in `process_main`:

```c
/* Number of reductions left.  This function
 * returns to the scheduler when FCALLS reaches zero. */
register Sint FCALLS REG_fcalls = 0;
```

Every BEAM instruction (roughly: one function call, one comparable unit of
work) decrements `FCALLS`. When it hits zero, `process_main` returns
control to the scheduler, which calls `erts_schedule` with the reduction
count actually consumed:

```c
reds_used = REDS_IN(c_p) - FCALLS;
...
c_p = erts_schedule(NULL, c_p, reds_used);
```

`erl_process.c` also derives several scheduler tuning constants directly
from `CONTEXT_REDS` — e.g. `ERTS_RUNQ_CHECK_BALANCE_REDS_PER_SCHED
(2000*CONTEXT_REDS)` for load-balancing cadence between run queues, and
`ERTS_PROC_MIN_CONTEXT_SWITCH_REDS_COST (CONTEXT_REDS/10)` — confirming
reductions are the scheduler's universal unit of "how much work happened,"
not just a preemption trigger.

There is no signal, no stack map, no poll page: preemption here is a
plain integer counter checked as part of every instruction dispatch, cheap
because it's already inline in the interpreter's hot loop, not a bolted-on
external mechanism.

### 3.4 GC consequence

Because each process owns its heap exclusively, `erl_gc.c` runs GC
per-process — a GC pause for one process is invisible to every other
process running concurrently on other scheduler threads. There is no
whole-VM stop-the-world equivalent to Go's `stopTheWorldWithSema` (Part
1.3) or HotSpot's global safepoint synchronization (Part 3.5.1): BEAM
never needs "every process frozen at once," because nothing GC-relevant is
ever shared across processes to make that necessary.

### 3.5 Fault model as a consequence, not a philosophy

Because processes are isolated, a crash is just a process exiting — it
cannot corrupt another process's state by construction. This is why "let
it crash" is viable: supervisors restart failed processes and the
remaining system is provably unaffected, because isolation was the
starting constraint everything else (per-process GC, reduction-counted
preemption, copy-on-send messaging) follows from, not an afterthought
layered on top.

### 3.5a `erts_schedule`: the descheduling/reschedule handoff

Read directly:
[`erts/emulator/beam/erl_process.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_process.c),
`Process *erts_schedule(...)`.

```c
Process *erts_schedule(ErtsSchedulerData *esdp, Process *p, int calls)
{
    ...
    if (ERTS_USE_MODIFIED_TIMING()) {
        context_reds = ERTS_MODIFIED_TIMING_CONTEXT_REDS;
    }
    else {
        context_reds = CONTEXT_REDS;
    }
    ...
    /*
     * Clean up after the process being scheduled out.
     */
    if (!p) {  /* NULL in the very first schedule() call */
        is_normal_sched = !esdp;
        ...
        rq = erts_get_runq_current(esdp);
        actual_reds = reds = 0;
        erts_runq_lock(rq);
    }
    else {
```

**Takeaway:** this is the function `process_main` (3.3.1) calls once
`FCALLS` hits zero — `erts_schedule` both cleans up the process being
descheduled and picks and returns the next one, in a single function (the
`if (!p)` branch is the bootstrap case with no previous process). The
`ERTS_USE_MODIFIED_TIMING()` branch means `CONTEXT_REDS` (4000) is not
always the literal number used — there's a "modified timing" mode with a
different constant. The 4000 figure in 3.3.1 is the default, not an
unconditional constant.

**Open question:** what `ERTS_USE_MODIFIED_TIMING()` gates, and the
next-process-selection logic inside `erts_schedule` past the cleanup
section shown above (priority levels, run-queue migration) — only the
function's opening is covered here.

### 3.6 Checkpoint

Given `CONTEXT_REDS = 4000` and one reduction ≈ one function call: can a
single BEAM process still starve the scheduler the way a Go goroutine
could pre-1.14? Look at what triggers the check. (Answer: no in the same
way — the check is baked into every instruction dispatch inside
`process_main`'s interpreter loop, not gated behind reaching a function
call boundary the way Go's old stack-bound check was; there is no BEAM
equivalent of `for {}` with literally zero dispatched instructions, since
even an infinite loop's body is instructions being dispatched and
decrementing `FCALLS`. The one thing that *can* still block a scheduler
thread is a genuinely blocking NIF/native call that doesn't yield control
back to the VM — the moral equivalent of a goroutine in a blocking syscall
without releasing its P.)

---

## Part 3.5 — JVM Safepoints (the mechanism Kotlin sits on top of, and Go's real point of contrast)

Sources read directly for this section:
[`src/hotspot/share/runtime/safepoint.hpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/safepoint.hpp),
[`src/hotspot/share/runtime/safepointMechanism.hpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/safepointMechanism.hpp),
openjdk/jdk, master branch. Also relevant as an applied-engineering account
(not a primary source, but a good "what this looks like in production"
companion): Sunny Srinidhi, ["Under the Hood: Java Peak Safepoints"](https://medium.com/software-under-the-hood/under-the-hood-java-peak-safepoints-dd45af07d766).

This section was missing entirely from the previous draft even though it's
the actual mechanism Part 2.4 waved at, and it's the correct point of
contrast for Go's approach — not an optional aside.

### 3.5.1 What a safepoint is, precisely, in HotSpot's own words

`safepoint.hpp`'s header comment:

```cpp
// The VMThread uses the SafepointSynchronize::begin/end
// methods to enter/exit a safepoint region. The begin method will roll
// all JavaThreads forward to a safepoint.
//
// JavaThreads must use the ThreadSafepointState abstraction (defined in
// thread.hpp) to indicate that that they are at a safepoint.
//
// The Mutex/Condition variable and ObjectLocker classes calls the enter/
// exit safepoint methods, when a thread is blocked/restarted. Hence, all
// mutex enter/exit points *must* be at a safepoint.
```

And the three-state enum that drives the whole mechanism:

```cpp
enum SynchronizeState {
    _not_synchronized = 0,   // Threads not synchronized at a safepoint. Keep this value 0.
    _synchronizing    = 1,   // Synchronizing in progress
    _synchronized     = 2    // All Java threads are running in native, blocked in OS
                              // or stopped at safepoint. VM thread and any NonJavaThread
                              // may be running.
};
```

This confirms the GC-adjacent framing directly: a safepoint isn't
GC-specific in HotSpot — it's the general mechanism the VM uses any time it
needs every Java thread frozen in a known state (GC, deoptimization,
biased-lock revocation, thread dumps, class redefinition). GC is the most
frequent consumer, not the only one.

### 3.5.2 The poll-page mechanism — how threads notice they should stop

Unlike Go's synchronous safe-points (stack-bound-check poisoning) or async
safe-points (signal delivery), HotSpot's classic mechanism is **memory
polling**. From `safepointMechanism.hpp`:

```cpp
class SafepointMechanism : public AllStatic {
  ...
  static uintptr_t _poll_page_armed_value;
  static uintptr_t _poll_page_disarmed_value;
  static address   _polling_page;
  ...
  struct ThreadData {
    volatile uintptr_t _polling_word;
    volatile uintptr_t _polling_page;
    ...
  };

  // Call this method to see if this thread should block for a safepoint
  // or process handshake.
  static inline bool should_process(JavaThread* thread, bool allow_suspend = true);
```

The JIT compiler emits, at method entry and loop back-edges, a memory read
from `_polling_page`. Normally this page is mapped read-only-but-armable
and the read is nearly free (a single load the CPU can pipeline away). To
request a safepoint, the VM thread **unmaps or protects the polling page**
(the "armed" state). The next thread that executes its poll instruction
triggers a trap — a real page fault the OS delivers as a signal/exception
— which HotSpot's fault handler intercepts and redirects into safepoint
processing.

This is the crucial contrast with Go: HotSpot's mechanism is cooperative
in mechanism (a thread must execute its own poll instruction to notice) but
made cheap and *effectively involuntary* by tying the poll to a hardware
trap instead of a branch — a thread genuinely cannot skip past an armed
poll once it executes one, but a thread that never reaches a poll point at
all (analogous to Go's pre-1.14 tight-loop problem) still can't be stopped.
This is exactly the "time to safe-point" (TTSP) latency the linked Medium
piece measures in production — the gap between the VM thread arming the
page and the last straggler thread actually hitting its poll and blocking.
JIT-compiled code has poll points at loop back-edges and method returns/calls
(the compiler decides placement per-method based on loop structure);
interpreter frames check a flag on every bytecode dispatch, which is why
interpreted code reaches safepoints faster but runs slower generally.

### 3.5.2a Exact poll placement, and the safepoint/blocked distinction

Additional sources for this subsection (secondary, but precise and
attributed): Gil Tene's account on the mechanical-sympathy mailing list, as
reproduced at [Nitsan Wakart, "Safepoints: Meaning, Side Effects and Overheads"](http://psy-lob-saw.blogspot.com/2015/12/safepoints.html);
also [chriskirk.blogspot.com, "What is a Java Safepoint?"](http://chriskirk.blogspot.com/2013/09/what-is-java-safepoint.html)
and [jpbempel.blogspot.com, "Safety First: Safepoints"](http://jpbempel.blogspot.com/2013/03/safety-first-safepoints.html).

HotSpot doesn't poll unconditionally everywhere — poll placement is a
deliberate tradeoff, because "on top of the cost of the flag check itself,
maintaining a 'known state' adds significant complexity to the
implementation of certain optimizations," so keeping safepoints further
apart widens the scope for optimization. The actual poll locations:

- Effectively **between any two bytecodes** while running in the interpreter
- On **non-counted loop back-edges** in C1/C2-compiled code (a "counted"
  loop — bounds known at compile time — can skip the poll, since the JIT
  can prove it terminates)
- At **method entry/exit** in compiled code (entry on Zing, exit on
  OpenJDK) — and the compiler removes these polls entirely when a method
  gets inlined, since the caller's own poll covers it

You can find the actual poll instructions in `-XX:+PrintAssembly` output
by searching for `{poll}` or `{poll return}` in the instruction comments —
this is directly checkable on a running JVM, not just a claim from a blog.

A second correction worth stating precisely: **"at a safepoint" does not
mean "blocked."** JNI code, for instance, runs *at* a safepoint (its Java
state representation is frozen and safe to inspect) without being
descheduled. "Being blocked always happens at a safepoint, but being at a
safepoint doesn't require being blocked" — this is exactly analogous to
Go's distinction between "blocked safe-points" and the state a goroutine
sits in during a syscall (Part 1.3, category 1): the state is
GC-inspectable without the thread being paused by anything external.

Two further points that generalize the model correctly:

- **Global vs. per-thread safepoints.** The page-protection trick (3.5.2)
  is a *global* mechanism — OpenJDK brings all threads to a safepoint
  together for STW work. Some JVMs (Azul's Zing, via what it calls
  "Checkpoints") can bring an *individual* thread to a safepoint-like state
  without a global pause, for short per-thread operations. This is the
  same axis Go and BEAM sit on opposite ends of: Go's STW GC phases are
  global by necessity (Part 1.3), BEAM's per-process GC is inherently
  per-thread already (Part 3) — Zing's Checkpoints are HotSpot borrowing
  the BEAM-shaped idea onto a shared-heap runtime.
- **Unsafe code and safepoint density.** Because a safepoint can occur
  between any two bytecodes by default, JNI/Unsafe code that wants to run
  long stretches without a safepoint (e.g. a large `Unsafe.copyMemory`)
  must opt in to periodic safepoint opportunities itself — otherwise a
  long native call can inflate the "time to safe-point" the VM thread
  waits on before starting STW work, which is precisely the TTSP latency
  the linked "Java Peak Safepoints" article measures in production.

### 3.5.2b `safepoint.cpp`'s `begin()` function

Read directly:
[`src/hotspot/share/runtime/safepoint.cpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/safepoint.cpp),
`SafepointSynchronize::begin()`.

```cpp
void SafepointSynchronize::begin() {
  assert(Thread::current()->is_VM_thread(), "Only VM thread may execute a safepoint");
  ...
  log_trace(safepoint)("Blocking threads from starting/exiting");
  Threads_lock->lock();
  ...
  _waiting_to_block = nof_threads;
  ...
  log_trace(safepoint)("Arming safepoint using %s wait barrier", _wait_barrier->description());
  arm_safepoint();
  ...
  if (SafepointTimeout) {
    safepoint_limit_time = SafepointTracing::start_of_safepoint()
        + (jlong)(SafepointTimeoutDelay * NANOSECS_PER_MILLISEC);
  }
```

and further down, what happens if a thread doesn't reach the poll in time:

```cpp
  if (AbortVMOnSafepointTimeout && (os::elapsedTime() * MILLIUNITS > AbortVMOnSafepointTimeoutDelay)) {
    for (JavaThreadIteratorWithHandle jtiwh; JavaThread *cur_thread = jtiwh.next(); ) {
      if (cur_thread->safepoint_state()->is_running()) {
        VMError::set_safepoint_timed_out_thread(cur_thread);
        if (!os::signal_thread(cur_thread, SIGILL, "blocking a safepoint")) {
          break;
        }
```

**Takeaway:** `begin()` grabs `Threads_lock` so no thread can start or exit
mid-arming, then calls `arm_safepoint()` (the page-protect operation from
3.5.2), and waits, tracked via `_waiting_to_block`. HotSpot also ships a
built-in watchdog (`SafepointTimeout`/`AbortVMOnSafepointTimeoutDelay`)
that, past a configurable delay, forcibly sends `SIGILL` to whichever
thread hasn't reached its poll — a thread can, in production, simply fail
to reach a safepoint in reasonable time, and the VM's answer is to crash
that thread deliberately rather than hang forever. This is the closest
direct JVM analogue to the Go pre-1.14 failure mode (Part 1.3): HotSpot
has an explicit, source-visible failsafe for it, while Go's answer was to
change the preemption mechanism so the stuck case couldn't occur at all.

**Open question:** what `arm_safepoint()`'s wait-barrier implementation
does at the OS level (mentioned as `_wait_barrier->description()` but not
read here) — the next step to fully trace the mechanism from "STW
requested" to "all threads confirmed parked."

### 3.5.3 Why Go didn't reuse this approach

Go's runtime doesn't have a JIT emitting per-loop poll instructions the way
HotSpot's C1/C2 compilers do — Go compiles ahead-of-time, and the
project's own tried-and-rejected loop-back-edge check (Part 1.3) is
functionally the *interpreter-style* version of HotSpot's mechanism minus
the page-fault trick: an explicit conditional branch at every loop
iteration, not a trap-backed memory read. That 7.8% regression is
consistent with paying interpreter-tier overhead in what should be
compiled-tier code — HotSpot avoids this cost by making the poll a load
the branch predictor and speculative execution can mostly hide, and by only
weaponizing it into an actual trap at the moment a safepoint is requested,
not on every iteration unconditionally. Go's signal-based async safe-points
sidestep the problem differently: instead of a poll executed by the
goroutine itself, the OS interrupts the thread from outside, at zero
steady-state cost, and the runtime only pays for stack-map lookups on the
rare occasions a preemption is actually requested.

### 3.5.4 Checkpoint

Both HotSpot's polling and Go's pre-1.14 back-edge checks impose steady-state
cost on every loop iteration. What's the qualitative difference in *how*
they impose it, and why does that explain why one shipped and the other
was measured at 7.8% and rejected? (Answer: HotSpot's poll is a single
memory load against a page the CPU can usually predict/cache — cheap even
paid unconditionally, and JIT-compiled so it's tuned per hot loop; Go's
back-edge check was a comparison-and-branch against a stack guard variable,
inserted by a non-JIT ahead-of-time compiler across *all* loops uniformly,
without HotSpot's runtime profiling to place it selectively.)

---

## Part 4 — Comparison: the safe-point problem, side by side

| | Go | Kotlin (JVM) | BEAM |
|---|---|---|---|
| Concurrency unit | Goroutine (runtime-managed stack) | Coroutine (compiler-transformed continuation) | Process (VM-managed, isolated heap) |
| Who controls switching | Go runtime scheduler (GMP) | Compiler-generated state machine + dispatcher | BEAM scheduler (per-core) |
| Preemption style | Non-cooperative (signal, SIGURG) constrained by safe-points | Cooperative (suspend points only) | Non-cooperative (reduction counting) |
| Memory model | Shared heap across goroutines | Shared heap across coroutines (same JVM heap) | Isolated heap per process |
| GC scope | Whole-process; STW phases need all goroutines at a safe-point | Whatever JVM GC is running; safe-points are a separate JIT-polling mechanism unrelated to coroutines | Per-process; one process's GC pause never affects others |
| What can go wrong if preempted incorrectly | GC sees stale/invalid pointer, collects live object | N/A — nothing is force-preempted | N/A — no shared state to corrupt |
| Fault containment | A panic in one goroutine can crash the process unless recovered | An exception in one coroutine can propagate per structured-concurrency scope | A crash is isolated to one process by construction |

**The one-sentence unification:** the safe-point problem exists exactly
where preemption is non-cooperative *and* memory is shared — Go has both
and pays for it with stack maps and signal handling; BEAM has non-cooperative
preemption but no shared memory, so no safe-point problem exists; Kotlin has
shared memory but no non-cooperative preemption of coroutines, so it also
sidesteps the problem, at the cost of coroutines being unable to preempt
themselves out of a runaway loop.

---

## Part 5 — GraalVM: does its safepoint mechanism actually differ from HotSpot's?

Source read directly:
[`oracle/graal` → `substratevm/src/com.oracle.svm.core/.../thread/Safepoint.java`](https://github.com/oracle/graal/blob/master/substratevm/src/com.oracle.svm.core/src/com/oracle/svm/core/thread/Safepoint.java).

GraalVM Native Image (SubstrateVM) does ahead-of-time compilation of JVM
bytecode to a native binary, replacing HotSpot entirely. It changes startup
time and memory footprint substantially, and removes JIT-recompilation-
triggered safepoints (no JIT running concurrently). It does **not** change
the Kotlin coroutine suspension model — the CPS transform happens in the
Kotlin compiler before GraalVM ever sees bytecode (Part 2). But the
safepoint mechanism itself — the thing Part 3.5 covered for HotSpot — is
genuinely different in SubstrateVM, not just a reimplementation of the same
idea, which is worth being precise about since it's easy to assume "still
the JVM, so still a poll page."

**`Safepoint.java`'s own class-level doc comment, quoted because the
mechanism it describes is the whole finding:**

```java
/**
 * Manages the initiation of safepoints. A safepoint is a global state where all Java threads,
 * except one, are paused so that invasive operations (such as a garbage collection) can execute
 * without interferences.
 *
 * When a safepoint is requested, one Java thread (the master) acquires the
 * {@link VMThreads#SAFEPOINT_MUTEX}. The master notifies all other threads about the pending
 * safepoint by modifying each thread's {@link SafepointCheckCounter} thread-local.
 *
 * Each Java threads periodically checks the value of its {@link SafepointCheckCounter}. If a
 * safepoint is pending, the thread enters the safepoint slowpath and blocks on the mutex that the
 * master is holding.
 */
```

And the actual arming operation, which negates rather than page-protects:

```java
value = SafepointCheckCounter.getVolatile(thread);
} while (!SafepointCheckCounter.compareAndSet(thread, value, -value));
```

**Takeaway:** HotSpot arms a safepoint by protecting a shared
*memory page* (Part 3.5.2) — every thread's poll is a load against the same
address, and the trap is a hardware page fault. SubstrateVM arms a
safepoint by **negating each thread's own counter value** via CAS — there
is no shared page, no page fault, no signal involved in the common path at
all. Each compiled method decrements its thread-local
`SafepointCheckCounter` periodically (mirroring HotSpot's loop-back-edge/
method-entry poll *placement* from Part 3.5.2a, but checking a counter
going negative instead of reading a protected page); when a thread notices
its own counter went negative, it takes the slowpath and blocks on
`SAFEPOINT_MUTEX`. This is architecturally closer to BEAM's reduction
counting (Part 3.3) than to HotSpot's own poll-page trap — a per-thread
software counter, not a shared trap-triggering memory region — even though
SubstrateVM is still fundamentally a JVM-semantics runtime, not a
process-isolated one. It's a genuine mechanism swap under the same
"safepoint" name, not a cosmetic difference.

**Open question:** why Oracle's SubstrateVM engineers chose a per-thread
counter over reusing HotSpot's poll-page approach — the file doesn't
state the rationale. Plausible candidates (avoiding `mprotect` syscalls
per arm/disarm cycle, better behavior under isolates/multi-tenant native
images) are not confirmed by the source.

**Checkpoint:** if your bottleneck is coroutine scheduling latency, does
GraalVM help? (Answer: no — that's a compile-time property of the Kotlin
coroutine transform, orthogonal to which VM executes the resulting
bytecode.) Separately: does GraalVM's safepoint mechanism reduce
"time to safepoint" compared to HotSpot's for the same reason BEAM's does?
(Answer: not for the same reason — BEAM's advantage is structural, no
shared memory to protect at all; SubstrateVM still has a shared heap and
still needs a global stop, it's only changed *how* each thread notices
the request, not the fact that all threads must eventually be stopped
together.)

---

## Part 6 — The GC algorithms behind the flags

The copy of *The Garbage Collection Handbook* at `~/Documents/Books_on_vm/`
is the **2023 second edition**, and it covers G1, ZGC, and Shenandoah by
name with dedicated sections. What follows is read directly from that PDF
(page numbers are the book's own page numbers, printed in each page
header — the PDF file's own page index has a fixed +37 offset from these,
front matter accounts for the difference).

### 6.1 The tricolor abstraction: base algorithm before the formal invariant

Source: Robert Nystrom, [*Crafting Interpreters*, "Garbage Collection"](https://craftinginterpreters.com/garbage-collection.html)
(also read in this research thread — see `003_research.md` in this
directory). Nystrom's chapter gives the base mark-sweep tricolor algorithm
in intuitive terms, before the GC Handbook's formal correctness theorem
below:

```
1. Start off with all objects white.
2. Find all the roots and mark them gray.
3. Repeat as long as there are still gray objects:
    a. Pick a gray object. Turn any white objects that the object
       mentions to gray.
    b. Mark the original gray object black.
```

The "gray wavefront" image: roots turn gray, each gray object's neighbors
turn gray while the object itself turns black, and the wavefront advances
through the graph leaving reached (black) objects behind it, sweeping
white-and-untouched objects up as garbage once no gray objects remain.

<img src="/img/posts/concurrency-and-gc_tricolor-trace.png" alt="tricolor mark-sweep wavefront" style="width: 100%; object-fit: contain;" />

*Image: Robert Nystrom, Crafting Interpreters, "Garbage Collection"
(craftinginterpreters.com/garbage-collection.html), used here per the
site's stated terms for educational reference.*

### 6.1a The formal version of the same invariant

The Go runtime's own version of this invariant, from
[`src/runtime/mgc.go`](https://github.com/golang/go/blob/master/src/runtime/mgc.go),
`gcStart`'s STW-to-mark-phase transition — the full sequence, not just the
one line:

```go
	// Enter concurrent mark phase and enable
	// write barriers.
	//
	// Because the world is stopped, all Ps will
	// observe that write barriers are enabled by
	// the time we start the world and begin
	// scanning.
	//
	// Write barriers must be enabled before assists are
	// enabled because they must be enabled before
	// any non-leaf heap objects are marked. Since
	// allocations are blocked until assists can
	// happen, we want to enable assists as early as
	// possible.
	setGCPhase(_GCmark)

	gcBgMarkPrepare() // Must happen before assists are enabled.
	gcPrepareMarkRoots()

	// Mark all active tinyalloc blocks. Since we're
	// allocating from these, they need to be black like
	// other allocations. The alternative is to blacken
	// the tiny block on every allocation from it, which
	// would slow down the tiny allocator.
	gcMarkTinyAllocs()

	// At this point all Ps have enabled the write
	// barrier, thus maintaining the no white to
	// black invariant. Enable mutator assists to
	// put back-pressure on fast allocating
	// mutators.
	atomic.Store(&gcBlackenEnabled, 1)
```

Read top to bottom, this is the actual order of operations at the start
of a mark phase: (1) `setGCPhase(_GCmark)` flips the global phase while
the world is still stopped, so every P will see the new phase the instant
it resumes; (2) `gcBgMarkPrepare()` and `gcPrepareMarkRoots()` set up the
background mark workers and root-scanning job queue *before* anything is
allowed to mark, per the comment's own stated ordering constraint (write
barriers before assists, assists before marking); (3) `gcMarkTinyAllocs()`
retroactively blackens small allocations already carved out of the tiny
allocator, so they don't need individual barrier coverage; (4) only then
does `atomic.Store(&gcBlackenEnabled, 1)` actually arm the write barrier
Part 1.3a's `mbarrier.go` checks — the comment's "no white to black
invariant" claim is true starting at this exact store, not before it.
Everything above this line is setup that must complete first because the
invariant would be violated if the barrier were armed before roots were
prepared.

**§15.1, "The tricolour abstraction, revisited"** (p.331) restates this
exact comment as a general, two-condition correctness theorem, attributed
to Wilson [1994]:

```
Condition 1: the mutator stores a pointer to a white object into a black object, and
Condition 2: all paths from any grey objects to that white object are destroyed.
```

**Takeaway:** an object only gets incorrectly collected if
*both* conditions hold simultaneously — a black object gains a hidden
white pointer, *and* every path the collector could have used to
rediscover that white object independently gets cut. Break either
condition and the collector stays correct. This immediately generalizes
into two named invariants, quoted directly:

```
The weak tricolour invariant: All white objects pointed to by a black
object are grey protected (that is, reachable from some grey object,
either directly or through a chain of white objects).

The strong tricolour invariant: There are no pointers from black
objects to white objects.
```

**Takeaway:** Go's hybrid barrier (Yuasa deletion + Dijkstra insertion) is
an example of a barrier that enforces something between these two — Go's
comment said "no white to black," which is the strong invariant stated
for Go's specific non-moving collector. Non-moving collectors like Go's
can get away with only the weak invariant ("white pointers in black
objects are not a problem because their grey protected white targets are
eventually shaded"), while concurrent copying collectors must preserve
the strong invariant, because a moving collector discards the fromspace
white copy entirely at cycle end — a black tospace object still pointing
at a discarded fromspace address is a dangling pointer, not just a late
mark. This is the precise reason ZGC/Shenandoah (both moving) and Go
(non-moving) need structurally different barrier strength.

### 6.2 §11.6 — the vendor-agnostic version of Part 3.5

**§11.6, "GC safe-points and mutator suspension"** (p.198) makes a
distinction Part 3.5 didn't have a name for: **GC safe-points vs. GC
check-points.**

```
Many systems make the opposite choice and only allow garbage collection
at certain restricted safe-points, and only produce maps for those
points. The minimal set of safe-points needed for correctness includes
each allocation ... and each call of a routine in which there may be
allocation or which may cause the thread to suspend in a wait.
```
```
Since these additional safe-points do not do anything that actually can
trigger a garbage collection, they need to have an added check for
whether garbage collection is needed/requested, so we call them GC
check-points.
```

**Takeaway:** a safe-point is *any* point where the machine
state is GC-inspectable; a check-point is the (much smaller) subset where
the runtime has also inserted code to actually test "should I stop right
now." HotSpot's poll-page instructions (Part 3.5.2) are check-points in
this vocabulary — they're placed at loop back-edges and method entries,
which the book independently identifies as the correct minimal placement
("there needs to be a safe-point in each loop; a simple rule is to place a
safe-point at each backwards branch in a function... in addition there
needs to be a safe-point in each function entry or each return"). This is
the same placement rule Gil Tene's account (Part 3.5.2a) gave for HotSpot
specifically — the book states it as the general principle HotSpot (and
Go's old back-edge check, and SubstrateVM's counter) are all independent
instances of.

The book also names the exact two mechanisms this document found in two
different runtimes and treats them as one general dichotomy, citing
Agesen [1998]:

```
Agesen [1998] compared two ways of causing a thread to suspend at a
GC-point. One is polling ... The other technique is patching, which
involves modifying the code at the next GC-point(s) of the thread.
```

**Takeaway:** HotSpot's poll-page (Part 3.5.2) is "polling."
Go's pre-1.14 stack-bound-check poisoning (Part 1.3) is closer to
"patching" in spirit — the runtime rewrites `stackguard0` so the *existing*
bound check becomes a trap, rather than adding a new check. Go's post-1.14
`SIGURG` mechanism is neither in Agesen's original two-way split — it's a
third strategy (async external interrupt) the 1998 taxonomy predates,
which is a useful thing to know precisely: SIGURG isn't a variant of
polling or patching, it's a genuinely later addition to the design space.

### 6.3 G1 — the actual phase list, not just the region idea

**§16.5, "Garbage-First: collecting young and old regions"** (p.354)
gives OpenJDK 20's actual mixed-collection phase sequence, not just the
region-prioritization idea Part 6's original version described. Quoting
the phase list directly (abridged):

```
Start: This stop-the-world phase is piggy-backed on a 'young only'
collection that seeds the roots for concurrent marking. ... G1 sets a
Top At Mark Start (TAMS) variable for each region; any objects allocated
at addresses above the TAMS for a region will be considered implicitly
live/marked.

Concurrent Mark From Roots: ... using a snapshot-at-the-beginning
algorithm, with mutators using a deletion barrier ... G1 marking threads
... Each thread first claims a region to mark by atomically advancing a
global 'finger' to the right.
```

**Takeaway:** TAMS is the mechanism that lets G1 avoid
marking newly-allocated objects at all — anything allocated after
marking starts in a region is *assumed* live by address comparison alone,
no barrier or scan needed for it. This is a genuinely different strategy
from Go's approach (Part 1.3a), where new allocations are marked black
immediately via `gcBlackenEnabled`-gated behavior — G1's TAMS threshold
achieves a similar goal (don't waste work on new objects) through a
different mechanism (an address comparison per region, not a global
allocation-color flag). The book also names G1's barrier as a **deletion**
barrier specifically (snapshot-at-the-beginning), which is the Yuasa half
only, not Go's hybrid Yuasa+Dijkstra combination — a real algorithmic
difference between the two collectors' barriers not visible from the JEP
alone.

### 6.4 ZGC — colored pointers, confirmed with the actual bit layout

**§17.5** describes ZGC [Lidén, 2018] and gives the actual pointer bit
layout (Figure 17.4) rather than just naming "colored pointers" as a
concept:

```
ZGC uses tagged pointers and self-healing load barriers. ... A group of
four higher-order bits determine a colour. The four bits are named F
(finalisable), R (relocated), M1 and M0 (marked). A given pointer will
have only one of R, M0 and M1 set ... At any given time, only one of R,
M0 or M1 is the good colour; loading pointers of other colours forces a
load barrier slow path.
```

**Takeaway:** "colored pointer" isn't metaphorical — it's four specific
bits (F/R/M0/M1) living in the unused high bits of a 64-bit pointer, on a
system where the actual address only needs 47 bits (the address bits span
roughly bit 46 down to 0, leaving room above for tag bits). Self-healing:
when a thread loads a pointer with a stale colour, the load barrier fixes
the colour in place via the barrier's slow path, so subsequent loads of
that same memory location by the same thread don't re-trigger the slow
path. This is a materially different mechanism from both Go's write
barrier (fires on writes, not reads) and G1's deletion barrier (also
write-side) — ZGC's barrier fires on reads.

### 6.5 Shenandoah

**§17.5, "Shenandoah"** (p.401) gives both the algorithm and, notably, a
sentence where the cited authors question their own earlier design
argument:

```
In 2016 Flood et al. argued that programs such as web caches hold onto
objects just long enough to defeat generational collectors so, instead,
Shenandoah focuses its effort on regions with fewer live objects...
They also argued that generational collection requires some kind of
remembered set... However, it is not clear that these concerns still
hold and implementation of a generational version of Shenandoah is in
progress.
```

**Takeaway:** as of 2023, Shenandoah's own foundational 2016 design
argument (why not to be generational) is under active reconsideration by
its own authors, with a generational variant in progress — a different
picture than a static "Shenandoah is non-generational, ZGC is
non-generational" fact would give; the field is mid-revision on this
point, not settled.

The self-healing load barrier itself, given as actual pseudocode
(Algorithm 17.12), is worth comparing line-by-line against ZGC's:

```
Read(src, i):
    addr ← &src[i]
    obj ← *addr
    if not isGCactive()             /* fast path: accesses thread-local flag */
        return obj
    if not isInCollectionSet(obj)
        return obj
    fwd = resolveForwardee(obj)     /* access forwarding pointer, if one */
    if obj ≠ fwd
        CAS(addr, fwd, obj)         /* self-heal */
        return fwd
```

**Takeaway:** Shenandoah's self-healing works by CAS-ing the
*forwarding pointer* back into the original slot once discovered — a
different self-healing mechanism than ZGC's colored-pointer remap, but the
same goal (pay the barrier cost once per location, not once per access).
The `isGCactive()` fast-path check is functionally the same shape as G1's
`gcBlackenEnabled` and Go's `gcphase == _GCmark` gating (Part 1.3a) — all
three collectors pay for their respective barrier machinery only during an
active cycle, confirmed independently now in three different codebases and
this one textbook description.

### 6.6 Compressor and Pauseless/C4: page protection vs. tagged pointers

**§17.5, "Compressor"** (p.386) and **"Pauseless and C4"** (p.387–388).

Compressor's mechanism, from the book's own category list:

```
Live: pages containing (mostly) live objects
Condemned: pages containing some live objects, but mostly dead ones
Free: pages currently free but available for allocation
New Live: pages in which copied live objects have been allocated but not yet copied
Dead: unmapped pages that can be recycled once there are no pointers to them
```

**Takeaway:** Compressor drives compaction entirely through page
protection — it `mprotect`s tospace pages so any mutator access traps,
and the trap handler performs forwarding/copying on demand. This is the
same style of mechanism as HotSpot's safepoint poll page (Part 3.5.2) —
a hardware trap doing useful work, not just a stop signal — applied to
compaction correctness rather than safepoint arrival: the same trick
generalizes to enforcing GC invariants during copying, not just to
synchronizing mutator suspension.

Pauseless/C4's mechanism, by contrast, avoids page protection almost
entirely and uses **tagged pointers** instead — confirmed by the actual
bit layout (Figure 17.2, p.388):

```
Pauseless steals one address bit from the 64-bit address space to use as
a pointer tag. This Not-Marked-Through (NMT) bit is used by the LVB
during the concurrent marking phase of the collector to decide whether
the reference has previously been scanned by the collector.
```

**Takeaway:** C4/Pauseless's LVB ("Loaded Value Barrier") is functionally
the same idea as ZGC's self-healing colored-pointer load barrier
(Part 6.4) — both steal address bits, both self-heal on load. ZGC's
design (2018) comes after and builds on Azul's Pauseless/C4 (2005/2011),
not as an independent invention. C4's generational extension steals an
additional tag bit per pointer to track which generation the referent
belongs to, letting young and old collections proceed independently
without cross-checking a single global NMT value.

**Open question:** whether ZGC's generational variant (Figure 17.4b) has
an analogous bit-budget tradeoff to C4's — not verified against ZGC's
generational tagged-pointer figure directly.

### 6.7 Staccato

**§19.7, "Staccato: best-effort compaction with mutator wait-freedom"**
(p.455) — the McCloskey et al. paper also referenced in
`006_other_reading_materials.md` of this research directory.

```
Staccato [McCloskey et al., 2008] permits concurrent compaction without
requiring the mutators to use locks or atomic operations like
compare-and-swap in the common case, even on multiprocessors with weak
memory ordering.
```

The mechanism, confirmed via the book's own pseudocode (Algorithm 19.8):

```
copyObjects(candidates):
    for each p in candidates
        CompareAndSet(&forwardingAddress(p), p, p | COPYING)
        waitForRaggedSynch(writeFence; readFence)
        ...
```

**Takeaway:** "ragged synchronisation" is the general name for a pattern
this document already touched via Collie's "pre-compaction ragged
handshake" (Part 6.6) and §15.3's "Ragged phase changes": instead of a
single global stop-the-world rendezvous, each mutator independently
performs a memory fence "at regular intervals (such as GC safe-points),"
and the collector waits for all mutators to have crossed that fence
individually, at their own pace — a distributed handshake rather than a
synchronized barrier. This is a different STW-avoidance strategy than
HotSpot's single global `Threads_lock`-based rendezvous (Part 3.5.2b).

### 6.8 Scope note and further reading

Not covered above: Ch.14 (parallel GC internals — marking, copying,
compaction algorithms), Tax-and-Spend (§19.6). Sapphire, Transactional
Sapphire, Platinum, Metronome, Stopless, Chicken, and Clover are covered
in the appendix below (§19.5–19.7), not in the numbered sections above.

Vendor/JEP-level pointers, for the production-flag view rather than the
algorithm view:
- [JEP 248 — Make G1 the Default Garbage Collector](https://openjdk.org/jeps/248)
- [JEP 439 — Generational ZGC](https://openjdk.org/jeps/439)
- [JEP 318 — Epsilon: A No-Op Garbage Collector](https://openjdk.org/jeps/318)
- [OpenJDK ZGC wiki](https://wiki.openjdk.org/display/zgc/Main)
- [OpenJDK Shenandoah wiki](https://wiki.openjdk.org/display/shenandoah/Main)
- [GraalVM Native Image `MemoryManagement.md`](https://github.com/oracle/graal/blob/master/docs/reference-manual/native-image/MemoryManagement.md) — `--gc=serial|G1|epsilon` flags

### 6.9 Sapphire, Platinum, Metronome, Stopless, Chicken, Clover

**Sapphire and Transactional Sapphire** (§17.4, p.376–379) — a concurrent
copying algorithm for shared-memory multiprocessors that lets one mutator
thread at a time flip from reading fromspace to reading tospace, rather
than stopping all threads to flip together. Transactional Sapphire
extends this with parallel collector threads and hardware/software
transactions for object copying, moving through four phase groups (Mark,
Copy, Flip, Reclaim — Algorithm 17.4) with distinct write barriers per
phase.

```
Flip: In this group, the collector forwards pointers in global variables
and thread stacks and registers, flipping them one at a time into
tospace. Unflipped mutator threads may hold references to both fromspace
and tospace copies (even of the same object).
```

**Takeaway:** incremental flipping (one thread at a time, rather than a
single stop-the-world flip) is the mechanism's whole point — it trades a
more complex barrier (mutators may see both copies of the same object
simultaneously) for a shorter window where any thread needs to block.

**Platinum** (§17.4, p.383–384) — mostly-concurrent, generational,
replicating, aimed at long tail latencies. Uses fewer collector threads
than cores and binds each to a specific core, and uses Intel's memory
protection keys (not a syscall-heavy `mprotect`, but a fast per-thread
register) to give collector and mutator threads different access rights
to the same pages without a full page-table change.

```
Platinum sets up two protection keys. During collection, one is
associated with pages to which only the collector threads should have
write access, and Platinum arranges that the mutators set their
protection keys to disallow writes to these pages.
```

**Metronome** (§19.5, p.439–441) — a time-based real-time collector for
Java: an incremental mark-sweep collector with partial on-demand
compaction, scheduled via fixed time quanta (500µs collector slices in a
10ms window) to guarantee a minimum mutator utilization (MMU) target,
commonly 70%.

**Stopless** (§19.7, p.454–455) — a lock-free concurrent compactor. Rather
than requiring mutators to update both a fromspace and tospace copy of an
object (as Sapphire does), Stopless enforces that exactly one copy is
ever the definitive one, tracked via a double-word compare-and-swap on a
"wide" intermediate copy with a status word per field
(`inOriginal`/`inWide`/`inCopy`).

**Chicken** (§19.7, p.458) — architecturally close to Staccato (Part 6.7),
developed independently, targeting x86/x86-64's stronger memory model
specifically. Because that architecture orders reads relative to atomics,
only writes need to abort an in-progress copy, and the ragged
synchronisation Staccato relies on doesn't need the read-fence half.

**Clover** (§19.7, p.458–459) — guarantees compaction with lock-free
mutator access in the common case by having the collector mark
just-copied fields with a reserved sentinel value α (chosen to make
collision with a real program value astronomically unlikely, using a
128-bit compare-and-swap on modern x86-64). A mutator that reads α knows
to reload the field through the forwarding pointer instead.

---

## Part 7 — Reading this material in passes, not linearly

The framework below is applied selectively, not as a checklist run against
every source uniformly — some of these materials don't have all five
properties (a rejected-alternatives section, an admitted weak spot), and
forcing the framework onto a source that doesn't have that structure would
produce a false pattern rather than an honest one. Where a technique
doesn't fit a given source, it's left out for that source rather than
padded in.

**The one dominant constraint** applies cleanly to Go (GC needs pointer
maps → constrains preemption, Part 1.3), to BEAM (shared-nothing →
no safe-point problem, Part 3.2–3.3a), and to Kotlin (can't modify the
JVM → CPS transform is the only lever, Part 2.1). It applies less cleanly
to the GC algorithms in Part 6 — G1, ZGC, and Shenandoah are all solving
the *same* constraint (bound pause time independent of heap size) with
different mechanisms, so for that cluster the useful move is comparing
mechanisms against a shared constraint, not finding a different
constraint for each.

**An admitted weak spot / rejected path** is present, concretely, in three
places already surfaced in this document, not hypothetically: Go's
proposal rejecting loop-back-edge checks over a measured 7.8% regression
(Part 1.3), HotSpot's own `AbortVMOnSafepointTimeout` watchdog admitting a
thread can simply fail to reach a safepoint in production (Part 3.5.2b),
and Shenandoah's authors' 2023-dated uncertainty about their own 2016
non-generational argument (Part 6.5). These three are the highest-value
re-reads in the whole document if you only have time to revisit three
things.

### 7.1 Concept mindmap — the tension map, not a fact list

```mermaid
mindmap
  root((Preempt a running<br/>task safely))
    Who initiates preemption
      OS timer interrupt
        No cooperation needed
        Thread has no say
      Go: SIGURG signal
        Async, external
        Still gated by safe-point check
      HotSpot: poll page
        Thread checks itself
        Trap turns it involuntary
      SubstrateVM: counter CAS
        Per-thread, no shared page
      BEAM: reduction counter
        Every instruction dispatch
        No separate check needed
    What makes a point unsafe
      Shared GC-managed heap
        Pointer vs raw int ambiguity
        Go stack maps
        HotSpot stack maps
      No shared heap at all
        BEAM sidesteps the question
        Every point is already safe
    GC correctness invariant
      Weak tricolour
        Non-moving OK
        Go hybrid barrier
      Strong tricolour
        Required for moving GC
        ZGC load barrier
        Shenandoah load barrier
        G1 deletion barrier
    Concurrency unit
      Go: goroutine, CSP channels
      Kotlin: continuation, CPS
        compiler layer
        kotlinx.coroutines layer
      BEAM: process, shared nothing
```

**What this diagram is arguing, in one sentence per branch:** preemption
mechanisms differ in *who* decides to stop a task; safety mechanisms
differ in *whether* shared GC-managed memory makes most points unsafe to
stop at; GC correctness reduces to which tricolour invariant a collector
can afford to only weakly enforce, which is itself downstream of whether
the collector moves objects. The three top-level branches are not
independent — the "who initiates" answer each language chose was
constrained by the "what makes a point unsafe" answer their memory model
already committed them to.

### 7.2 Reading roadmap — four passes across this document's actual source list

```mermaid
flowchart TD
    subgraph P1["Pass 1 — Orient: what problem is being solved"]
        direction LR
        A1["Go proposal 24543<br/>abstract + problem statement"]
        A2["mgc.go header comment<br/>(algorithm summary, lines 1-20)"]
        A3["Safepoint.java class doc<br/>(GraalVM)"]
        A4["GC Handbook §1.3<br/>Comparing GC algorithms"]
    end

    subgraph P2["Pass 2 — Find the one constraint"]
        direction LR
        B1["preempt.go safe-point<br/>categories comment"]
        B2["signal_unix.go SIGURG<br/>4-criteria rationale"]
        B3["Continuation.kt<br/>+ why suspend is compiler-level"]
        B4["erl_process.h fcalls comment<br/>+ Part 3.2 shared-nothing"]
        B5["GC Handbook §11.6<br/>safe-point vs check-point"]
    end

    subgraph P3["Pass 3 — Map rejected paths and tensions"]
        direction LR
        C1["Go: loop back-edge check,<br/>7.8% regression, rejected"]
        C2["HotSpot: SafepointTimeout<br/>watchdog admits failure mode"]
        C3["Shenandoah §17.5: authors<br/>question own 2016 argument"]
        C4["Agesen 1998: polling vs<br/>patching vs SIGURG (3rd path)"]
    end

    subgraph P4["Pass 4 — Compress to one sentence per system"]
        direction LR
        D1["Go: non-cooperative,<br/>gated by pointer safety"]
        D2["Kotlin: cooperative by<br/>construction, no interrupt exists"]
        D3["BEAM: no unsafe points<br/>exist, only a budget"]
        D4["JVM family: same constraint<br/>(bounded pause), different<br/>mechanism per collector"]
    end

    P1 --> P2 --> P3 --> P4

    A1 -.reread after.-> C1
    B2 -.reread after.-> C4
    B5 -.reread after.-> C2
```

**How to actually use this roadmap:** don't read every box once in order —
Pass 1 across all four sources first (just enough to know what problem
each is solving), then Pass 2 across all four (find the load-bearing
constraint in each), then Pass 3 only for the sources that have a rejected
path or admitted gap (not all of them do — Continuation.kt, for instance,
doesn't have a "we tried X and rejected it" moment the way Go's proposal
or Shenandoah's retrospective do), then Pass 4 forces you to write the
one-sentence compression for each system, which is the actual test of
whether the first three passes worked. If you can't write Pass 4's
sentence for a system, that's the signal to go back to Pass 2 for that
system specifically, not to reread everything.

---

## Source references for going deeper (only if a checkpoint above stumps you)

### Primary source files fetched and read directly for this document

**Go** (golang/go, master):
- [`src/runtime/preempt.go`](https://github.com/golang/go/blob/master/src/runtime/preempt.go)
- [`src/runtime/signal_unix.go`](https://github.com/golang/go/blob/master/src/runtime/signal_unix.go)
- [`src/runtime/mgc.go`](https://github.com/golang/go/blob/master/src/runtime/mgc.go)
- [`src/runtime/proc.go`](https://github.com/golang/go/blob/master/src/runtime/proc.go)
- [`src/runtime/mbarrier.go`](https://github.com/golang/go/blob/master/src/runtime/mbarrier.go)

**Kotlin/kotlinx.coroutines**:
- JetBrains/kotlin → [`libraries/stdlib/src/kotlin/coroutines/Continuation.kt`](https://github.com/JetBrains/kotlin/blob/master/libraries/stdlib/src/kotlin/coroutines/Continuation.kt)
- JetBrains/kotlin → [`libraries/stdlib/src/kotlin/coroutines/intrinsics/Intrinsics.kt`](https://github.com/JetBrains/kotlin/blob/master/libraries/stdlib/src/kotlin/coroutines/intrinsics/Intrinsics.kt)
- Kotlin/kotlinx.coroutines → [`kotlinx-coroutines-core/common/src/CoroutineDispatcher.kt`](https://github.com/Kotlin/kotlinx.coroutines/blob/master/kotlinx-coroutines-core/common/src/CoroutineDispatcher.kt)
- Kotlin/kotlinx.coroutines → [`kotlinx-coroutines-core/jvm/src/scheduling/CoroutineScheduler.kt`](https://github.com/Kotlin/kotlinx.coroutines/blob/master/kotlinx-coroutines-core/jvm/src/scheduling/CoroutineScheduler.kt)
- Kotlin/kotlinx.coroutines → [`kotlinx-coroutines-core/common/src/internal/DispatchedContinuation.kt`](https://github.com/Kotlin/kotlinx.coroutines/blob/master/kotlinx-coroutines-core/common/src/internal/DispatchedContinuation.kt)
- (attempted, 404) `.../intrinsics/CoroutineIntrinsics.kt` — doesn't exist at that path, discarded

**OpenJDK/HotSpot** (openjdk/jdk, master):
- [`src/hotspot/share/runtime/safepoint.hpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/safepoint.hpp)
- [`src/hotspot/share/runtime/safepointMechanism.hpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/safepointMechanism.hpp)
- [`src/hotspot/share/runtime/safepoint.cpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/safepoint.cpp)

**GraalVM/SubstrateVM** (oracle/graal, master):
- [`substratevm/src/com.oracle.svm.core/src/com/oracle/svm/core/thread/Safepoint.java`](https://github.com/oracle/graal/blob/master/substratevm/src/com.oracle.svm.core/src/com/oracle/svm/core/thread/Safepoint.java)
- [`docs/reference-manual/native-image/MemoryManagement.md`](https://github.com/oracle/graal/blob/master/docs/reference-manual/native-image/MemoryManagement.md) — official docs, `--gc=serial|G1|epsilon` flags and defaults

### The Garbage Collection Handbook, 2nd ed. (2023) — read directly, local PDF

`~/Documents/Books_on_vm/Jones, Richard - The Garbage Collection Handbook...pdf`
(Jones, Hosking, Moss; Chapman and Hall/CRC, 2023). Sections read directly
for Part 6: §11.6 "GC safe-points and mutator suspension" (p.198), §15.1
"Correctness of concurrent collection" / tricolour invariants (p.331–334),
§16.5 "Garbage-First: collecting young and old regions" (p.354), §17.4
"Replication copying" — Sapphire, Transactional Sapphire, Platinum
(p.376–384), §17.5 "Concurrent compaction" — Compressor (p.386),
Pauseless/C4 (p.387–388), Collie (p.395), ZGC (p.396), Shenandoah (p.401),
§19.5 "Metronome" (p.439–441), §19.7 "Controlling fragmentation" —
Staccato, Stopless, Chicken, Clover (p.453–459). Not yet read directly:
Ch.14 (parallel GC internals), §19.6 "Tax-and-Spend" (p.448).

### GC algorithms (Part 6) — not read as source, cited as pointers for later reading

- [JEP 248 — Make G1 the Default Garbage Collector](https://openjdk.org/jeps/248)
- [JEP 439 — Generational ZGC](https://openjdk.org/jeps/439)
- [JEP 318 — Epsilon: A No-Op Garbage Collector](https://openjdk.org/jeps/318)
- [OpenJDK ZGC wiki](https://wiki.openjdk.org/display/zgc/Main)
- [OpenJDK Shenandoah wiki](https://wiki.openjdk.org/display/shenandoah/Main)
- Detlefs, Flood, Heller, Printezis, "Garbage-First Garbage Collection" (ISMM 2004) — search title, not linked directly
- Flood, Ross, Shipilev et al., "Shenandoah: An Open-Source Concurrent Compacting Garbage Collector for OpenJDK" (2016) — search title, not linked directly

**Erlang/OTP** (erlang/otp, master):
- [`erts/emulator/beam/erl_process.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_process.c)
- [`erts/emulator/beam/erl_process.h`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_process.h)
- [`erts/emulator/beam/erl_vm.h`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_vm.h)
- [`erts/emulator/beam/emu/beam_emu.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/emu/beam_emu.c)
- [`erts/emulator/beam/erl_gc.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_gc.c)
- [`erts/emulator/beam/erl_bif_info.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_bif_info.c) (grep only, minimal use)

### Crafting Interpreters — read directly (via `003_research.md`, this directory)

Robert Nystrom, [*Crafting Interpreters*, "Garbage Collection"](https://craftinginterpreters.com/garbage-collection.html)
— base mark-sweep and tricolor abstraction (Part 6.1); the tricolor
wavefront image used in Part 6.1 is sourced from this chapter.

### Secondary sources (pasted/cited, not independently fetched for this doc)

- Sunny Srinidhi, ["Under the Hood: Java Peak Safepoints"](https://medium.com/software-under-the-hood/under-the-hood-java-peak-safepoints-dd45af07d766)
- Nitsan Wakart / Gil Tene (mechanical-sympathy list), ["Safepoints: Meaning, Side Effects and Overheads"](http://psy-lob-saw.blogspot.com/2015/12/safepoints.html)
- ["What is a Java Safepoint?"](http://chriskirk.blogspot.com/2013/09/what-is-java-safepoint.html)
- ["Safety First: Safepoints"](http://jpbempel.blogspot.com/2013/03/safety-first-safepoints.html)
