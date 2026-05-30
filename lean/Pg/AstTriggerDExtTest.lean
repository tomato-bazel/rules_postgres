/-
Pg.AstTriggerDExtTest — pinning tests for the four
production-trigger Expr extensions added in Triggers-D Phase 2a.

Each `#guard` locks in the exact SQL surface a constructor
renders to. Catches accidental output drift in future refactors
of `printExpr`.

Coverage:
  * `Expr.isNotNull`   — `(<e> IS NOT NULL)`
  * `Expr.coalesce`    — `COALESCE(<e1>, <e2>, …)`
  * `Expr.tgOp`        — `TG_OP`
  * `Expr.tgTableName` — `TG_TABLE_NAME`

These pair with Phase 2b/2c work to encode the production
`graph.invalidate_permission_cache_on_statement` trigger.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty

-- isNotNull: production cache-invalidation WHERE clause uses
-- `v_new_subject_id IS NOT NULL`.
#guard printExpr (.isNotNull (.var "v_new_subject_id"))
  = "(v_new_subject_id IS NOT NULL)"

-- coalesce, two-arg: production trigger uses `COALESCE(NEW, OLD)`
-- in the RETURN.
#guard printExpr (.coalesce [.var "NEW", .var "OLD"])
  = "COALESCE(NEW, OLD)"

-- coalesce, three-arg: ensures the variadic intercalation
-- is correct for longer arg lists.
#guard printExpr (.coalesce [.var "a", .var "b", .litConst (.text "fallback")])
  = "COALESCE(a, b, 'fallback')"

-- coalesce, single-arg: the corner case the variadic form
-- collapses to.
#guard printExpr (.coalesce [.var "only"])
  = "COALESCE(only)"

-- tgOp: bare context variable, no parens.
#guard printExpr .tgOp = "TG_OP"

-- tgTableName: same.
#guard printExpr .tgTableName = "TG_TABLE_NAME"

-- Composition: `TG_OP = 'INSERT'` — the dispatch-by-op pattern
-- the production trigger uses heavily.
#guard printExpr (.eq .tgOp (.litConst (.text "INSERT")))
  = "(TG_OP = 'INSERT')"
