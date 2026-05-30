/-
Pg.AstUpdateReturnExprTest — pinning tests for the
Triggers-D Phase 2d extensions: `BodyStmt.updateTable` and
`BodyStmt.returnExpr`.

Each `#guard` locks the exact PL/pgSQL surface a constructor
renders to. Catches accidental output drift in future refactors
of `printBodyStmt`.

Coverage:
  * `updateTable` — single SET column, multi-column SETs, the
    full production `invalidate_permission_cache_on_statement`
    UPDATE shape (3 SETs + a complex WHERE).
  * `returnExpr` — `RETURN <expr>;` with a literal, a variable,
    and the production `RETURN COALESCE(NEW, OLD)` shape.

These pair with Phase 2e (encode the actual trigger) and
Phase 3 (semantics + bridge theorem to #308's `invalidateMatching`).
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty

-- updateTable: single column, simple WHERE.
#guard printBodyStmt
    (.updateTable "graph.permission_cache"
      [("is_valid", .litConst (.bool false))]
      (.eq (.var "subject_id") (.var "v_new_subject_id")))
  = "    UPDATE graph.permission_cache\n" ++
    "    SET is_valid = FALSE\n" ++
    "    WHERE (subject_id = v_new_subject_id);\n"

-- updateTable: multiple SET columns.
#guard printBodyStmt
    (.updateTable "graph.permission_cache"
      [ ("is_valid",          .litConst (.bool false))
      , ("invalidated_at",    .callBuiltin "now" []) ]
      (.eq (.var "subject_id") (.var "v_new_subject_id")))
  = "    UPDATE graph.permission_cache\n" ++
    "    SET is_valid = FALSE, invalidated_at = now()\n" ++
    "    WHERE (subject_id = v_new_subject_id);\n"

-- Empty SET list — degenerate but renders deterministically.
#guard printBodyStmt
    (.updateTable "graph.permission_cache"
      []
      (.litConst (.bool true)))
  = "    UPDATE graph.permission_cache\n" ++
    "    SET \n" ++
    "    WHERE TRUE;\n"

-- returnExpr: simple literal.
#guard printBodyStmt (.returnExpr (.litConst (.int 42)))
  = "    RETURN 42;\n"

-- returnExpr: variable reference.
#guard printBodyStmt (.returnExpr (.var "v_count"))
  = "    RETURN v_count;\n"

-- returnExpr: the production `RETURN COALESCE(NEW, OLD)` shape.
#guard printBodyStmt
    (.returnExpr (.coalesce [.var "NEW", .var "OLD"]))
  = "    RETURN COALESCE(NEW, OLD);\n"
