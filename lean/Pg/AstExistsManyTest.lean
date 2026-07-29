/-
Pg.AstExistsManyTest — smoke tests for `existsInAliasedMany`, the
multi-table EXISTS.

Shape:
  EXISTS (SELECT 1 FROM <t1> AS <a1>, <t2> AS <a2>, … WHERE <cond>)

WHY IT EXISTS. Found the same way as `alterTable`: by emitting a
real schema against this AST. The savvifi/graph substrate renders
its RLS policies from a Lean catalog, and three of the four on
`graph.statement` emit fine with `existsInAliasedQualified` — each
needs a single correlated subquery over `graph.resource`:

  EXISTS (SELECT 1 FROM graph.resource AS r
          WHERE r.id = statement.subject_id AND has_permission(…))

The fourth cannot be said at all. `statement_insert` joins the
policy table to the predicate resource:

  NOT EXISTS (SELECT 1 FROM graph.statement_policy AS sp
              JOIN graph.resource AS prd ON prd.id = statement.predicate_id
              WHERE sp.is_active AND …)

and the one-table arm takes exactly one table plus an alias. So the
substrate's subtlest policy — the clause that stops a caller wiring
a permission-granting edge to a resource they can merely write —
stayed hand-written while its three siblings became emitted.

WHY A COMMA-JOIN RATHER THAN A JOIN CLAUSE. `FROM a AS x, b AS y
WHERE p` is exactly equivalent to `FROM a AS x JOIN b AS y ON p`,
and expressing it this way keeps the printer free of a join grammar
— no join kinds, no ON/USING distinction, no nesting. The join
predicate and the outer correlation both become conjuncts of
`cond`, which is where they read most naturally anyway. If an
OUTER join is ever needed the equivalence stops holding and a real
join clause becomes the right answer; nothing needs one yet.

WHY NOT REPLACE THE ONE-TABLE ARM. `existsInAliasedQualified` is
the overwhelmingly common shape, and `[(t, "r")]` reads worse than
`t "r"` at every call site. Two arms, one of which is the singleton
case of the other, is the smaller cost.

NON-EMPTINESS is a caller obligation, stated below rather than
enforced in the type. An empty `tables` renders `FROM  WHERE`,
which postgres rejects — so the failure is loud and immediate at
apply time, not silent. Callers pass literal lists, so a
`List.length > 0` proof obligation at every construction site
would cost more than it catches.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty

namespace Pg.AstExistsManyTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty

/-! ## Rendering -/

/-- Two tables — the shape `statement_insert` needs. -/
example :
    printExpr (.ext (.existsInAliasedMany
      [ (Identifier.qualified "graph" "statement_policy", "sp")
      , (Identifier.qualified "graph" "resource", "prd") ]
      (.eq (.field (.var "prd") "id") (.field (.var "statement") "predicate_id"))))
    = "EXISTS (SELECT 1 FROM graph.statement_policy AS sp, graph.resource AS prd "
      ++ "WHERE (prd.id = statement.predicate_id))" := by native_decide

/-- One table — the singleton case renders identically to
    `existsInAliasedQualified`, so switching between them is a
    refactor and not a change in emitted SQL. -/
example :
    printExpr (.ext (.existsInAliasedMany
      [ (Identifier.qualified "graph" "resource", "r") ]
      (.eq (.field (.var "r") "id") (.field (.var "statement") "subject_id"))))
    = printExpr (.ext (.existsInAliasedQualified
      (Identifier.qualified "graph" "resource") "r"
      (.eq (.field (.var "r") "id") (.field (.var "statement") "subject_id")))) := by
  native_decide

/-- Three tables, to show the separator is applied between elements
    and not appended after the last one — the off-by-one a manual
    `foldl` would get wrong. -/
example :
    printExpr (.ext (.existsInAliasedMany
      [ (Identifier.unqualified "a", "x")
      , (Identifier.unqualified "b", "y")
      , (Identifier.unqualified "c", "z") ]
      (.litConst (.bool true))))
    = "EXISTS (SELECT 1 FROM a AS x, b AS y, c AS z WHERE TRUE)" := by native_decide

/-- Negation composes, which is what `statement_insert` actually
    needs — its clause is `NOT EXISTS (…) OR EXISTS (…)`. -/
example :
    printExpr (.not_ (.ext (.existsInAliasedMany
      [ (Identifier.unqualified "t", "x") ]
      (.litConst (.bool true)))))
    = "NOT (EXISTS (SELECT 1 FROM t AS x WHERE TRUE))" := by native_decide

end Pg.AstExistsManyTest
