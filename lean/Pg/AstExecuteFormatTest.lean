/-
Pg.AstExecuteFormatTest — smoke tests for the
`BodyStmt.executeFormat` constructor added in Blocker-1
slice 9 (EXECUTE <sql_expr> [USING …];).

The constructor models the production PL/pgSQL pattern:

  EXECUTE <sql_expr> [USING <bind1>, <bind2>, …];

The canonical shape uses `format()` for safe identifier and
literal interpolation:

  EXECUTE format('SELECT * FROM %I WHERE id = $1', tbl)
    USING p_id;

`%I` quotes identifiers, `%L` quotes literals, `%s` does
raw substitution (dangerous — opens up SQL injection if `%s`
substitutes user input). The AST just carries the
expression and bind args; format()-vs-concatenation lives
at the Expr level.

This slice adds:
  - The AST constructor (`PgAst.lean`)
  - The pretty-printer rule (`PgPretty.lean`)
  - The procedural-surface lock (`PgProceduralSurface.lean`)
  - The trigger-semantics arm (`PgTriggerSemantics.lean` —
    `.undefined`; modelling dynamic SQL needs a parser+
    evaluator the kernel doesn't ship)

Production users include `audit.*` table-partition
maintenance, `graph.invalidate_dynamic`, and `auth.*`
migration helpers that compute DROP/ALTER statements from
catalog rows.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstExecuteFormatTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## Printer rendering -/

/-- Minimal shape: bare EXECUTE of a string literal SQL with
    no USING clause. -/
example :
    printBodyStmt
      (.executeFormat (.litConst (.text "DROP TABLE foo")) [])
    = "    EXECUTE 'DROP TABLE foo';\n" := by native_decide

/-- Canonical production shape:
    `EXECUTE format('SELECT * FROM %I WHERE id = $1', tbl) USING p_id;`. -/
example :
    printBodyStmt
      (.executeFormat
        (.callBuiltin "format"
          [.litConst (.text "SELECT * FROM %I WHERE id = $1"),
           .var "tbl"])
        [.var "p_id"])
    = "    EXECUTE format('SELECT * FROM %I WHERE id = $1', tbl)" ++
      " USING p_id;\n" := by native_decide

/-- Multi-bind USING shape — production `audit.*` partition helper
    that supplies several positional binds. -/
example :
    printBodyStmt
      (.executeFormat
        (.callBuiltin "format"
          [.litConst (.text "INSERT INTO %I VALUES ($1, $2)"),
           .var "tbl"])
        [.var "p_id", .var "p_name"])
    = "    EXECUTE format('INSERT INTO %I VALUES ($1, $2)', tbl)" ++
      " USING p_id, p_name;\n" := by native_decide

/-! ## Surface lock -/

example :
    bodyStmtShape
      (.executeFormat (.litConst (.text "x")) [])
    = .executeFormatShape := rfl

end Pg.AstExecuteFormatTest
