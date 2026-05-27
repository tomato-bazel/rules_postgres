# `tools/catalog_gen/` — placeholder

This directory is the receiving location for `gen_catalog_lean.py` and
its helpers under Phase 1 of the PgAst extraction.

**Currently empty.** Real content arrives via Phase 1 of the extraction
(Aion-side drives, target start **2026-06-01**), when the script moves
from `~/Documents/rfcs/tools/catalog_gen/gen_catalog_lean.py` to here.

## What `gen_catalog_lean.py` does (per Aion's existing design)

Parses pinned Postgres `.dat` files (the `pg_namespace`, `pg_class`,
`pg_proc`, `pg_attribute`, `pg_authid`, etc. system-catalog seed data
shipped with the Postgres source tree) and produces a Lean snapshot at
`lean/Pg/Catalog/Generated.lean`. The snapshot is structurally the
same shape every run, so a CI drift gate (currently in Aion as
`//lean:catalog_generated_drift_gate_test`, moves here per Q3) checks
that the committed `Generated.lean` matches what the script would
produce from the pinned source.

## Why it moves here

`Pg/Catalog/Generated.lean` is generic Postgres catalog content (not
Aion-domain). The tooling that produces it travels with the data.
After the move, Aion drops `tools/catalog_gen/` and depends on the
rules_postgres-owned generator.

## Postgres source pin

This script consumes `@postgres_src` provided by rules_postgres's
`pg.source` extension (`postgres/extensions.bzl`). Current pin:
**Postgres 17.6** (see `MODULE.bazel`: `pg.source(version = "17.6")`).

Aion's existing pin at
`~/Documents/rfcs/tools/postgres_src/postgres_src_repositories.bzl`
is verified for alignment before Phase 1 commits — see the Phase 1
plan's "Outstanding pre-move verification" section.

## Decision trail

`~/Documents/rfcs/narrative/pgast-extraction-*.md` — 5-doc dialogue
(proposal → review → response → phase1-plan → phase1-ack).

## When Phase 1 lands here

Expected files (relocated from Aion's `tools/catalog_gen/`):

- `gen_catalog_lean.py` — the generator
- `BUILD.bazel` — `py_binary` target + the drift-gate `sh_test`
- Helper Python modules (if any)

Until then, this README is the only thing in the dir.
