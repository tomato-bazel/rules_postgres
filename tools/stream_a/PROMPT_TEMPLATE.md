# Stream A prompt template (Haiku writes Pg.Ir Lean specs)

Template for spawning a Haiku general-purpose agent that authors a new
Pg.Ir cluster end-to-end. Hardened from lessons across 4 pilots
(float-unary / text / int-div / interval-v2):

- **Most important fix (lesson from int-div):** Agents must include the
  `return` keyword in `PG_RETURN_*` macro definitions. The int-div pilot
  defined `PG_RETURN_INT32(x) ((Datum)(x))` — an expression, not a return
  statement. Function bodies fell through to garbage. Regen + AST
  grounding passed (macro preamble isn't visible to AST diff); only
  cargo behavioral diff-test caught it.

- **Agents may misreport** "all gates pass" without actually running
  cargo. Verification is the spawner's responsibility. The agent's
  report goes in `<result>`; trust gate output (paste the literal
  `test result:` line in the report so we have something to grep).

## Boilerplate sections to copy-paste

Each Stream A pilot prompt should follow this structure. Replace
`<<...>>` placeholders.

```
You are extending the Pg.Ir Lean-source-of-truth codegen pipeline.
Target: <<cluster name>> — <<one-line description + function count>>.

## What Pg.Ir is

Lean spec → emits Rust V1 fmgr bodies AND real-style Postgres C.
Three verification gates:
1. Lean → Rust regen idempotent (`regen-*.sh --check`)
2. Cargo diff-test against vendored real-PG bodies (`cargo test --release`)
3. clang AST structural diff vs real Postgres source (`check-*-grounding.sh`)

## Closest exemplar(s) — read FIRST

<<list 1-3 closest existing clusters with their Common/Emit/EmitC files
+ regen + grounding scripts + the crate directory>>

Also read pg_fcinfo's relevant helpers:
- `/Volumes/Workspace/rules_postgres/rust/pg_fcinfo/src/lib.rs`
  Find: <<list specific helpers the target needs>>

## Target bodies

Real Postgres source: `<<src/backend/...>>` at
```
/Users/mattmarshall/Library/Caches/bazel/_bazel_mattmarshall/0fee58293a938d2caa5da4f904216d74/external/+postgres_src_extension+postgres_src/<<rest of path>>
```

<<inline the actual function bodies you want vendored, or grep
instructions to find them>>

## CRITICAL C oracle conventions

When you write `c_oracle/<name>.c`, the `PG_RETURN_*` macro definitions
MUST INCLUDE THE `return` KEYWORD. Real Postgres' macros are return
statements, NOT expressions. Use exactly these forms in your C oracle's
preamble:

```c
#define PG_RETURN_BOOL(x)   return (Datum)((x) ? 1 : 0)
#define PG_RETURN_INT16(x)  return (Datum) (uint16_t) (x)
#define PG_RETURN_INT32(x)  return (Datum) (uint32_t) (x)
#define PG_RETURN_INT64(x)  return (Datum) (uint64_t) (x)
#define PG_RETURN_FLOAT4(x) do { float  _tmp = (x); return (Datum) (uint32_t) __builtin_bit_cast(uint32_t, _tmp); } while (0)
#define PG_RETURN_FLOAT8(x) do { double _tmp = (x); return (Datum) (uint64_t) __builtin_bit_cast(uint64_t, _tmp); } while (0)
#define PG_RETURN_NULL()    do { fcinfo->isnull = true; return (Datum) 0; } while (0)
#define PG_RETURN_BYTEA_P(p)    return (Datum) (uintptr_t) (p)
#define PG_RETURN_INTERVAL_P(p) return (Datum) (uintptr_t) (p)
```

If you omit `return`, your functions will return garbage register values
and ALL cargo tests will fail — but regen and AST grounding will
silently pass (the macros aren't in the function body AST that AST
grounding inspects). DO NOT FALL INTO THIS TRAP.

## What to produce

<<list of files to create with their paths>>

## Verification — RUN THESE COMMANDS YOURSELF AND PASTE THE OUTPUT

After writing all files, run these EXACTLY and paste the literal output
of each one's last line (the `test result:` / `ok:` line) in your final
report:

```bash
chmod +x <<regen + check scripts>>
bash <<regen-*.sh>>                 # initial generate
bash <<regen-*.sh>> --check         # must say "ok: ... matches"
cd <<crate dir>> && cargo test --release 2>&1 | grep "test result:"
bash <<check-*-grounding.sh>>       # must say "ok: N / N functions ..."
```

If `cargo test` reports ANY failures, debug them — DO NOT report success
until cargo shows `test result: ok. N passed; 0 failed`. Common failure
mode: see "CRITICAL C oracle conventions" above.

Also verify no regressions:
```bash
<<list of other check-*-grounding.sh scripts that should still pass>>
```

## Report format

Under <<word limit>> words. Required sections:
1. **Cargo output (verbatim)**: paste the actual `test result:` line.
2. **AST grounding output (verbatim)**: paste the `ok: N / N` line.
3. **Regen check output**: paste the `ok: ... matches` line.
4. **No regressions**: paste each prior cluster's grounding line.
5. **Subtleties discovered**: any non-obvious things about the target.
6. **Divergences from exemplar**: what you had to do differently.

If ANY gate failed and you couldn't fix it, report THAT honestly. A
clean "I couldn't make X green because Y" is far more valuable than a
green report that papers over real divergence.
```

## Verification cost / benefit

The user (or spawner) verifies the agent's claims independently by
re-running the same four commands. Cost: ~30 seconds per cluster.
Net Stream A savings stays at ~7-10× per cluster vs hand-authoring.

## Misreport types observed

1. **C oracle macro shim bugs** (int-div PG_RETURN_*) — caught only by
   cargo behavioral diff-test, NOT by regen or AST grounding.
2. **Skipped own-cluster grounding** (date-arith): agent ran
   grounding for OTHER clusters ("no regressions") but did not
   actually verify its OWN cluster's grounding output. Prompt v3
   fix: require pasting the exact `bash check-<cluster>-grounding.sh`
   final line, and require the explicit sentence "I confirmed N/N
   functions pass AST grounding for <cluster>".
3. **Inline-vs-delegated body shape divergence** (cash-arith,
   date-arith): real Postgres has many clusters that delegate from
   a thin fmgr stub to a `static inline` helper (e.g., `cash_pl`
   delegates to `cash_pl_cash`; `date_pli` delegates to
   `date_pli_internal`-style helpers). Agents tend to INLINE the
   body in the fmgr stub. Behaviorally equivalent; structurally
   divergent at the AST level — AST grounding fails. Prompt v3
   fix: agents MUST check real Postgres source structure first.
   If the body delegates, the Lean emit must ALSO delegate
   (emit two helpers — one static, one fmgr stub).

## Hardened guidance to add to prompts (v3)

For palloc-using or arithmetic-with-overflow clusters, copy this
verbatim into the prompt:

> **PG body structure rule (CRITICAL for AST grounding):**
> Open the real Postgres source for each function you're vendoring.
> If the V1 fmgr body is just a few lines that call a `static`
> `<name>_internal` / `<name>_cash` / `finite_<name>` helper, your
> Lean Emit must produce TWO emit blocks per family:
>   1. The static helper (with the actual algorithm).
>   2. The fmgr stub (which decodes args, calls the helper, returns).
> Inlining the helper's body into the fmgr stub will make AST
> grounding fail. Behavioral diff-test will still pass, but the
> three-gate green standard is missed.

And:

> **Verification report rule (CRITICAL):**
> Your report MUST include three sentences in this exact form:
>   - "Cargo: `<paste exact 'test result: ok. N passed; 0 failed' line>`"
>   - "AST grounding: `<paste exact 'ok: N / N functions ...' line>`"
>   - "Regen check: `<paste exact 'ok: ... matches' line>`"
> If any of these is not green, debug until they are. Do NOT
> report success while any gate is failing — a clean honest
> "I couldn't make X pass" is more valuable than green-on-paper.

> **TWO C FILES — DO NOT CONFLATE (CRITICAL for AST grounding,
> v4 addition after UUID pilot misreport):**
>
> Pg.Ir produces TWO different C files per cluster, with DIFFERENT
> include strategies:
>
> 1. **The C oracle** (`rust/pg_<cluster>/c_oracle/<cluster>.c`) —
>    standalone, vendored body. Self-contained: own typedefs for
>    Datum, NullableDatum, FunctionCallInfoBaseData, own
>    `PG_GETARG_*` / `PG_RETURN_*` macros. Compiles standalone for
>    cargo's diff-test. **DOES NOT include real Postgres headers.**
>
> 2. **The Lean C emit** (`lean/Pg/Ir/Emit/<Cluster>C.lean` →
>    output) — real-PG-style C for AST grounding. clang
>    `-ast-dump=json` this file with REAL Postgres headers, then
>    diffs against real `src/backend/utils/adt/<source>.c`. **MUST
>    `#include "postgres.h"` and module-specific headers** so all
>    typedefs and macros resolve identically on both sides.
>
> Reference examples for the real-PG-style emit (`<Cluster>C.lean`):
> ```c
> #include "postgres.h"
> #include "utils/uuid.h"          // for pg_uuid_t, UUID_LEN
> #include "common/hashfn.h"       // for hash_any
> #include "utils/fmgrprotos.h"    // function prototypes
> ```
>
> Match real PG's `varlena.c` / `date.c` / `cash.c` / etc. `#include`
> lines verbatim — those are the headers the function body depends
> on for macro expansion. AST grounding FAILS if any of those
> headers is missing.
>
> If you find yourself writing `typedef uintptr_t Datum;` or
> `typedef struct ... pg_uuid_t;` in `<Cluster>C.lean`, STOP — you
> are confusing the two files. The Lean C emit does NOT define types;
> it includes real PG headers that define them.

## Per-cluster fixes that should be one-line

If verification reveals a misreport:
- broken PG_RETURN_* → fix the C oracle preamble macros
- broken extern decl → check the wrappers.c WRAP() macro expansion
- wrong fcinfo arg index → check the decode call in the fmgr stub

If verification reveals a deeper structural issue, ask the agent to
iterate. But the four pilots so far had only the macro-shim type, fixed
in seconds.
