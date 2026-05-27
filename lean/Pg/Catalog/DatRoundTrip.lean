import Pg.Catalog.Dat

/-!
# Pg.Catalog.DatRoundTrip — round-trip the .dat parser across every
vendored PG system-catalog seed file.

For each filename in `targets` below, reads
`Pg/Catalog/dat/<file>` (staged via `lean_emit.data` in
rules_lean 0.3.3+), parses via `Pg.Catalog.Dat.parseFile`, re-emits
via `Pg.Catalog.Dat.emitFile`, re-parses, and asserts the two parsed
structures are equal.

A single Bazel `lean_regen_test` (`gate_catalog_dat_round_trip` in
`lean/BUILD.bazel`) runs this entry against the entire vendored
`.dat` set; output is per-file `ok: <name> (<N> rows) ...` lines
plus a summary footer. `diff_test` against the committed expected
catches any drift between the parser and the format.
-/

open Pg.Catalog.Dat

/-- All vendored `.dat` files. Must stay in sync with the `data` list
in the Bazel target. Order matters for the expected output. -/
def targets : List String := [
  "pg_aggregate.dat",
  "pg_am.dat",
  "pg_amop.dat",
  "pg_amproc.dat",
  "pg_authid.dat",
  "pg_cast.dat",
  "pg_class.dat",
  "pg_collation.dat",
  "pg_conversion.dat",
  "pg_database.dat",
  "pg_language.dat",
  "pg_namespace.dat",
  "pg_opclass.dat",
  "pg_operator.dat",
  "pg_opfamily.dat",
  "pg_proc.dat",
  "pg_range.dat",
  "pg_tablespace.dat",
  "pg_ts_config.dat",
  "pg_ts_config_map.dat",
  "pg_ts_dict.dat",
  "pg_ts_parser.dat",
  "pg_ts_template.dat",
  "pg_type.dat",
]

def roundTripOne (name : String) : IO (Option String) := do
  let src ← IO.FS.readFile s!"Pg/Catalog/dat/{name}"
  match parseFile src with
  | .error e => pure (some s!"{name}: parse error: {e}")
  | .ok f₁ =>
      let emitted := emitFile f₁
      match parseFile emitted with
      | .error e => pure (some s!"{name}: re-parse error: {e}")
      | .ok f₂ =>
          if f₁ == f₂ then do
            IO.println s!"ok: {name} ({f₁.rows.size} rows) round-trip stable"
            pure none
          else
            pure (some s!"{name}: structural mismatch")

def main : IO UInt32 := do
  let mut failed : List String := []
  for t in targets do
    match (← roundTripOne t) with
    | none   => pure ()
    | some e => failed := failed.concat e
  if failed.isEmpty then do
    IO.println s!"ok: {targets.length}/{targets.length} .dat files round-trip stable"
    pure 0
  else do
    IO.eprintln s!"FAILED: {failed.length}/{targets.length} .dat files diverged:"
    for f in failed do IO.eprintln s!"  - {f}"
    pure 1
