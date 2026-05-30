/-
Pg.AstPerformTest — smoke tests for the
`BodyStmt.perform` constructor added in Blocker-1 slice 3
(PERFORM <expr>; — evaluate-and-discard).

The constructor models the production PL/pgSQL pattern:

  PERFORM <expr>;

used to invoke a function for its side effects and throw
away the return value. Different from `SELECT <expr>;`,
which is a syntax error inside PL/pgSQL because the runtime
doesn't know what to do with the result row.

This slice adds:
  - The AST constructor (`PgAst.lean`)
  - The pretty-printer rule (`PgPretty.lean`)
  - The procedural-surface lock (`PgProceduralSurface.lean`)
  - The trigger-semantics arm (`PgTriggerSemantics.lean` —
    `.continue` if the expression has a defined value,
    `.undefined` otherwise; side effects are not modeled)

Production users include `pg_notify(channel, payload)` calls,
audit-logging side-effect invocations, and cache-refresh
helpers called from within other functions.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstPerformTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## Printer rendering

    The production shape is `PERFORM <expr>;` indented 4
    spaces, terminated with `;\n`. -/

/-- `PERFORM pg_notify('cache_invalidate', '');` — the
    canonical zero-argument-payload notify shape. -/
example :
    printBodyStmt
      (.perform
        (.call "pg_notify"
          [.litConst (.text "cache_invalidate"), .litConst (.text "")]))
    = "    PERFORM pg_notify('cache_invalidate', '');\n" := by native_decide

/-- `PERFORM auth.log_event('login');` — single-arg
    side-effect invocation. -/
example :
    printBodyStmt
      (.perform
        (.callQualified (Identifier.qualified "auth" "log_event") [.litConst (.text "login")]))
    = "    PERFORM auth.log_event('login');\n" := by native_decide

/-- `PERFORM 1;` — degenerate constant expression. PG would
    accept this; semantically it's a no-op since there are no
    side effects. -/
example :
    printBodyStmt (.perform (.litConst (.int 1)))
    = "    PERFORM 1;\n" := by native_decide

/-! ## Surface lock

    The new constructor must be visible in `bodyStmtShape` +
    `BodyStmt.exhaustive_known`. If a future change drops the
    `perform` case from either, the build breaks. -/

example :
    bodyStmtShape (.perform (.litConst (.int 1)))
    = .performShape := rfl

end Pg.AstPerformTest
