# `tools/catalog_gen/`

Lean-native catalog snapshot generator. Replaces the 631-LOC Python
generator `gen_catalog_lean.py` (currently Aion-side, scheduled to
move here on 2026-06-01 per the Phase 1 plan) with a pipeline that
participates in the same Bazel-native gates as Pg.Ir clusters.

## Design

`.dat` files in `@postgres_src//src/include/catalog/` are the source
of truth for PG's bootstrap system catalog rows. PG itself parses
them via `Catalog.pm::ParseData` (which uses Perl `eval` on the
input — see `src/backend/catalog/Catalog.pm` in the pinned PG source
tree if you need to consult the upstream grammar).

The Lean-native pipeline:

```
  @postgres_src//src/include/catalog/pg_namespace.dat
            │
            ▼  Pg.Catalog.Dat.parse  (Lean module, lean/Pg/Catalog/Dat.lean)
       File { catname = "pg_namespace", rows = [...] }
            │
            ▼  Pg.Catalog.Generated.emit  (TBD Lean script)
       Generated.lean snapshot for downstream Lean specs
```

Validation:

  - **Round-trip:** `lean_emit` runs a Lean script that parses each
    committed `.dat` file and re-emits its canonical form;
    `lean_regen_test` from `@rules_lean//lean:lean.bzl` gates the
    output against the committed `.dat` snapshot. A passing
    round-trip proves the Lean grammar captures the upstream format.
  - **Drift:** `Generated.lean` is built from `.dat` at every Bazel
    invocation. No committed-artifact drift gate; the snapshot just
    gets rebuilt. The "committed `Generated.lean`" smell from the
    Python pipeline is eliminated.

## Status (2026-05-27)

  - [x] All 24 vendored `.dat` files: `lean/Pg/Catalog/dat/*.dat`
  - [x] Lean grammar types + tokenizer-driven parser + canonical
        emitter in `lean/Pg/Catalog/Dat.lean`. Handles quoted strings
        with `\\` and `\'` escapes, bare-identifier values,
        brace-containing strings (pg_aggregate's `'{0,0}'`),
        multi-line records — every shape the vendored .dat files use.
  - [x] Bazel-native round-trip gate
        `//lean:gate_catalog_dat_round_trip` (rules_lean 0.3.3's
        `lean_emit.data` stages all 24 .dat files; the entry parses +
        re-emits + re-parses each; diff_test asserts stdout equals
        committed `_round_trip_expected.txt`). Included in `//:gates`.
  - [x] **Coverage: 6,777 rows across all 24 `.dat` files** round-trip
        stable (pg_namespace 3 → pg_proc 3,314 → pg_amop 945 → ...).
  - [ ] `Pg.Catalog.Generated` rebuild script (lean_emit reading the
        parsed `.dat` files, writing the catalog snapshot with the
        cross-links AddDefaultValues + GenerateArrayTypes apply).

## Why this replaces the Python script

User direction (2026-05-27): the existing `gen_catalog_lean.py`
"seems like a code smell" — Python as a third language between PG
and Lean, with `Generated.lean` committed-and-drift-gated. The
Lean-native pipeline:

  - Removes Python from the catalog build.
  - Removes `Generated.lean` from source control (build artifact).
  - Pattern-matches the Pg.Ir cluster gates exactly: `lean_emit` +
    `lean_regen_test` from `@rules_lean//lean:lean.bzl` (v0.3.2).

## Outstanding cross-repo work

The Phase 1 extraction plan (8-doc decision trail under
`~/Documents/rfcs/narrative/pgast-extraction-*.md`) scheduled the
Python script's move from Aion to here on 2026-06-01. With the
Lean-native direction, that move is no longer needed — Aion-side
`gen_catalog_lean.py` can be retired in favor of consuming the
rebuilt `Generated.lean` from rules_postgres.

Pre-move verification still useful: confirm the Aion-side
Postgres source pin (`postgres_src_repositories.bzl`) aligns with
rules_postgres' `pg.source(version = "17.6")` so the catalog
snapshot has the same OIDs on both sides during the transition.
