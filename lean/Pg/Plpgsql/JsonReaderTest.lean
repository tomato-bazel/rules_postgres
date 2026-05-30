/-
Pg.Plpgsql.JsonReaderTest — pinning tests for the
PL/pgSQL JSON reader.

Uses captured `plpgsql_to_json` output to drive `#guard`
assertions. Because `BodyStmt` / `Expr` don't derive
`DecidableEq`, the assertions destructure via `match` rather
than equality — explicit about the expected shape.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Plpgsql.JsonReader

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Plpgsql.JsonReader

/-- Captured `plpgsql_to_json` output for the
    `update_updated_at_column` trigger function body
    (`NEW.updated_at := now(); RETURN NEW;`). -/
def updateUpdatedAtJson : String :=
  "[{\"PLpgSQL_function\":{\"new_varno\":1,\"old_varno\":2," ++
  "\"datums\":[{\"PLpgSQL_var\":{\"refname\":\"found\"," ++
  "\"datatype\":{\"PLpgSQL_type\":{\"typname\":\"pg_catalog.\\\"boolean\\\"\"}}}}," ++
  "{\"PLpgSQL_rec\":{\"refname\":\"new\",\"dno\":1}}," ++
  "{\"PLpgSQL_rec\":{\"refname\":\"old\",\"dno\":2}}," ++
  "{\"PLpgSQL_recfield\":{\"fieldname\":\"updated_at\",\"recparentno\":1}}]," ++
  "\"action\":{\"PLpgSQL_stmt_block\":{\"lineno\":2," ++
  "\"body\":[" ++
  "{\"PLpgSQL_stmt_assign\":{\"lineno\":3,\"varno\":3," ++
  "\"expr\":{\"PLpgSQL_expr\":{\"query\":\"NEW.updated_at := now()\",\"parseMode\":4}}}}," ++
  "{\"PLpgSQL_stmt_return\":{\"lineno\":4," ++
  "\"expr\":{\"PLpgSQL_expr\":{\"query\":\"NEW\",\"parseMode\":2}}}}" ++
  "]}}}}]"

/-- A return whose body would be `OLD` (e.g. a DELETE trigger). -/
def oldReturnJson : String :=
  "[{\"PLpgSQL_function\":{\"action\":{\"PLpgSQL_stmt_block\":{\"body\":[" ++
  "{\"PLpgSQL_stmt_return\":{" ++
  "\"expr\":{\"PLpgSQL_expr\":{\"query\":\"OLD\",\"parseMode\":2}}}}" ++
  "]}}}}]"

/-! ## Top-level reader tests

Each guard pattern-matches the result against the expected
constructor shape. Returns `true` when the shape matches,
`false` otherwise (which fails the #guard). -/

-- The round-trip: real libpg_query JSON parses into the BodyStmt
-- list our emitter produced for `update_updated_at_column`.
#guard
  (match readBodyList updateUpdatedAtJson with
   | some [.assignNew "updated_at" (.callBuiltin "now" []), .returnRow .newRow] => true
   | _ => false)

-- An OLD-returning trigger body maps to `.returnRow .oldRow`.
#guard
  (match readBodyList oldReturnJson with
   | some [.returnRow .oldRow] => true
   | _ => false)

-- Malformed JSON returns `none` cleanly.
#guard
  (match readBodyList "not json at all" with
   | none => true
   | _    => false)

-- An empty JSON array doesn't yield a body list.
#guard
  (match readBodyList "[]" with
   | none => true
   | _    => false)

/-! ## Leaf-recogniser tests

These exercise the embedded-query string recognisers directly
(`matchAssignNewNow`, `matchReturnRow`) so a future refactor
can't silently change the recognition behaviour. -/

#guard
  (match matchAssignNewNow "NEW.updated_at := now()" with
   | some (.assignNew "updated_at" (.callBuiltin "now" [])) => true
   | _ => false)

#guard
  (match matchAssignNewNow "NEW.created_at := now()" with
   | some (.assignNew "created_at" (.callBuiltin "now" [])) => true
   | _ => false)

-- Negative: RHS isn't "now()".
#guard
  (match matchAssignNewNow "NEW.updated_at := 42" with
   | none => true
   | _    => false)

-- Negative: LHS isn't NEW.<col>.
#guard
  (match matchAssignNewNow "OLD.kind := NEW.kind" with
   | none => true
   | _    => false)

-- Negative: not a `:=` assignment shape.
#guard
  (match matchAssignNewNow "NEW.updated_at = now()" with
   | none => true
   | _    => false)

#guard
  (match matchReturnRow "NEW" with
   | some (.returnRow .newRow) => true
   | _ => false)

#guard
  (match matchReturnRow "OLD" with
   | some (.returnRow .oldRow) => true
   | _ => false)

#guard
  (match matchReturnRow "FOUND" with
   | none => true
   | _    => false)
