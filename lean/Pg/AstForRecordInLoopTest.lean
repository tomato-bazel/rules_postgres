/-
Pg.AstForRecordInLoopTest — smoke tests for the
`BodyStmt.forRecordInLoop` constructor added in Blocker-1
slice 6 (FOR record IN <query> LOOP <body> END LOOP;).

The constructor models the production PL/pgSQL pattern:

  FOR <recordVar> IN
    SELECT <projections> FROM <source>
      [WHERE <whereCond>]
      [ORDER BY <orderBy>]
      [LIMIT <limit>]
  LOOP
      <body…>
  END LOOP;

Each iteration binds `recordVar` to the current row; the
body executes once per row.

This slice also moves `JoinKind` + `SelectSource` above
`BodyStmt` in PgAst.lean and introduces the new
`SelectQuery` structure. The body-statement printer
references `printSelectQuery` (now defined upstream of the
mutual block).

Production users include `auth.refresh_all_caches` (walking
every entry in `auth.session`), `graph.invalidate_*` helpers
(per-descendant-statement work), and maintenance functions
that fan out across a result set.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstForRecordInLoopTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## Printer rendering -/

/-- Minimal shape: `FOR r IN SELECT id FROM graph.statement LOOP
    RETURN r; END LOOP;` — single projection, table source, no
    filter, single returnExpr body. -/
example :
    printBodyStmt
      (.forRecordInLoop "r"
        { projections := [.var "id"]
          source := .table "graph.statement" none }
        [.returnExpr (.var "r")])
    =
      "    FOR r IN SELECT id FROM graph.statement LOOP\n" ++
      "    RETURN r;\n" ++
      "    END LOOP;\n" := by native_decide

/-- WHERE-filtered loop — production shape for cache-walker
    helpers: `FOR r IN SELECT id FROM graph.statement WHERE
    subject_id = $1 LOOP …` -/
example :
    printBodyStmt
      (.forRecordInLoop "r"
        { projections := [.var "id"]
          source := .table "graph.statement" none
          whereCond := some (.eq (.var "subject_id") (.var "p_subject_id"))
        }
        [.perform (.callQualified (Identifier.qualified "auth" "log_event") [.litConst (.text "row")])])
    =
      "    FOR r IN SELECT id FROM graph.statement" ++
        " WHERE (subject_id = p_subject_id) LOOP\n" ++
      "    PERFORM auth.log_event('row');\n" ++
      "    END LOOP;\n" := by native_decide

/-- Function-call source — `FOR r IN SELECT * FROM
    auth.parse_key_id(p_key_id) LOOP …`. -/
example :
    printBodyStmt
      (.forRecordInLoop "r"
        { projections := [.var "*"]
          source := .functionCall "auth.parse_key_id" [.var "p_key_id"] none }
        [.returnLit (.litConst (.bool true))])
    =
      "    FOR r IN SELECT * FROM auth.parse_key_id(p_key_id) LOOP\n" ++
      "    RETURN TRUE;\n" ++
      "    END LOOP;\n" := by native_decide

/-! ## Surface lock -/

example :
    bodyStmtShape
      (.forRecordInLoop "r"
        { projections := [.var "id"], source := .empty }
        [])
    = .forRecordInLoopShape := rfl

end Pg.AstForRecordInLoopTest
