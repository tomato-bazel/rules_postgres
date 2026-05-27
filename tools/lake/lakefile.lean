import Lake
open Lake DSL

-- Minimal Lake workspace for the rules_postgres-side PgAst extraction
-- scaffolding. Pins the Lean toolchain that the moved-from-Aion content
-- expects to type-check under.
--
-- One nominal `require` (batteries) because rules_lean's
-- lake_workspace extension fails analysis if the lake workspace has
-- zero packages — the rule assumes downstream targets need something
-- importable. Batteries is small + cache-backed via Reservoir, so the
-- cost of including it is one fast download.
--
-- Phase 1 scope (PgTy, PgAst, PgPretty, Catalog/*) doesn't actually
-- import batteries; the require is structural. When later phases
-- pull in modules that DO need mathlib or cslib, add them here and
-- bump `lake-manifest.json` accordingly.
--
-- The toolchain version must match Aion's `tools/lake/lean-toolchain`
-- exactly — both repos need to type-check the same source against the
-- same compiler. Coordination cost: when Aion bumps, we bump.
--
-- Decision trail: ~/Documents/rfcs/narrative/pgast-extraction-*.md

package «rules-postgres-lean» where

require batteries from git
  "https://github.com/leanprover-community/batteries.git" @ "v4.30.0-rc2"
