/-
Pg.AstBeginExceptionTest — smoke tests for the
`BodyStmt.beginException` constructor added in Blocker-1
slice 5 (BEGIN … EXCEPTION WHEN … END; error-handling
sub-block).

The constructor models the production PL/pgSQL pattern:

  BEGIN
      <body…>
  EXCEPTION
      WHEN <cond₁> [OR <cond₂>…] THEN
          <handler₁…>
      [WHEN <cond₃> THEN
          <handler₂…>]
  END;

If any statement in `body` raises an exception whose SQLSTATE
matches one of the handler conditions, control transfers to
that handler and the sub-block exits normally. If no handler
matches, the exception propagates. The special condition name
`OTHERS` is the catch-all.

This slice adds:
  - The AST constructor (`PgAst.lean`)
  - The pretty-printer rule + `printExceptionHandlers` helper
    in the mutual block (`PgPretty.lean`)
  - The procedural-surface lock (`PgProceduralSurface.lean`)
  - The trigger-semantics arm (`PgTriggerSemantics.lean` —
    `.undefined` until errcode-aware dispatch lands; the
    surface lock + printer ship here)

Production users: `auth.try_set_session_id` and the
`graph.create_*` helpers that catch `unique_violation` to
dedupe re-inserts, and the audit-logging path that wraps
user-supplied code in `WHEN OTHERS THEN <fallback>`.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstBeginExceptionTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## Printer rendering -/

/-- Single-handler shape: catch `unique_violation`, RETURN FALSE. -/
example :
    printBodyStmt
      (.beginException
        [.returnLit (.litConst (.bool true))]
        [(["unique_violation"], [.returnLit (.litConst (.bool false))])])
    =
      "    BEGIN\n" ++
      "    RETURN TRUE;\n" ++
      "    EXCEPTION\n" ++
      "        WHEN unique_violation THEN\n" ++
      "    RETURN FALSE;\n" ++
      "    END;\n" := by native_decide

/-- Multi-condition handler (`OR`) — production
    `WHEN unique_violation OR foreign_key_violation THEN`. -/
example :
    printBodyStmt
      (.beginException
        [.returnLit (.litConst (.bool true))]
        [(["unique_violation", "foreign_key_violation"],
          [.returnLit (.litConst (.bool false))])])
    =
      "    BEGIN\n" ++
      "    RETURN TRUE;\n" ++
      "    EXCEPTION\n" ++
      "        WHEN unique_violation OR foreign_key_violation THEN\n" ++
      "    RETURN FALSE;\n" ++
      "    END;\n" := by native_decide

/-- `WHEN OTHERS THEN` catch-all shape. -/
example :
    printBodyStmt
      (.beginException
        [.returnLit (.litConst (.bool true))]
        [(["OTHERS"], [.returnLit (.litConst (.bool false))])])
    =
      "    BEGIN\n" ++
      "    RETURN TRUE;\n" ++
      "    EXCEPTION\n" ++
      "        WHEN OTHERS THEN\n" ++
      "    RETURN FALSE;\n" ++
      "    END;\n" := by native_decide

/-- Two handlers in declaration order. -/
example :
    printBodyStmt
      (.beginException
        [.returnLit (.litConst (.bool true))]
        [ (["unique_violation"], [.returnLit (.litConst (.bool false))])
        , (["OTHERS"],            [.raiseException "fallback" [] none]) ])
    =
      "    BEGIN\n" ++
      "    RETURN TRUE;\n" ++
      "    EXCEPTION\n" ++
      "        WHEN unique_violation THEN\n" ++
      "    RETURN FALSE;\n" ++
      "        WHEN OTHERS THEN\n" ++
      "    RAISE EXCEPTION 'fallback';\n" ++
      "    END;\n" := by native_decide

/-! ## Surface lock -/

example :
    bodyStmtShape
      (.beginException [] [(["OTHERS"], [])])
    = .beginExceptionShape := rfl

end Pg.AstBeginExceptionTest
