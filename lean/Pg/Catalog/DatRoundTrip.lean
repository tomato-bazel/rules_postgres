import Pg.Catalog.Dat

/-!
# Pg.Catalog.DatRoundTrip — round-trip smoke for the .dat parser.

Reads `lean/Pg/Catalog/dat/pg_namespace.dat` from disk, parses it via
`Pg.Catalog.Dat.parseFile`, re-emits via `Pg.Catalog.Dat.emitFile`,
parses the re-emitted output, and verifies the two parsed structures
are equal. Prints `ok: <N> rows, structurally round-trip stable` on
success.

Run:
  lean --run lean/Pg/Catalog/DatRoundTrip.lean
-/

open Pg.Catalog.Dat

def main : IO UInt32 := do
  let src ← IO.FS.readFile "Pg/Catalog/dat/pg_namespace.dat"
  match parseFile src with
  | .error e => do
      IO.eprintln s!"parse error: {e}"
      pure 1
  | .ok file₁ => do
      let emitted := emitFile file₁
      match parseFile emitted with
      | .error e => do
          IO.eprintln s!"re-parse error after emit: {e}"
          IO.eprintln s!"emitted text:\n{emitted}"
          pure 1
      | .ok file₂ =>
          if file₁ == file₂ then do
            IO.println s!"ok: {file₁.rows.size} rows, structurally round-trip stable"
            pure 0
          else do
            IO.eprintln "structural mismatch between parse(emit(parse(src))) and parse(src)"
            pure 1
