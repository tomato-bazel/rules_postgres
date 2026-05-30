/-
Pg.AstRaiseNoticeTest — smoke tests for the
`BodyStmt.raiseNotice` constructor added in Blocker-1
slice 4 (RAISE NOTICE — non-aborting log emission).

The constructor models the production PL/pgSQL pattern:

  RAISE NOTICE '<message>' [, <arg1>, <arg2>, …];

used for debug-trace points and informational client log
lines. Distinct from `raiseException` in that NOTICE does
NOT abort the surrounding statement.

This slice adds:
  - The AST constructor (`PgAst.lean`)
  - The pretty-printer rule (`PgPretty.lean`, reusing
    `printRaiseArgs` from the existing RAISE EXCEPTION
    machinery)
  - The procedural-surface lock (`PgProceduralSurface.lean`)
  - The trigger-semantics arm (`PgTriggerSemantics.lean` —
    `.continue` since NOTICE doesn't change state)

DEBUG / LOG / INFO / WARNING are separate constructors a
future slice will add (each requires its own surface-lock
arm to maintain Tightening E discipline).
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstRaiseNoticeTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## Printer rendering -/

/-- Bare RAISE NOTICE with no format arguments. -/
example :
    printBodyStmt (.raiseNotice "permission cache warmed" [])
    = "    RAISE NOTICE 'permission cache warmed';\n" := by native_decide

/-- RAISE NOTICE with positional `%`-substitution args. -/
example :
    printBodyStmt
      (.raiseNotice "loaded % rows for subject %"
        [.litConst (.int 42), .litConst (.text "alice")])
    = "    RAISE NOTICE 'loaded % rows for subject %', 42, 'alice';\n" := by native_decide

/-- RAISE NOTICE escapes a single-quote in the message. -/
example :
    printBodyStmt (.raiseNotice "can't reach quorum" [])
    = "    RAISE NOTICE 'can''t reach quorum';\n" := by native_decide

/-! ## Surface lock -/

example :
    bodyStmtShape (.raiseNotice "x" [])
    = .raiseNoticeShape := rfl

end Pg.AstRaiseNoticeTest
