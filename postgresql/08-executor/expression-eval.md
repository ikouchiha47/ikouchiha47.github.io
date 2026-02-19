---
title: "Expression Evaluation"
layout: group_page
group: postgresql
group_title: "PostgreSQL Internals Deep Dive"
group_url: "/2025/06/01/postgresql-internals.html"
chapter: "08-executor"
chapter_title: "Executor"
chapter_url: "/postgresql/08-executor/"
---

# Expression Evaluation and JIT Compilation

## Summary

PostgreSQL compiles expression trees (WHERE clauses, projection lists, computed
columns) into flat arrays of `ExprEvalStep` instructions during executor
startup. At runtime, these steps are executed by a fast interpreted dispatch
loop that uses either a switch statement or GCC's computed-goto extension for
efficient opcode dispatch. For expensive queries, PostgreSQL can optionally
JIT-compile expressions and tuple deforming into native machine code via LLVM,
eliminating interpretation overhead entirely.

---

## Overview

Expression evaluation happens on the hot path of every tuple processed by the
executor. A `WHERE x > 10 AND y = 'foo'` clause is evaluated once per candidate
tuple. The design therefore prioritizes minimal per-tuple overhead.

### Two-Phase Design

```
Phase 1: Compilation (ExecInitExpr, once per query)
  Expression tree (Expr nodes)
    --> flat array of ExprEvalStep instructions
    --> set evalfunc pointer (interpreter or JIT)

Phase 2: Evaluation (per tuple)
  ExprState.evalfunc(expression, econtext, &isNull)
    --> execute steps sequentially
    --> return final Datum result
```

---

## Key Source Files

| File | Purpose |
|---|---|
| `src/backend/executor/execExpr.c` | Expression "compilation" to step arrays |
| `src/backend/executor/execExprInterp.c` | Interpreted step evaluation (switch/computed-goto) |
| `src/include/executor/execExpr.h` | `ExprEvalStep`, `ExprEvalOp` enum |
| `src/include/nodes/execnodes.h` | `ExprState` struct |
| `src/backend/jit/jit.c` | JIT provider infrastructure |
| `src/backend/jit/llvm/llvmjit.c` | LLVM-based JIT implementation |
| `src/backend/jit/llvm/llvmjit_expr.c` | JIT compilation of expression steps |
| `src/backend/jit/llvm/llvmjit_deform.c` | JIT compilation of tuple deforming |

---

## How It Works

### Step 1: Expression Compilation

`ExecInitExpr()` walks the expression tree and emits a flat array of
`ExprEvalStep` structs:

```c
ExprState *
ExecInitExpr(Expr *node, PlanState *parent)
{
    ExprState *state = makeNode(ExprState);
    state->expr = node;
    state->parent = parent;

    /* Compile expression tree into steps */
    ExecInitExprRec(node, state, &state->resvalue, &state->resnull);

    /* Emit final DONE step */
    ExprEvalStep scratch = {.opcode = EEOP_DONE};
    ExecPushExprSlots(state, ...);
    ExprEvalPushStep(state, &scratch);

    /* Select evaluation method */
    ExecReadyExpr(state);       /* choose interpreter or fast-path */

    return state;
}
```

Each node type in the expression tree maps to one or more opcodes:

| Expression Node | Generated Steps |
|---|---|
| `Var` (column reference) | `EEOP_INNER_VAR` / `EEOP_OUTER_VAR` / `EEOP_SCAN_VAR` |
| `Const` | `EEOP_CONST` |
| `FuncExpr` | `EEOP_FUNCEXPR` / `EEOP_FUNCEXPR_STRICT` / `EEOP_FUNCEXPR_FUSAGE` |
| `OpExpr` (operator) | Same as FuncExpr (operators are functions) |
| `BoolExpr AND` | `EEOP_BOOL_AND_STEP` + `EEOP_BOOL_AND_STEP_LAST` |
| `BoolExpr OR` | `EEOP_BOOL_OR_STEP` + `EEOP_BOOL_OR_STEP_LAST` |
| `BoolExpr NOT` | `EEOP_BOOL_NOT_STEP` |
| `NullTest` | `EEOP_NULLTEST_ISNULL` / `EEOP_NULLTEST_ISNOTNULL` |
| `CaseExpr` | `EEOP_CASE_WHEN` + jump targets |
| `ScalarArrayOp` | `EEOP_SCALARARRAYOP` |
| `Aggref` | `EEOP_AGG_PLAIN_PERGROUP_NULLCHECK` + `EEOP_AGG_PLAIN_TRANS` |
| `WindowFunc` | `EEOP_WINDOW_FUNC` |
| `SubPlan` | `EEOP_SUBPLAN` |

### Step 2: The ExprEvalStep Structure

```c
typedef struct ExprEvalStep {
    intptr_t    opcode;         /* EEOP_xxx (or computed-goto address) */
    Datum      *resvalue;       /* where to store result Datum */
    bool       *resnull;        /* where to store result null flag */

    union {
        /* EEOP_INNER/OUTER/SCAN_VAR */
        struct {
            int attnum;         /* attribute number to fetch */
            int resultnum;      /* index into tts_values/tts_isnull */
        } var;

        /* EEOP_CONST */
        struct {
            Datum value;
            bool  isnull;
        } constval;

        /* EEOP_FUNCEXPR* */
        struct {
            FmgrInfo   *finfo;          /* function lookup info */
            FunctionCallInfo fcinfo;    /* pre-allocated call info */
            int         nargs;
        } func;

        /* EEOP_BOOL_AND/OR_STEP */
        struct {
            bool       *anynull;        /* tracking null state */
            int         jumpdone;       /* step to jump to on short-circuit */
        } boolexpr;

        /* EEOP_JUMP* */
        struct {
            int         jumpdone;       /* target step index */
        } jump;

        /* EEOP_AGG_PLAIN_TRANS */
        struct {
            AggStatePerTrans pertrans;
            ExprContext      *aggcontext;
            int               setno;
            int               transno;
            int               setoff;
        } agg_trans;

        /* ... many more union members ... */
    } d;
} ExprEvalStep;
```

### Step 3: Interpreted Evaluation

`ExecInterpExpr()` is the main interpreter. It uses either a switch statement
or GCC computed gotos for dispatch:

```c
/* Computed-goto dispatch (GCC/Clang) */
#ifdef EEO_USE_COMPUTED_GOTO

static const void *const dispatch_table[] = {
    &&CASE_EEOP_DONE,
    &&CASE_EEOP_INNER_VAR,
    &&CASE_EEOP_OUTER_VAR,
    &&CASE_EEOP_SCAN_VAR,
    &&CASE_EEOP_CONST,
    &&CASE_EEOP_FUNCEXPR,
    ...
};

#define EEO_DISPATCH()    goto *((void *) op->opcode)
#define EEO_NEXT()        do { op++; EEO_DISPATCH(); } while(0)
#define EEO_CASE(name)    CASE_##name:

#else /* switch-based dispatch */

#define EEO_DISPATCH()    goto starteval
#define EEO_NEXT()        do { op++; EEO_DISPATCH(); } while(0)
#define EEO_CASE(name)    case name:

#endif

static Datum
ExecInterpExpr(ExprState *state, ExprContext *econtext, bool *isnull)
{
    ExprEvalStep *op = state->steps;

    EEO_DISPATCH();

    EEO_CASE(EEOP_DONE)
    {
        *isnull = state->resnull;
        return state->resvalue;
    }

    EEO_CASE(EEOP_SCAN_VAR)
    {
        int attnum = op->d.var.attnum;
        TupleTableSlot *scanslot = econtext->ecxt_scantuple;
        *op->resvalue = scanslot->tts_values[attnum];
        *op->resnull = scanslot->tts_isnull[attnum];
        EEO_NEXT();
    }

    EEO_CASE(EEOP_FUNCEXPR_STRICT)
    {
        FunctionCallInfo fcinfo = op->d.func.fcinfo;
        /* Check for null arguments */
        bool has_null = false;
        for (int i = 0; i < op->d.func.nargs; i++)
            if (fcinfo->args[i].isnull) { has_null = true; break; }
        if (has_null)
        {
            *op->resnull = true;
            EEO_NEXT();
        }
        fcinfo->isnull = false;
        *op->resvalue = op->d.func.finfo->fn_addr(fcinfo);
        *op->resnull = fcinfo->isnull;
        EEO_NEXT();
    }

    EEO_CASE(EEOP_BOOL_AND_STEP)
    {
        if (*op->resnull)
            *op->d.boolexpr.anynull = true;
        else if (!DatumGetBool(*op->resvalue))
        {
            /* Short-circuit: AND with false = false */
            *op->resvalue = BoolGetDatum(false);
            *op->resnull = false;
            EEO_JUMP(op->d.boolexpr.jumpdone);
        }
        EEO_NEXT();
    }

    /* ... ~100+ opcode handlers ... */
}
```

**Computed goto advantage.** With a switch statement, all dispatches jump from
a single location (the switch), causing poor branch prediction. With computed
gotos, each opcode handler jumps directly to the next handler from a different
source address, giving the CPU branch predictor more context and improving
prediction accuracy.

### Fast-Path Evaluation

For very simple expressions, the full interpreter loop has noticeable overhead.
`ExecReadyInterpretedExpr()` detects common patterns and installs specialized
fast-path functions:

| Pattern | Fast-Path Function |
|---|---|
| Single `Var` reference | `ExecJustInnerVar` / `ExecJustOuterVar` / `ExecJustScanVar` |
| Single `Const` | `ExecJustConst` |
| Single `Var` assigned to slot | `ExecJustAssignInnerVar` / etc. |

These bypass the step-dispatch loop entirely.

---

## JIT Compilation (LLVM)

### When JIT Activates

JIT compilation is controlled by cost thresholds:

| GUC | Default | Triggers |
|---|---|---|
| `jit_above_cost` | 100,000 | Any JIT at all |
| `jit_inline_above_cost` | 500,000 | Inlining of called functions |
| `jit_optimize_above_cost` | 500,000 | LLVM optimization passes |

If the query's total cost exceeds `jit_above_cost` and `jit_enabled = on`,
PostgreSQL will attempt to JIT-compile expressions and tuple deforming.

### What Gets JIT-Compiled

1. **Expression evaluation.** The `ExprEvalStep` array is translated into LLVM
   IR that performs the same operations but without interpretation overhead.
   Each step becomes inline native code.

2. **Tuple deforming.** The `slot_getsomeattrs()` function, which extracts
   column values from a heap tuple's binary format, is JIT-compiled with the
   specific tuple descriptor baked in. This eliminates per-column type dispatch.

### JIT Compilation Pipeline

```
ExprState with ExprEvalStep array
        |
        v
  llvm_compile_expr()  (llvmjit_expr.c)
        |
        +-- Create LLVM module and function
        +-- For each ExprEvalStep:
        |     Emit LLVM IR equivalent
        |     (loads, stores, function calls, branches)
        +-- If cost > jit_inline_above_cost:
        |     Inline called C functions (transfuncs, operators)
        +-- If cost > jit_optimize_above_cost:
        |     Run LLVM optimization passes (mem2reg, SROA, etc.)
        +-- Compile to native code (MCJIT or ORC)
        |
        v
  Native function pointer
  --> installed as ExprState.evalfunc
```

### JIT Provider Architecture

JIT is pluggable via a provider interface:

```c
typedef struct JitProviderCallbacks {
    JitProviderResetAfterErrorCB reset_after_error;
    JitProviderReleaseContextCB  release_context;
    JitProviderCompileExprCB     compile_expr;
} JitProviderCallbacks;
```

The default provider is `llvmjit.so`, loaded dynamically. The provider is
initialized lazily on first use.

### JIT Context and Lifecycle

Each `EState` has an optional `JitContext` that tracks all JIT-compiled code
for the query:

```c
typedef struct JitContext {
    int         flags;                  /* PGJIT_xxx flags */
    ResourceOwner resowner;
    /* Provider-specific state follows */
} JitContext;

/* Flags */
#define PGJIT_NONE          0
#define PGJIT_PERFORM       (1 << 0)   /* perform JIT */
#define PGJIT_OPT3          (1 << 1)   /* -O3 optimization */
#define PGJIT_INLINE        (1 << 2)   /* inline called functions */
#define PGJIT_EXPR          (1 << 3)   /* JIT expressions */
#define PGJIT_DEFORM        (1 << 4)   /* JIT tuple deforming */
```

All JIT-compiled code is released when the query's `EState` is destroyed,
ensuring no memory leaks.

### JIT GUC Settings

```
jit = on                        -- enable JIT globally
jit_provider = 'llvmjit'       -- JIT provider library
jit_above_cost = 100000        -- minimum cost for JIT
jit_inline_above_cost = 500000 -- minimum cost for inlining
jit_optimize_above_cost = 500000 -- minimum cost for -O3
jit_expressions = on            -- JIT-compile expressions
jit_tuple_deforming = on        -- JIT-compile deforming
jit_debugging_support = off     -- emit debug info
jit_dump_bitcode = off          -- dump .bc files
jit_profiling_support = off     -- perf integration
```

---

## Key Data Structures

### ExprState

```c
typedef struct ExprState {
    NodeTag             type;
    uint8               flags;          /* EEO_FLAG_* */
    bool                resnull;
    Datum               resvalue;
    TupleTableSlot     *resultslot;
    struct ExprEvalStep *steps;         /* instruction array */
    ExprStateEvalFunc   evalfunc;       /* interpreter or JIT function */
    Expr               *expr;           /* original tree (debug) */
    void               *evalfunc_private; /* JIT private data */
    int                 steps_len;
    int                 steps_alloc;
    PlanState          *parent;
    ...
} ExprState;
```

### ExprEvalOp (opcodes)

Selected from the ~130 opcodes:

```c
typedef enum ExprEvalOp {
    EEOP_DONE,

    /* Variable access */
    EEOP_INNER_VAR,
    EEOP_OUTER_VAR,
    EEOP_SCAN_VAR,
    EEOP_INNER_SYSVAR,
    EEOP_OUTER_SYSVAR,
    EEOP_SCAN_SYSVAR,

    /* Constants */
    EEOP_CONST,

    /* Function calls */
    EEOP_FUNCEXPR,
    EEOP_FUNCEXPR_STRICT,
    EEOP_FUNCEXPR_FUSAGE,
    EEOP_FUNCEXPR_STRICT_FUSAGE,

    /* Boolean logic */
    EEOP_BOOL_AND_STEP,
    EEOP_BOOL_AND_STEP_FIRST,
    EEOP_BOOL_AND_STEP_LAST,
    EEOP_BOOL_OR_STEP,
    EEOP_BOOL_OR_STEP_FIRST,
    EEOP_BOOL_OR_STEP_LAST,
    EEOP_BOOL_NOT_STEP,

    /* Null tests */
    EEOP_NULLTEST_ISNULL,
    EEOP_NULLTEST_ISNOTNULL,

    /* Comparisons */
    EEOP_NULLIF,

    /* CASE */
    EEOP_CASE_WHEN,

    /* Aggregates */
    EEOP_AGG_PLAIN_PERGROUP_NULLCHECK,
    EEOP_AGG_PLAIN_TRANS_INIT_STRICT_BYVAL,
    EEOP_AGG_PLAIN_TRANS_STRICT_BYVAL,
    EEOP_AGG_PLAIN_TRANS_BYVAL,
    EEOP_AGG_PLAIN_TRANS_INIT_STRICT_BYREF,
    EEOP_AGG_PLAIN_TRANS,

    /* Jump / control flow */
    EEOP_JUMP,
    EEOP_JUMP_IF_NULL,
    EEOP_JUMP_IF_NOT_NULL,
    EEOP_JUMP_IF_NOT_TRUE,

    /* ~100 more opcodes ... */

    EEOP_LAST
} ExprEvalOp;
```

---

## Diagram: Expression Compilation and Evaluation

```
SQL: WHERE a > 10 AND b = 'foo'

Parse Tree:
  BoolExpr (AND)
   +-- OpExpr (>)
   |    +-- Var (a)
   |    +-- Const (10)
   +-- OpExpr (=)
        +-- Var (b)
        +-- Const ('foo')

Compiled Steps:
  [0] EEOP_SCAN_VAR          attnum=0 (a)     -> resvalue[0]
  [1] EEOP_CONST             value=10         -> resvalue[1]
  [2] EEOP_FUNCEXPR_STRICT   fn=int4gt        -> resvalue[2]
  [3] EEOP_BOOL_AND_STEP     jumpdone=7       (short-circuit if false)
  [4] EEOP_SCAN_VAR          attnum=1 (b)     -> resvalue[3]
  [5] EEOP_CONST             value='foo'      -> resvalue[4]
  [6] EEOP_FUNCEXPR_STRICT   fn=texteq        -> resvalue[5]
  [7] EEOP_BOOL_AND_STEP_LAST                 -> final result
  [8] EEOP_DONE

Execution (per tuple):
  Step 0: fetch a from scan slot
  Step 1: load constant 10
  Step 2: call int4gt(a, 10)
  Step 3: if false, jump to step 7 (AND short-circuit)
  Step 4: fetch b from scan slot
  Step 5: load constant 'foo'
  Step 6: call texteq(b, 'foo')
  Step 7: combine AND result
  Step 8: return
```

### JIT vs. Interpreted Performance

```
             Interpreted              JIT-Compiled
             ----------               ------------
Dispatch:    computed goto            direct native jumps
             (indirect branch)        (no dispatch overhead)

Func call:   fmgr_info->fn_addr()    inlined native code
             (indirect call)          (direct operations)

Deform:      generic loop over       baked-in column offsets
             column descriptors       (no loop, no type check)

Startup:     ~0                       ~50-200ms (LLVM compile)
Per-tuple:   ~100-500ns               ~10-50ns
Break-even:  < ~100K tuples           > ~100K tuples
```

---

## Connections

| Topic | Link |
|---|---|
| Executor overview | [Query Executor](index) |
| Volcano model (where expressions run) | [Volcano Model](volcano-model) |
| Qual evaluation in scan nodes | [Scan Nodes](scan-nodes) |
| Join qual evaluation | [Join Nodes](join-nodes) |
| Aggregate transition functions | [Aggregation](aggregation) |
| JIT in parallel workers | [Parallel Query](parallel-query) |
| Function manager (fmgr) | [Extensions](../15-extensions/) |
| Memory contexts for expression state | [Memory Management](../10-memory/) |
