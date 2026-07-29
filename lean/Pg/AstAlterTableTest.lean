/-
Pg.AstAlterTableTest — smoke tests for the `alterTable` statement
constructor and the `IndexElem.opclass` field.

ALTER TABLE shape:
  ALTER TABLE <name> <action>;

where <action> is one of the four row-level-security toggles.

WHY THESE TWO, AND WHY NOW. Both were found by emitting a real
schema against this AST — the savvifi/graph substrate, which
renders four tables, five indexes and four RLS policies from a
Lean catalog. Everything else it needed was already here:
per-column referential actions, IF NOT EXISTS, partial indexes,
gist/gin/btree, table-level PK/UNIQUE/CHECK, function-call and
cast DEFAULTs, and CREATE POLICY with FOR/USING/WITH CHECK.

These were the two gaps.

ENABLE vs FORCE is the one that matters. `ENABLE ROW LEVEL
SECURITY` makes policies apply to ordinary roles but leaves the
table OWNER exempt; `FORCE` removes that exemption. A schema
carrying ENABLE and no FORCE, read by a service that owns its
tables, has policies that never run — and `pg_policy` looks
identical either way, so nothing surfaces it. A schema emitter
that cannot say FORCE cannot state the property that makes its
policies load-bearing.

The opclass field matters more narrowly: postgres picks a default
operator class per (type, access method), and for most columns
that default is right. For `ltree` under GiST it decides whether
`<@` ancestor matching uses the index or scans — a
correctness-shaped performance property a schema should be able
to state rather than hope for.

ADD COLUMN / DROP COLUMN are the obvious next `AlterTableAction`
arms and are deliberately omitted: a migration DSL that can drop
columns raises a different safety question, and nothing needs it
yet.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty

namespace Pg.AstAlterTableTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty

/-! ## ALTER TABLE rendering -/

/-- The RLS enablement a schema emitter needs. -/
example :
    printStmt (.alterTable
      { name := Identifier.qualified "graph" "resource"
      , action := .enableRowLevelSecurity })
    = "ALTER TABLE graph.resource ENABLE ROW LEVEL SECURITY;\n" := by native_decide

/-- FORCE — the arm that removes the owner's exemption, and the
    reason this constructor exists. -/
example :
    printStmt (.alterTable
      { name := Identifier.qualified "graph" "statement"
      , action := .forceRowLevelSecurity })
    = "ALTER TABLE graph.statement FORCE ROW LEVEL SECURITY;\n" := by native_decide

/-- Both negative arms, so a schema can turn RLS off deliberately
    rather than by omission. -/
example :
    printStmt (.alterTable
      { name := Identifier.qualified "graph" "resource"
      , action := .disableRowLevelSecurity })
    = "ALTER TABLE graph.resource DISABLE ROW LEVEL SECURITY;\n" := by native_decide

example :
    printStmt (.alterTable
      { name := Identifier.qualified "graph" "resource"
      , action := .noForceRowLevelSecurity })
    = "ALTER TABLE graph.resource NO FORCE ROW LEVEL SECURITY;\n" := by native_decide

/-- Banner comments, same convention as every other statement. -/
example :
    printStmt (.alterTable
      { name := Identifier.qualified "graph" "resource"
      , action := .forceRowLevelSecurity
      , banner := ["-- the owner is not exempt"] })
    = "-- the owner is not exempt\n\n" ++
      "ALTER TABLE graph.resource FORCE ROW LEVEL SECURITY;\n" := by native_decide

/-- An unqualified target still renders. -/
example :
    printStmt (.alterTable
      { name := Identifier.unqualified "resource"
      , action := .enableRowLevelSecurity })
    = "ALTER TABLE resource ENABLE ROW LEVEL SECURITY;\n" := by native_decide

/-! ## IndexElem.opclass -/

/-- Absent opclass renders exactly as before — this is the
    regression guard for every index already emitted. -/
example :
    printCreateIndex
      { name := Identifier.unqualified "idx_resource_kind"
      , table := Identifier.qualified "graph" "resource"
      , method := .gist
      , columns := [{ column := "kind" }] }
    = "CREATE INDEX idx_resource_kind ON graph.resource USING gist (kind);\n"
    := by native_decide

/-- With an opclass: the `ltree` GiST case that motivated it. -/
example :
    printCreateIndex
      { name := Identifier.unqualified "idx_resource_kind"
      , table := Identifier.qualified "graph" "resource"
      , method := .gist
      , columns := [{ column := "kind", opclass := some "gist_ltree_ops" }] }
    = "CREATE INDEX idx_resource_kind ON graph.resource USING gist (kind gist_ltree_ops);\n"
    := by native_decide

/-- Mixed: one column with an opclass, one without, in a
    multi-column index. -/
example :
    printCreateIndex
      { name := Identifier.unqualified "idx_mixed"
      , table := Identifier.qualified "graph" "statement"
      , columns :=
          [ { column := "subject_id" }
          , { column := "kind", opclass := some "gist_ltree_ops" } ] }
    = "CREATE INDEX idx_mixed ON graph.statement USING btree (subject_id, kind gist_ltree_ops);\n"
    := by native_decide

/-- opclass composes with a partial index, which is the shape the
    live-row indexes actually use. -/
example :
    printCreateIndex
      { name := Identifier.unqualified "idx_active_kind"
      , table := Identifier.qualified "graph" "resource"
      , method := .gist
      , columns := [{ column := "kind", opclass := some "gist_ltree_ops" }]
      , whereExpr := some (.isNull (.var "deleted_at")) }
    = "CREATE INDEX idx_active_kind ON graph.resource USING gist (kind gist_ltree_ops)" ++
      " WHERE (deleted_at IS NULL);\n" := by native_decide

end Pg.AstAlterTableTest
