/-
Pg.AstInsertDeleteTest — smoke tests for the
`BodyStmt.insertStmt` and `BodyStmt.deleteStmt`
constructors added in Blocker-1 slice 10.

INSERT shape:
  INSERT INTO <table> (<col₁>, <col₂>, …)
    VALUES (<v₁>, <v₂>, …)
    [ON CONFLICT DO NOTHING];

DELETE shape:
  DELETE FROM <table> [WHERE <cond>];

This slice adds:
  - Two AST constructors (`PgAst.lean`)
  - Two pretty-printer rules (`PgPretty.lean`)
  - Two BodyStmtShape variants + two `bodyStmtShape` arms
    (`PgProceduralSurface.lean`)
  - Two trigger-semantics arms — both `.undefined` pending
    the multi-table DbState extension Phase 3 of Triggers-D
    introduces (same dependency `updateTable` carries)

Production users for INSERT include
`auth.try_set_session_id`, `graph.upsert_resource_idempotent`,
and audit-logging helpers that append into rolling tables.
For DELETE: cache-eviction helpers, `audit.purge_old_events`,
and rollback paths in maintenance functions.

The `onConflictDoNothing : Bool` field on `insertStmt`
covers the most common production upsert shape; richer ON
CONFLICT (DO UPDATE SET, ON CONSTRAINT, conflict-target
columns) is a follow-up slice once production needs them.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstInsertDeleteTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## INSERT printer rendering -/

/-- Minimal INSERT: single column, single value. -/
example :
    printBodyStmt
      (.insertStmt "audit.event" ["kind"]
        [.litConst (.text "login")])
    = "    INSERT INTO audit.event (kind) VALUES ('login');\n" := by native_decide

/-- Multi-column INSERT with bound values. -/
example :
    printBodyStmt
      (.insertStmt "graph.resource" ["name", "kind"]
        [.var "p_name", .litConst (.text "user")])
    = "    INSERT INTO graph.resource (name, kind)" ++
      " VALUES (p_name, 'user');\n" := by native_decide

/-- INSERT with `ON CONFLICT DO NOTHING` — the idempotent
    dedupe upsert. -/
example :
    printBodyStmt
      (.insertStmt "auth.session" ["session_id"]
        [.var "p_session_id"] (some .doNothing))
    = "    INSERT INTO auth.session (session_id)" ++
      " VALUES (p_session_id) ON CONFLICT DO NOTHING;\n" := by native_decide

/-- INSERT with `ON CONFLICT (cols) DO UPDATE SET … WHERE …
    RETURNING col INTO var` — the rich upsert shape used by
    production `graph.create_statement` (defect-12 surface). -/
example :
    printBodyStmt
      (.insertStmt "graph.statement"
        ["subject_id", "predicate_id", "object_id"]
        [.var "p_subject_id", .var "p_predicate_id", .var "p_object_id"]
        (some (.doUpdate
          { targetCols := ["subject_id", "predicate_id", "object_id"]
            sets := [("data", .field (.var "graph.statement") "data")]
            whereCond := some
              (.isNull (.field (.var "graph.statement") "valid_to")) }))
        (some ("id", "v_id")))
    = "    INSERT INTO graph.statement" ++
      " (subject_id, predicate_id, object_id)" ++
      " VALUES (p_subject_id, p_predicate_id, p_object_id)" ++
      " ON CONFLICT (subject_id, predicate_id, object_id)" ++
      " DO UPDATE SET data = graph.statement.data" ++
      " WHERE (graph.statement.valid_to IS NULL)" ++
      " RETURNING id INTO v_id;\n" := by native_decide

/-! ## DELETE printer rendering -/

/-- DELETE with WHERE. -/
example :
    printBodyStmt
      (.deleteStmt "auth.session"
        (some (.eq (.var "session_id") (.var "p_session_id"))))
    = "    DELETE FROM auth.session" ++
      " WHERE (session_id = p_session_id);\n" := by native_decide

/-- Bare DELETE — postgres allows it; deletes every row. -/
example :
    printBodyStmt (.deleteStmt "graph.permission_cache" none)
    = "    DELETE FROM graph.permission_cache;\n" := by native_decide

/-! ## Surface lock -/

example :
    bodyStmtShape (.insertStmt "t" [] []) = .insertStmtShape := rfl

example :
    bodyStmtShape (.deleteStmt "t" none) = .deleteStmtShape := rfl

end Pg.AstInsertDeleteTest
