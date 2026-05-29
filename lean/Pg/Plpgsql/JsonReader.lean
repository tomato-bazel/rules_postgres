/-
Pg.Plpgsql.JsonReader — Lean-side reader for libpg_query's
PL/pgSQL JSON output. Lean-side leg of the BodyStmt round-trip
bridge.

## What this module does

Given a JSON string emitted by `pg_query_parse_plpgsql()` (via the
`tools/libpg_query:plpgsql_to_json` CLI), this module parses it
into a Lean intermediate AST (`PlpgsqlNode`) that mirrors
libpg_query's schema, and maps that to our existing
`PgAst.BodyStmt` constructors.

## Scope (Bridge PR B)

Initial coverage is the **`update_updated_at_column`** trigger
function shape — the minimum needed to validate the architecture:

  PLpgSQL_stmt_block
    body:
      [PLpgSQL_stmt_assign { expr.query = "NEW.<col> := <rhs>" }
       PLpgSQL_stmt_return { expr.query = "NEW" or "OLD" }]
  ↓
  [BodyStmt.assignNew col (.call rhs [])
   BodyStmt.returnRow .newRow / .oldRow]

Other libpg_query node shapes (`PLpgSQL_stmt_if`,
`PLpgSQL_stmt_raise`, `PLpgSQL_stmt_assign` with arbitrary RHS,
local-variable assignment, multi-branch IF) land as expansions:
each one is a new pattern in the embedded-expression recogniser
plus a new arm in `plpgsqlToBodyStmt`. The intermediate
`PlpgsqlNode` AST collects the raw text for each embedded query
so future expansions don't need a JSON re-walk.

## Design

  * **`PlpgsqlNode`** — Lean inductive mirroring the libpg_query
    JSON schema. Each constructor stores embedded SQL queries as
    *opaque text* (matching libpg_query's behaviour — those
    fragments aren't parsed deeper by the PL/pgSQL grammar).
  * **`readPlpgsql`** — `Lean.Json → PlpgsqlNode`. Parses a single
    JSON value into the intermediate AST. Walks the
    `{"PLpgSQL_*": {...}}` tag pattern recursively.
  * **`plpgsqlToBodyStmt`** — `PlpgsqlNode → Option BodyStmt`.
    Pattern-matches against the shapes our emitter actually
    produces; returns `none` for shapes we haven't taught the
    mapper yet (which is most of them today).
  * **`readBodyList`** — top-level: takes the JSON string from
    `plpgsql_to_json`, parses it, and returns
    `Option (List BodyStmt)` for the single function we expect.

## Connection to the round-trip theorem (Bridge PR C)

PR C states (under a `ParserReflects` stipulation):

    parseBody (printBody body) = some body

`parseBody` is composed of: (1) the C tool's JSON output, (2) this
module's `readBodyList`. The stipulation says that composition
recovers the original `body` — provable by exhibiting the round
trip on each emit shape we support.
-/

import Lean.Data.Json
import Pg.Ast
import Pg.Stmt
import Pg.AstSmart

namespace Pg.Plpgsql.JsonReader

open Lean (Json)
open Polyglot.Sql.Ast Pg.Ast Pg.Stmt

/-! ## Intermediate AST mirroring libpg_query's schema -/

/-- A subset of libpg_query's PLpgSQL node taxonomy, restricted to
    the shapes we need for round-tripping our emitted bodies.

    Embedded SQL expressions are kept as opaque strings — that's
    what libpg_query gives us (its PL/pgSQL parser doesn't parse
    the inner queries). The mapper to `BodyStmt` does
    pattern-matching against the known shapes our emitter
    produces. -/
inductive PlpgsqlNode where
  /-- `{"PLpgSQL_function": {..., action: <block>}}` — wraps a
      single function's compiled body. -/
  | function (action : PlpgsqlNode) : PlpgsqlNode
  /-- `{"PLpgSQL_stmt_block": {body: [<node>...]}}` — BEGIN/END. -/
  | block (body : List PlpgsqlNode) : PlpgsqlNode
  /-- `{"PLpgSQL_stmt_assign": {expr.query: "NEW.col := rhs"}}` —
      *all* PL/pgSQL assignments take this shape; the LHS and RHS
      are inside the query string. -/
  | assign (query : String) : PlpgsqlNode
  /-- `{"PLpgSQL_stmt_return": {expr.query: "NEW"}}` —
      RETURN with an embedded query. -/
  | returnQ (query : String) : PlpgsqlNode
  /-- An un-modelled construct — preserves the raw tag string
      for debuggability. -/
  | unknown (tag : String) : PlpgsqlNode
deriving Repr, Inhabited

/-! ## JSON reader

`Lean.Json` is the standard Lean 4 JSON library; we use its
`getObjVal?` / `getStr?` / `getArr?` helpers to walk the
libpg_query output. -/

/-- Try to read a `PLpgSQL_expr.query` text out of a JSON node
    that looks like `{"PLpgSQL_expr": {"query": "...", ...}}`. -/
def readExprQuery (j : Json) : Option String :=
  match j.getObjVal? "PLpgSQL_expr" with
  | .ok inner =>
      match inner.getObjVal? "query" with
      | .ok q => q.getStr?.toOption
      | .error _ => none
  | .error _ => none

/-- Top-level JSON-to-PlpgsqlNode reader. Matches against the
    single-key-object pattern libpg_query uses for tag
    discrimination. Returns `.unknown <tag>` for any node shape
    we haven't taught the reader yet. -/
partial def readPlpgsql (j : Json) : PlpgsqlNode :=
  -- Try each known tag in turn. The tagged-object pattern is
  -- `{"<tag>": {<payload>}}` with exactly one key.
  match j.getObjVal? "PLpgSQL_function" with
  | .ok inner =>
      match inner.getObjVal? "action" with
      | .ok action => .function (readPlpgsql action)
      | .error _   => .unknown "PLpgSQL_function"
  | .error _ =>
  match j.getObjVal? "PLpgSQL_stmt_block" with
  | .ok inner =>
      match inner.getObjVal? "body" with
      | .ok bodyArr =>
          match bodyArr.getArr? with
          | .ok arr => .block (arr.toList.map readPlpgsql)
          | .error _ => .unknown "PLpgSQL_stmt_block"
      | .error _ => .unknown "PLpgSQL_stmt_block"
  | .error _ =>
  match j.getObjVal? "PLpgSQL_stmt_assign" with
  | .ok inner =>
      match inner.getObjVal? "expr" with
      | .ok exprJ =>
          match readExprQuery exprJ with
          | some q => .assign q
          | none   => .unknown "PLpgSQL_stmt_assign"
      | .error _ => .unknown "PLpgSQL_stmt_assign"
  | .error _ =>
  match j.getObjVal? "PLpgSQL_stmt_return" with
  | .ok inner =>
      match inner.getObjVal? "expr" with
      | .ok exprJ =>
          match readExprQuery exprJ with
          | some q => .returnQ q
          | none   => .unknown "PLpgSQL_stmt_return"
      | .error _ => .unknown "PLpgSQL_stmt_return"
  | .error _ => .unknown "<unrecognised>"

/-! ## Mapper: PlpgsqlNode → BodyStmt

Pattern-matches against the embedded query strings our emitter
produces. Returns `none` for shapes we haven't covered yet —
expanding coverage is purely additive (new pattern, new arm). -/

/-- Try to recover an `assignNew col (.callBuiltin "now" [])` shape from
    a query like `"NEW.<col> := now()"`. Returns `none` if the
    string doesn't match this exact pattern. -/
def matchAssignNewNow (query : String) : Option BodyStmt :=
  -- Expect: `NEW.<col> := now()`. Split on " := " then verify
  -- the LHS starts with "NEW." and the RHS is exactly "now()".
  match query.splitOn " := " with
  | [lhs, rhs] =>
      if rhs = "now()" ∧ lhs.startsWith "NEW." then
        some (.assignNew ((lhs.drop "NEW.".length).toString) (.callBuiltin "now" []))
      else
        none
  | _ => none

/-- Try to recover a `returnRow` shape from a query like `"NEW"`
    or `"OLD"`. -/
def matchReturnRow (query : String) : Option BodyStmt :=
  if query = "NEW" then some (.returnRow .newRow)
  else if query = "OLD" then some (.returnRow .oldRow)
  else none

/-- Map a single `PlpgsqlNode` to a `BodyStmt` if the shape is
    recognised. `.function` and `.block` unwrap into their inner
    bodies and aren't themselves a `BodyStmt`; they're handled
    by `readBodyList`. -/
def plpgsqlToBodyStmt (n : PlpgsqlNode) : Option BodyStmt :=
  match n with
  | .assign q  => matchAssignNewNow q
  | .returnQ q => matchReturnRow q
  | _          => none

/-! ## Top-level entry point -/

/-- Map a list of `PlpgsqlNode`s to a list of `BodyStmt`s.
    Returns `none` if any element fails to map. -/
def mapBodyStmts : List PlpgsqlNode → Option (List BodyStmt)
  | []       => some []
  | n :: rest =>
      match plpgsqlToBodyStmt n with
      | none   => none
      | some s =>
          match mapBodyStmts rest with
          | none    => none
          | some ss => some (s :: ss)

/-- Parse a libpg_query PL/pgSQL JSON output (the `plpgsql_funcs`
    field — a JSON array of `PLpgSQL_function` objects) and
    extract the first function's body as a `List BodyStmt`.

    Returns `none` on JSON parse error, on missing function/block
    structure, or on any body statement we don't yet know how to
    map. -/
def readBodyList (s : String) : Option (List BodyStmt) := do
  let j ← Json.parse s |>.toOption
  let arr ← j.getArr?.toOption
  let first ← arr[0]?
  let func := readPlpgsql first
  match func with
  | .function (.block stmts) => mapBodyStmts stmts
  | _ => none

end Pg.Plpgsql.JsonReader
