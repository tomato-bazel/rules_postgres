/-
Pg.AstSelectIntoTest — smoke tests for the
`BodyStmt.selectInto` constructor added in Blocker-1
slice 7 (SELECT … INTO <vars> FROM …;).

The constructor models the production PL/pgSQL pattern:

  SELECT <projs> INTO [STRICT] <var₁>, <var₂>, … FROM <source>
    [WHERE <cond>] [ORDER BY …] [LIMIT …];

Single-row result assignment to declared local variables.
The projections list and targets list must have matching
length at runtime; the AST surface lock doesn't enforce that
here (postgres raises an error if they don't match).

This slice adds:
  - The AST constructor (`PgAst.lean`)
  - The pretty-printer rule (`PgPretty.lean`) — interleaves
    INTO between projections and FROM, so it doesn't reuse
    `printSelectQuery` directly
  - The procedural-surface lock (`PgProceduralSurface.lean`)
  - The trigger-semantics arm (`PgTriggerSemantics.lean` —
    `.undefined`; production trigger functions don't use
    SELECT INTO)

Production users include `auth.lookup_resource_by_id`,
`graph.get_session_subject`, and many lookup-style helpers
that bind a few columns to declared locals before continuing.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstSelectIntoTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## Printer rendering -/

/-- Minimal shape: bind one local from a single-table lookup.
    `SELECT id INTO v_id FROM graph.resource WHERE name = $1;` -/
example :
    printBodyStmt
      (.selectInto ["v_id"]
        { projections := [.var "id"]
          source := .table "graph.resource" none
          whereCond := some (.eq (.var "name") (.var "p_name"))
        }
        false)
    = "    SELECT id INTO v_id FROM graph.resource" ++
      " WHERE (name = p_name);\n" := by native_decide

/-- STRICT shape — raises NO_DATA_FOUND if no row, TOO_MANY_ROWS if >1. -/
example :
    printBodyStmt
      (.selectInto ["v_id"]
        { projections := [.var "id"]
          source := .table "graph.resource" none
          whereCond := some (.eq (.var "name") (.var "p_name"))
        }
        true)
    = "    SELECT id INTO STRICT v_id FROM graph.resource" ++
      " WHERE (name = p_name);\n" := by native_decide

/-- Multi-target shape — bind several columns at once. -/
example :
    printBodyStmt
      (.selectInto ["v_id", "v_kind"]
        { projections := [.var "id", .var "kind"]
          source := .table "graph.resource" none
          whereCond := some (.eq (.var "name") (.var "p_name"))
        }
        false)
    = "    SELECT id, kind INTO v_id, v_kind FROM graph.resource" ++
      " WHERE (name = p_name);\n" := by native_decide

/-- ORDER BY + LIMIT shape — typical "first match" pattern. -/
example :
    printBodyStmt
      (.selectInto ["v_id"]
        { projections := [.var "id"]
          source := .table "graph.resource" none
          orderBy := [(.var "created_at", true)]
          limit := some (.litConst (.int 1))
        }
        false)
    = "    SELECT id INTO v_id FROM graph.resource" ++
      " ORDER BY created_at DESC LIMIT 1;\n" := by native_decide

/-! ## Surface lock -/

example :
    bodyStmtShape
      (.selectInto ["v"]
        { projections := [.var "id"], source := .empty } false)
    = .selectIntoShape := rfl

end Pg.AstSelectIntoTest
