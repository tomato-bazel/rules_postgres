/-
Pg.AstDeclareLocalTest — pinning tests for the
DECLARE block + `BodyStmt.assignLocal` extensions added in
Triggers-D Phase 2c.

Each `#guard` locks the exact PL/pgSQL surface a DECLARE +
assignLocal pair renders to. Catches accidental output drift in
future refactors of `printCreateFunction` / `printDeclareBlock` /
`printDeclareEntry` / `printBodyStmt`'s `.assignLocal` arm.

Coverage:
  * `BodyStmt.assignLocal` rendering in isolation
  * Empty DECLARE list — no block emitted
  * Single-entry DECLARE block
  * Multi-entry DECLARE block (production trigger's
    `v_new_subject_id BIGINT; v_old_subject_id BIGINT; …` shape)
  * Full round-trip: a CREATE FUNCTION with both a DECLARE block
    and assignLocal statements in the body
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.Ty

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.Ty

-- assignLocal renders as `name := <expr>;` with 4-space indent.
#guard printBodyStmt (.assignLocal "v_new_subject_id" (.var "NEW"))
  = "    v_new_subject_id := NEW;\n"

-- Empty DECLARE list → no block emitted at all.
#guard printDeclareBlock [] = ""

-- Single-entry DECLARE: `DECLARE\n    name TYPE;\n`.
#guard printDeclareBlock [{ name := "v_id", pgType := .bigint }]
  = "DECLARE\n    v_id BIGINT;\n"

-- Production trigger's multi-entry DECLARE shape:
-- four BIGINT locals for INSERT/UPDATE/DELETE id capture.
#guard printDeclareBlock
    [ { name := "v_new_subject_id", pgType := .bigint }
    , { name := "v_old_subject_id", pgType := .bigint }
    , { name := "v_new_object_id",  pgType := .bigint }
    , { name := "v_old_object_id",  pgType := .bigint } ]
  = "DECLARE\n    v_new_subject_id BIGINT;\n    v_old_subject_id BIGINT;\n    v_new_object_id BIGINT;\n    v_old_object_id BIGINT;\n"

-- Full CREATE FUNCTION round-trip with DECLARE + assignLocal.
-- Function signature plus header is fixed; the new pieces are
-- the DECLARE block (between `AS $$` and `BEGIN`) and the
-- assignLocal inside BEGIN.
#guard printCreateFunction
    { name := Identifier.qualified "graph" "test_fn"
    , params := []
    , returnType := .trigger
    , volatility := .volatile
    , securityDefiner := false
    , declare := [{ name := "v_id", pgType := .bigint }]
    , body :=
        [ .assignLocal "v_id" (.field (.var "NEW") "id")
        , .returnRow .newRow ] }
  = "CREATE OR REPLACE FUNCTION graph.test_fn(\n\n) RETURNS TRIGGER\n" ++
    "LANGUAGE PLPGSQL\nVOLATILE\nAS $$\n" ++
    "DECLARE\n    v_id BIGINT;\n" ++
    "BEGIN\n" ++
    "    v_id := NEW.id;\n" ++
    "    RETURN NEW;\n" ++
    "END;\n$$;\n"

-- No-DECLARE case: a function without locals renders identically
-- to the pre-Phase-2c form (DECLARE block omitted).
#guard printCreateFunction
    { name := Identifier.qualified "graph" "test_no_decl"
    , params := []
    , returnType := .trigger
    , volatility := .volatile
    , securityDefiner := false
    , body := [.returnRow .newRow] }
  = "CREATE OR REPLACE FUNCTION graph.test_no_decl(\n\n) RETURNS TRIGGER\n" ++
    "LANGUAGE PLPGSQL\nVOLATILE\nAS $$\n" ++
    "BEGIN\n" ++
    "    RETURN NEW;\n" ++
    "END;\n$$;\n"
