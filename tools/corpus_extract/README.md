# Pg.Ir corpus extraction

Walks the Pg.Ir clusters and emits structured training data — (real C
source, Lean spec, Rust translation) triples plus AST grounding
metadata.

## Purpose

The downstream goal (per
`memory/project_c_to_rust_translation.md`) is to fine-tune a local
model that authors Pg.Ir Lean specs, eliminating the hosted-LLM
dependency. The first step is corpus extraction.

## What it emits

`corpus.jsonl` — one record per cluster (NOT per function; the cluster
is the natural authoring unit for Pg.Ir's family-table pattern).

Each record contains:

| Field | Type | Source |
|---|---|---|
| `cluster` | string | crate dir name (e.g. `pg_int4_cmp`) |
| `cluster_short` | string | dropped `pg_` prefix (e.g. `int4_cmp`) |
| `lean_modules` | object | `{Common, Emit, EmitC}` → raw Lean source strings |
| `rust_translation` | string | `src/lib.rs` content (Lean-emitted) |
| `c_oracle` | string | `c_oracle/<cluster>.c` content (vendored real-PG body) |
| `c_oracle_renamed` | string | `c_oracle/renamed_*.c` content |
| `c_oracle_wrappers` | string | `c_oracle/wrappers.c` content |
| `regen_script` | string | `tools/regen/regen-<cluster>.sh` content |
| `grounding_script` | string | `tools/regen/check-<cluster>-grounding.sh` content |
| `function_names` | list[string] | grep `pub unsafe extern "C" fn` from lib.rs |
| `n_functions` | int | length of function_names |
| `cargo_test_count` | int | parsed from `cargo test --release` output |
| `ast_grounding_total` | string | the `N / N` from the grounding output |
| `cluster_shape` | string | inferred — "cmp" / "hash" / "arith" / "palloc-result" / etc. |
| `real_pg_source_files` | list[string] | inferred from c_oracle's attribution comment |
| `pg_fcinfo_helpers_used` | list[string] | grep `use pg_fcinfo::{...}` from lib.rs |
| `pg_palloc_helpers_used` | list[string] | grep `use pg_palloc::...` from lib.rs |
| `errcode_used` | list[string] | grep `pg_ereport_*` from lib.rs |

## Training objectives (downstream)

The corpus supports several fine-tuning objectives:

1. **C-to-Lean**: input = real PG C source + closest exemplar; output
   = Lean Common + Emit + EmitC files. The primary Stream A objective.
2. **Lean-to-Rust**: input = Lean spec; output = expected Rust emit.
3. **Lean-to-C**: input = Lean spec; output = expected real-PG-style C
   for AST grounding.
4. **Failure-mode classifier**: input = (Lean spec, real PG source);
   output = which of the 7 known failure modes likely applies (helps
   pre-validate agent outputs before running gates).

## Run

```sh
python3 tools/corpus_extract/extract.py \
    --repo /Volumes/Workspace/rules_postgres \
    --out  /Volumes/Workspace/rules_postgres/tools/corpus_extract/corpus.jsonl
```
