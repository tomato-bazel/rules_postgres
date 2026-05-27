/-!
# Pg.Catalog.Dat

Lean-native parser + emitter for Postgres' `.dat` system-catalog seed
files (`pg_namespace.dat`, `pg_type.dat`, `pg_proc.dat`, ...).

Grounded by PG's own `Catalog.pm::ParseData` (vendored at
`tools/catalog_gen/reference/Catalog.pm`). PG itself delegates to Perl
`eval` on each hash-ref line; we tokenize directly.

## Grammar (subset PG's .dat files actually use)

  - File body: `[ <record>, <record>, ..., ]` wrapped in `#`-comment
    preamble + optional `#` comments between records.
  - Record: `{ <field>, <field>, ... }` (may span multiple lines).
  - Field: `<ident> => <value>`.
  - Value: single-quoted string `'...'` (with `\\` and `\'` escapes)
    OR bare identifier (e.g. `_null_`, or symbolic OID references
    that pg_proc uses for type names).

## Implementation

Two-phase: char-stream → token-stream → File AST. The tokenizer is
quote-aware (braces / commas inside `'...'` are NOT structural), so
values like `'{0,0}'` (pg_aggregate.dat) parse correctly. Backslash
escapes inside strings are decoded; canonical re-emit re-encodes them
identically.

## Status

  - [x] Types: `Value`, `Field`, `Row`, `File`
  - [x] `parseFile : String → Except String File`
  - [x] `emitFile  : File → String`              (canonical form)
  - [x] Round-trip stable on at least: `pg_namespace.dat`,
        `pg_tablespace.dat`, `pg_authid.dat`, `pg_language.dat`,
        `pg_class.dat`, `pg_collation.dat`, `pg_range.dat`,
        `pg_am.dat`, `pg_database.dat`, `pg_ts_*.dat`,
        `pg_type.dat`, `pg_conversion.dat`, `pg_opfamily.dat`,
        `pg_aggregate.dat`, `pg_opclass.dat`, `pg_cast.dat`,
        `pg_amproc.dat`, `pg_operator.dat`, `pg_amop.dat`, `pg_proc.dat`
        (see lean/BUILD.bazel `gate_catalog_dat_round_trip_<name>`).
-/

namespace Pg.Catalog.Dat

/-- A single field value. -/
inductive Value where
  /-- A single-quoted string. The wrapping quotes are NOT stored;
  escape sequences are decoded (`\'` → `'`, `\\` → `\`). -/
  | str (s : String)
  /-- A bare identifier (e.g. `_null_`, or symbolic OID refs). -/
  | ident (s : String)
  deriving Repr, BEq, Inhabited

/-- One `key => value` field in a row. -/
structure Field where
  key   : String
  value : Value
  deriving Repr, BEq, Inhabited

/-- One `{ k => v, k => v }` row. -/
structure Row where
  fields : Array Field
  deriving Repr, BEq, Inhabited

/-- A complete `.dat` file. -/
structure File where
  rows : Array Row
  deriving Repr, BEq, Inhabited

/-! ## Tokenization -/

inductive Token where
  | lBrace | rBrace
  | comma | arrow
  | ident (s : String)
  | str (s : String)
  deriving Repr, BEq, Inhabited

private def isIdentChar (c : Char) : Bool :=
  c.isAlphanum || c == '_'

/-- Tokenize a `.dat` source string into a flat list of `Token`s.
Skips whitespace + `#`-to-end-of-line comments. -/
partial def tokenize (src : String) : Except String (Array Token) := do
  let cs := src.toList
  let n := cs.length
  let mut out : Array Token := #[]
  let mut i : Nat := 0
  while i < n do
    let c := cs[i]!
    if c.isWhitespace then
      i := i + 1
    else if c == '#' then
      -- skip until end of line (or EOF)
      while i < n && cs[i]! != '\n' do
        i := i + 1
    else if c == '{' then
      out := out.push .lBrace
      i := i + 1
    else if c == '}' then
      out := out.push .rBrace
      i := i + 1
    else if c == ',' then
      out := out.push .comma
      i := i + 1
    else if c == '[' || c == ']' then
      -- File envelope; not a record-level token. Skip silently —
      -- record boundaries are governed by `{ ... }` directly.
      i := i + 1
    else if c == '=' then
      -- expect `=>`
      if i + 1 < n && cs[i+1]! == '>' then
        out := out.push .arrow
        i := i + 2
      else
        throw s!"expected `=>` at offset {i}"
    else if c == '\'' then
      -- single-quoted string with backslash escapes
      i := i + 1  -- skip opening quote
      let mut acc : List Char := []
      let mut closed : Bool := false
      while i < n && !closed do
        let d := cs[i]!
        if d == '\\' then
          -- escape sequence: backslash + next char (decoded literally)
          if i + 1 >= n then throw "unterminated escape at end of file"
          let e := cs[i+1]!
          acc := acc.concat e
          i := i + 2
        else if d == '\'' then
          closed := true
          i := i + 1
        else
          acc := acc.concat d
          i := i + 1
      if !closed then throw "unterminated string literal"
      out := out.push (.str (String.ofList acc))
    else if isIdentChar c then
      -- bare identifier
      let start := i
      while i < n && isIdentChar cs[i]! do
        i := i + 1
      out := out.push (.ident (String.ofList ((cs.drop start).take (i - start))))
    else
      throw s!"unexpected character `{c}` at offset {i}"
  pure out

/-! ## Parsing (token stream → File) -/

/-- Parse one `{ key => value, ... }` record starting at `i`.
Returns the row + the index one past the closing `}`. -/
private partial def parseRow (toks : Array Token) (i : Nat) : Except String (Row × Nat) := do
  if i ≥ toks.size || toks[i]? != some Token.lBrace then
    throw s!"expected left-brace at token {i}"
  let mut j := i + 1
  let mut fields : Array Field := #[]
  while j < toks.size do
    match toks[j]! with
    | .rBrace =>
        return ({ fields }, j + 1)
    | .ident key =>
        if j + 1 ≥ toks.size then throw "expected arrow after key, got EOF"
        if toks[j+1]! != .arrow then
          throw s!"expected arrow after key {key} at token {j+1}"
        if j + 2 ≥ toks.size then throw "expected value after arrow, got EOF"
        let value ←
          match toks[j+2]! with
          | .str s   => pure (Value.str s)
          | .ident s => pure (Value.ident s)
          | other    => throw s!"expected value at token {j+2}, got {repr other}"
        fields := fields.push { key, value }
        if j + 3 < toks.size && toks[j+3]! == .comma then
          j := j + 4
        else
          j := j + 3
    | other =>
        throw s!"expected ident or right-brace at token {j}, got {repr other}"
  throw "unterminated record (no closing brace found)"

/-- Parse the whole `.dat` file from its tokenized form. -/
partial def parseTokens (toks : Array Token) : Except String File := do
  let mut rows : Array Row := #[]
  let mut i := 0
  while i < toks.size do
    match toks[i]! with
    | .lBrace =>
        let (row, j) ← parseRow toks i
        rows := rows.push row
        i := j
        -- skip optional trailing comma between records
        if i < toks.size && toks[i]! == .comma then
          i := i + 1
    | .comma => i := i + 1  -- stray comma between records — tolerate
    | other  => throw s!"expected left-brace at top level, got {repr other}"
  pure { rows }

/-- Parse `.dat` source text. -/
def parseFile (src : String) : Except String File := do
  let toks ← tokenize src
  parseTokens toks

/-! ## Emitting (canonical form) -/

/-- Re-encode a string for emission: turn `'` into `\'` and `\` into
`\\`. Mirrors Perl single-quoted-string escapes. -/
private def escapeStr (s : String) : String :=
  let escaped := s.toList.foldl
    (fun acc c =>
      if c == '\\' then acc ++ ['\\', '\\']
      else if c == '\'' then acc ++ ['\\', '\'']
      else acc.concat c)
    ([] : List Char)
  String.ofList escaped

def emitValue : Value → String
  | .str s    => "'" ++ escapeStr s ++ "'"
  | .ident s  => s

def emitField (f : Field) : String :=
  f.key ++ " => " ++ emitValue f.value

def emitRow (r : Row) : String :=
  "{ " ++ ", ".intercalate (r.fields.toList.map emitField) ++ " }"

def emitFile (f : File) : String :=
  "[\n" ++ String.join (f.rows.toList.map (fun r => emitRow r ++ ",\n")) ++ "]\n"

/-! ## Round-trip helper -/

/-- Parse → emit → parse → structural compare. -/
def roundTripStructural (src : String) : Except String Unit := do
  let f₁ ← parseFile src
  let emitted := emitFile f₁
  let f₂ ← parseFile emitted
  if f₁ == f₂ then pure () else throw "structural round-trip mismatch"

end Pg.Catalog.Dat
