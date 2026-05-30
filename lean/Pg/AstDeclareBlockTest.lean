/-
Pg.AstDeclareBlockTest — smoke tests for the
`BodyStmt.declareBlock` constructor added in Blocker-1
slice 2 (DECLARE … BEGIN … END sub-block).

The constructor models the production PL/pgSQL pattern:

  DECLARE
      v1 type;
      v2 type := default_expr;
  BEGIN
      stmts;
  END;

used inside `auth.*` and `graph.*` function bodies whenever
a function needs a local scope that's narrower than the
function-level DECLARE — typically a "prelude" block at the
top of the function body, or an error-handling local in a
branch.

This slice adds:
  - The AST constructor (`PgAst.lean`, reusing `FuncParam`
    for `decls` the same way the function-level DECLARE does)
  - The pretty-printer rule (`PgPretty.lean`) — emits the
    DECLARE/BEGIN/END shape with the inner body rendered via
    the mutual `printBodyStmts` walker; supports the optional
    `:= <default>` suffix on each decl via `FuncParam.default`
  - The procedural-surface lock (`PgProceduralSurface.lean`)
  - The trigger-semantics fallthrough (`PgTriggerSemantics.lean`
    marks the constructor `.undefined` — body-level DECLARE
    requires a frame-stack TriggerContext that Phase 3 of
    Triggers-D doesn't ship yet)

Subsequent Blocker-1 slices add: FOR record IN <query> LOOP,
CASE WHEN … END CASE, BEGIN … EXCEPTION WHEN OTHERS THEN …,
PERFORM, RAISE NOTICE, SELECT INTO, EXECUTE format(...),
and INSERT/DELETE within function bodies.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstDeclareBlockTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## Printer rendering

    The production shape indents the inner declarations to 8
    spaces and the surrounding `DECLARE` / `BEGIN` / `END;`
    keywords to 4 spaces (matching the rest of the body
    statement convention). -/

/-- Single-decl, single-stmt body — the minimal nontrivial
    shape: declare one BIGINT local, then return it. -/
example :
    printBodyStmt
      (.declareBlock
        [{ name := "v_count", pgType := .bigint }]
        [.returnLit (.litConst (.int 0))])
    =
      "    DECLARE\n" ++
      "        v_count BIGINT;\n" ++
      "    BEGIN\n" ++
      "    RETURN 0;\n" ++
      "    END;\n" := by native_decide

/-- Two decls (one with a default-expr init), one body
    statement — the "prelude" pattern used by several
    `auth.*` and `graph.*` functions. -/
example :
    printBodyStmt
      (.declareBlock
        [ { name := "v_now", pgType := .timestamptz,
            default := some (.callBuiltin "NOW" []) }
        , { name := "v_count", pgType := .bigint } ]
        [.returnLit (.litConst (.bool true))])
    =
      "    DECLARE\n" ++
      "        v_now TIMESTAMPTZ := NOW();\n" ++
      "        v_count BIGINT;\n" ++
      "    BEGIN\n" ++
      "    RETURN TRUE;\n" ++
      "    END;\n" := by native_decide

/-- Empty decl list — degenerate but the printer handles it
    cleanly. PG would reject a `DECLARE` with no entries but
    the AST representation is structural. -/
example :
    printBodyStmt (.declareBlock [] [.returnLit (.litConst (.bool false))])
    =
      "    DECLARE\n" ++
      "    BEGIN\n" ++
      "    RETURN FALSE;\n" ++
      "    END;\n" := by native_decide

/-! ## Surface lock

    The new constructor must be visible in `bodyStmtShape` +
    `BodyStmt.exhaustive_known`. If a future change drops the
    `declareBlock` case from either, the build breaks. -/

example :
    bodyStmtShape
      (.declareBlock [{ name := "v", pgType := .bigint }]
                     [.returnLit (.litConst (.int 1))])
    = .declareBlockShape := rfl

end Pg.AstDeclareBlockTest
