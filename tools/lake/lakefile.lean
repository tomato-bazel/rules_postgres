import Lake
open Lake DSL

-- Minimal Lake workspace for the rules_postgres-side PgAst extraction
-- scaffolding. Pins the Lean toolchain that the moved-from-Aion content
-- expects to type-check under.
--
-- Dep-free: rules_lean >= 0.5.1 accepts a zero-package workspace (the
-- lake_workspace dep-free path), so the old nominal `require batteries`
-- is gone — it was never imported (Phase 1: PgTy, PgAst, PgPretty,
-- Catalog/* import only Lean core), and source-building it cost ~15 min
-- on every CI run that pulled rules_postgres in. When later phases pull in
-- mathlib/cslib, add the real require here and bump `lake-manifest.json`.
--
-- The toolchain version must match Aion's `tools/lake/lean-toolchain`
-- exactly — both repos need to type-check the same source against the
-- same compiler. Coordination cost: when Aion bumps, we bump.
--
-- Decision trail: ~/Documents/rfcs/narrative/pgast-extraction-*.md

package «rules-postgres-lean» where
