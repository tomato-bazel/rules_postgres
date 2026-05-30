/-
Pg.AstIfElseIfTest — pinning tests for the
`BodyStmt.ifElseIf` extension added in Triggers-D Phase 2b.

Each `#guard` locks the exact PL/pgSQL surface a multi-branch
IF renders to. Catches accidental output drift in future
refactors of `printBodyStmt` / `printIfElseIfClauses` /
`printElsifClauses` / `printIfElseIfElse`.

Coverage:
  * Single-clause `IF … THEN … END IF;` (no ELSIF, no ELSE)
  * Two-clause `IF … ELSIF … END IF;` (no ELSE)
  * Three-clause `IF … ELSIF … ELSIF … END IF;` (production
    cache-invalidation trigger shape — `IF TG_OP = 'INSERT' …
    ELSIF TG_OP = 'UPDATE' … ELSIF TG_OP = 'DELETE' …`)
  * `IF … ELSE … END IF;` (single clause + ELSE)
  * Empty-clauses degenerate case (no IF, just `END IF;` —
    documents the semantics; production won't emit this shape)

These pair with Phase 2c (declare + assignLocal) and Phase 2d
(updateTable + returnExpr) to encode the production
`graph.invalidate_permission_cache_on_statement` trigger.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty

-- Single-clause IF (no ELSIF, no ELSE).
#guard printBodyStmt
    (.ifElseIf
      [(.eq (.var "x") (.litConst (.int 0)), [.returnLit (.litConst (.int 1))])]
      [])
  = "    IF (x = 0) THEN\n    RETURN 1;\n    END IF;\n"

-- Two-clause IF/ELSIF (no ELSE).
#guard printBodyStmt
    (.ifElseIf
      [ (.eq (.var "x") (.litConst (.int 0)), [.returnLit (.litConst (.int 1))])
      , (.eq (.var "x") (.litConst (.int 1)), [.returnLit (.litConst (.int 2))]) ]
      [])
  = "    IF (x = 0) THEN\n    RETURN 1;\n    ELSIF (x = 1) THEN\n    RETURN 2;\n    END IF;\n"

-- Three-clause IF/ELSIF/ELSIF — the production trigger shape.
-- `IF TG_OP = 'INSERT' THEN … ELSIF TG_OP = 'UPDATE' THEN … ELSIF TG_OP = 'DELETE' THEN …`
-- (each body just RETURN-LIT for the test; production uses
-- assignLocal which lands in Phase 2c).
#guard printBodyStmt
    (.ifElseIf
      [ (.eq (.var "TG_OP") (.litConst (.text "INSERT")),
         [.returnLit (.litConst (.text "INSERT branch"))])
      , (.eq (.var "TG_OP") (.litConst (.text "UPDATE")),
         [.returnLit (.litConst (.text "UPDATE branch"))])
      , (.eq (.var "TG_OP") (.litConst (.text "DELETE")),
         [.returnLit (.litConst (.text "DELETE branch"))]) ]
      [])
  = "    IF (TG_OP = 'INSERT') THEN\n    RETURN 'INSERT branch';\n" ++
    "    ELSIF (TG_OP = 'UPDATE') THEN\n    RETURN 'UPDATE branch';\n" ++
    "    ELSIF (TG_OP = 'DELETE') THEN\n    RETURN 'DELETE branch';\n" ++
    "    END IF;\n"

-- IF/ELSE (single clause + ELSE).
#guard printBodyStmt
    (.ifElseIf
      [(.eq (.var "x") (.litConst (.int 0)), [.returnLit (.litConst (.int 1))])]
      [.returnLit (.litConst (.int 99))])
  = "    IF (x = 0) THEN\n    RETURN 1;\n    ELSE\n    RETURN 99;\n    END IF;\n"

-- Degenerate empty-clauses case — documents that the printer
-- emits a bare `END IF;`. Production code shouldn't construct
-- this shape, but the printer renders it deterministically.
#guard printBodyStmt (.ifElseIf [] []) = "    END IF;\n"

-- Degenerate empty-clauses + ELSE — the ELSE keyword still
-- appears.
#guard printBodyStmt
    (.ifElseIf [] [.returnLit (.litConst (.int 42))])
  = "    ELSE\n    RETURN 42;\n    END IF;\n"
