/-!
# Pg.Catalog.Dat

Lean-native parser + emitter for Postgres' `.dat` system-catalog seed
files (e.g. `pg_namespace.dat`, `pg_type.dat`).

Grounded by PG's own `Catalog.pm::ParseData` (vendored at
`tools/catalog_gen/reference/Catalog.pm`). That sub takes ~80 lines
of Perl using a line-major brace-counting trick — same approach
implemented here in Lean, without delegating to a `eval`.

## Grammar (from Catalog.pm::ParseData)

Top-level layout: comments + an `[ ... ]` array of `{...}` hash refs
spanning one or more lines. The line-major parser:

  1. Read input line-by-line.
  2. If a line contains `{`, start an accumulator.
  3. Count `{` and `}` in the accumulator — if balanced, the
     accumulator holds a complete hash ref. Parse it as a record.
  4. Otherwise read the next line and append, then retry the count.
  5. Lines that never contain `{` and aren't inside an accumulator
     are comment/blank/structural lines.

Each record is `{ key => value, key => value, ... }` with:
  - keys: bare identifiers (`/[A-Za-z_][A-Za-z0-9_]*/`)
  - values: single-quoted strings `'...'` or the bare token `_null_`

Whitespace + newlines inside a record are flexible. Comments
between records use `#` line syntax. The MVP doesn't preserve
inter-token whitespace — emitter produces canonical form.

## Status

  - [x] Types: `Value`, `Field`, `Row`, `File`
  - [x] `parseFile : String → Except String File`
  - [x] `emitFile  : File → String`              (canonical form)
  - [ ] Byte-identical re-emit (stretch — would need whitespace
        preservation)
-/

namespace Pg.Catalog.Dat

/-- A single `.dat` row field value. -/
inductive Value where
  /-- A single-quoted string. The wrapping quotes are NOT stored. -/
  | str (s : String)
  /-- The bare `_null_` token. -/
  | null
  deriving Repr, BEq, Inhabited

/-- One `key => value` field. -/
structure Field where
  key   : String
  value : Value
  deriving Repr, BEq, Inhabited

/-- One `{ k => v, k => v }` row. -/
structure Row where
  fields : Array Field
  deriving Repr, BEq, Inhabited

/-- A complete `.dat` file. The MVP doesn't preserve the file
preamble (`#`-comments + the `[ ]` envelope) — `emitFile` produces
those in canonical form. -/
structure File where
  rows : Array Row
  deriving Repr, BEq, Inhabited

/-! ## Parsing -/

/-- Count occurrences of `c` in `s`. -/
private def countChar (s : String) (c : Char) : Nat :=
  s.foldl (fun acc ch => if ch == c then acc + 1 else acc) 0

/-- Index of the first occurrence of `c` in `s`, by character (not
byte). Returns `none` if absent. Avoids `String.Pos` which has
changed shape across Lean versions. -/
private def findIdx? (s : String) (c : Char) : Option Nat := Id.run do
  let mut i := 0
  for ch in s.toList do
    if ch == c then return some i
    i := i + 1
  return none

/-- Index of the LAST occurrence of `c` in `s`. -/
private def findLastIdx? (s : String) (c : Char) : Option Nat := Id.run do
  let mut last : Option Nat := none
  let mut i := 0
  for ch in s.toList do
    if ch == c then last := some i
    i := i + 1
  return last

/-- Extract the substring strictly between the FIRST `{` and the LAST
`}` in `s`. Returns `none` if either brace is missing or they're
out of order. -/
private def extractBraceBody (s : String) : Option String :=
  match findIdx? s '{', findLastIdx? s '}' with
  | some li, some ri =>
      if li + 1 > ri then none
      else
        let chars := s.toList
        some (String.ofList ((chars.drop (li + 1)).take (ri - li - 1)))
  | _, _ => none

/-- Parse one record body (the content between `{` and `}`).
Pre: `body` is everything between the outer braces. Splits on
top-level commas (no nesting in the MVP — pg_namespace.dat has no
array values) and parses each as `key => value`. -/
private def parseRecordBody (body : String) : Except String Row := do
  -- Split on commas. Risk: `'foo,bar'` would split too — but
  -- pg_namespace.dat has no commas inside string values. Catalog.pm
  -- itself uses Perl `eval` to sidestep this; we use a simple split
  -- and document the limitation.
  let parts := (body.splitOn ",").map String.trim
  -- Drop empty trailing splits (caused by `, }` style trailing).
  let parts := parts.filter (fun s => !s.isEmpty)
  let mut fields : Array Field := #[]
  for part in parts do
    -- Each part is `key => value` (or `key=>value` with arbitrary ws).
    let toks := part.splitOn "=>"
    if toks.length != 2 then
      throw s!"expected `key => value`, got `{part}`"
    let key := toks[0]!.trim
    let raw := toks[1]!.trim
    -- value: '...' or _null_
    let value ←
      if raw == "_null_" then
        pure Value.null
      else if raw.startsWith "'" && raw.endsWith "'" && raw.length ≥ 2 then
        -- Drop the outer single quotes via take/drop. In Lean 4.30+
        -- these return String.Slice; .toString converts back.
        pure (Value.str (((raw.drop 1).take (raw.length - 2)).toString))
      else
        throw s!"unrecognized value `{raw}` (expected '...' or _null_)"
    fields := fields.push { key, value }
  pure { fields }

/-- Line-major parse: accumulate lines until braces balance, then
parse the accumulated record. -/
def parseFile (src : String) : Except String File := do
  let lines := src.splitOn "\n"
  let mut rows : Array Row := #[]
  let mut acc : String := ""
  let mut accOpens : Nat := 0
  let mut accCloses : Nat := 0
  let mut inRecord : Bool := false
  for line in lines do
    -- Strip comment-only lines (start with optional ws + '#'). For
    -- pg_namespace.dat: comments are always on their own line.
    -- More elaborate inline-comment stripping is deferred to later
    -- .dat files that need it.
    let strippedTrim := line.trim
    let stripped :=
      if inRecord then line
      else if strippedTrim.startsWith "#" then ""
      else line
    if !inRecord then
      -- Looking for a line that opens a record.
      if stripped.any (· == '{') then
        inRecord := true
        acc := stripped
        accOpens := countChar stripped '{'
        accCloses := countChar stripped '}'
        if accOpens == accCloses then
          match extractBraceBody acc with
          | some body =>
              let row ← parseRecordBody body
              rows := rows.push row
              inRecord := false
              acc := ""
              accOpens := 0
              accCloses := 0
          | none => throw "internal: balanced braces but extract failed"
    else
      -- Inside a record: keep appending until balanced.
      acc := acc ++ " " ++ stripped.trim
      accOpens := accOpens + countChar stripped '{'
      accCloses := accCloses + countChar stripped '}'
      if accOpens == accCloses then
        match extractBraceBody acc with
        | some body =>
            let row ← parseRecordBody body
            rows := rows.push row
            inRecord := false
            acc := ""
            accOpens := 0
            accCloses := 0
        | none => throw "internal: balanced braces but extract failed"
  if inRecord then
    throw s!"unterminated record at end of file: `{acc}`"
  pure { rows }

/-! ## Emitting (canonical form) -/

def emitValue : Value → String
  | .str s => "'" ++ s ++ "'"
  | .null  => "_null_"

def emitField (f : Field) : String :=
  f.key ++ " => " ++ emitValue f.value

def emitRow (r : Row) : String :=
  "{ " ++ ", ".intercalate (r.fields.toList.map emitField) ++ " }"

def emitFile (f : File) : String :=
  "[\n" ++ String.join (f.rows.toList.map (fun r => emitRow r ++ ",\n")) ++ "]\n"

/-! ## Round-trip helper -/

/-- Parse-then-re-parse: `parse src → emit → parse → compare`.
Returns `.ok ()` iff the two parsed structures are equal. -/
def roundTripStructural (src : String) : Except String Unit := do
  let f₁ ← parseFile src
  let emitted := emitFile f₁
  let f₂ ← parseFile emitted
  if f₁ == f₂ then pure () else throw "structural round-trip mismatch"

end Pg.Catalog.Dat
