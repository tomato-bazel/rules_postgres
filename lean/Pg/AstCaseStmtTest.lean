/-
Pg.AstCaseStmtTest — smoke tests for the
`BodyStmt.caseStmt` constructor added in Blocker-1 slice 8
(CASE [<subject>] WHEN … END CASE;).

The constructor models the production PL/pgSQL pattern in
both simple-CASE (with subject) and searched-CASE (without)
shapes:

  CASE TG_OP                  -- simple-CASE
      WHEN 'INSERT' THEN
          <body>
      WHEN 'UPDATE', 'DELETE' THEN
          <body2>
  END CASE;

  CASE                        -- searched-CASE
      WHEN p_kind = 'X' THEN
          <body>
      ELSE
          <fallback>
  END CASE;

Searched-CASE is semantically equivalent to `ifElseIf` but
preserves the CASE source shape when round-tripping production
code.

This slice adds:
  - The AST constructor (`PgAst.lean`)
  - The pretty-printer rule + `printCaseClauses` /
    `printCaseElse` helpers in the mutual block
    (`PgPretty.lean`)
  - The procedural-surface lock (`PgProceduralSurface.lean`)
  - The trigger-semantics arm (`PgTriggerSemantics.lean` —
    `.undefined` until value/condition reduction lands)
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstCaseStmtTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## Printer rendering -/

/-- Simple-CASE dispatching on TG_OP — the canonical
    trigger-body shape. -/
example :
    printBodyStmt
      (.caseStmt
        (some (.var "TG_OP"))
        [ ([.litConst (.text "INSERT")],
           [.returnRow .newRow])
        , ([.litConst (.text "UPDATE"), .litConst (.text "DELETE")],
           [.returnRow .oldRow]) ]
        [])
    =
      "    CASE TG_OP\n" ++
      "        WHEN 'INSERT' THEN\n" ++
      "    RETURN NEW;\n" ++
      "        WHEN 'UPDATE', 'DELETE' THEN\n" ++
      "    RETURN OLD;\n" ++
      "    END CASE;\n" := by native_decide

/-- Searched-CASE with ELSE — boolean conditions, fallthrough body. -/
example :
    printBodyStmt
      (.caseStmt
        none
        [ ([.eq (.var "p_kind") (.litConst (.text "X"))],
           [.returnLit (.litConst (.bool true))]) ]
        [.returnLit (.litConst (.bool false))])
    =
      "    CASE\n" ++
      "        WHEN (p_kind = 'X') THEN\n" ++
      "    RETURN TRUE;\n" ++
      "        ELSE\n" ++
      "    RETURN FALSE;\n" ++
      "    END CASE;\n" := by native_decide

/-- Single-clause, no-ELSE shape — postgres raises
    `case_not_found` at runtime if the WHEN doesn't match. -/
example :
    printBodyStmt
      (.caseStmt
        (some (.var "TG_OP"))
        [ ([.litConst (.text "INSERT")],
           [.returnLit (.litConst (.bool true))]) ]
        [])
    =
      "    CASE TG_OP\n" ++
      "        WHEN 'INSERT' THEN\n" ++
      "    RETURN TRUE;\n" ++
      "    END CASE;\n" := by native_decide

/-! ## Surface lock -/

example :
    bodyStmtShape
      (.caseStmt none [] [.returnLit (.litConst (.bool true))])
    = .caseStmtShape := rfl

end Pg.AstCaseStmtTest
