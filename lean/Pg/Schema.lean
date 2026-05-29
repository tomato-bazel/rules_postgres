/-
Pg.Schema — schema-level predicates for cross-statement
                    consistency.

Tightening D of the libpg_query integration plan. Until now the
AST has been shape-correct (PgAst), type-correct (HasTy), and
meaning-correct on the body (compileBoolBody_faithful), but
consistency *across* multiple emitted statements has been by
faith: nothing prevents a `graph.statement` table from declaring
a FOREIGN KEY referencing `graph.resource(id)` while the
`graph.resource` table is renamed, drops the `id` column, or
declares it with the wrong type.

This file adds:

  * `Schema := List CreateTableStmt` — a multi-table emit unit.
  * `findColumn` / `Schema.findTable` — concrete lookups.
  * `Schema.fkWellFormedB` — Bool-valued well-formedness check
    on a single FK constraint.
  * `Schema.consistentB` — Bool-valued schema-wide consistency.

Bool-valued predicates make the consistency theorem a concrete
`= true` claim discharged by `native_decide` — no
existential-witness gymnastics required, and the cost is trivial
since schemas are concrete data.

The concrete `aionSchema` value (the savvi-studio universal-graph
tables) and the `aionSchema_consistent` theorem live in
`SchemaExamplesBounds.lean`. Adding a new table to the schema or
editing FK targets without preserving the corresponding columns
breaks that proof.

What this catches at proof time:
  - FOREIGN KEY targeting a table that isn't in the schema.
  - FOREIGN KEY targeting a column that isn't in the named table.
  - Mismatched column-count between the FK source and target.
  - Type mismatch between the FK source column and the target
    column (BIGINT FK referencing a TEXT column would fail).
-/

import Pg.Ty
import Pg.Ast
import Pg.Stmt
import Pg.AstSmart

namespace Pg.Schema

open Pg.Ty Polyglot.Sql.Ast Pg.Ast Pg.Stmt

/-- A schema is a list of `CreateTableStmt`s. Order matters only
    for reading; predicates use list lookup which considers all
    members. -/
abbrev Schema : Type := List CreateTableStmt

/-- Look up a column by name within a single table. -/
def findColumn (t : CreateTableStmt) (name : String) : Option ColumnDef :=
  t.columns.find? (fun c => c.name == name)

/-- Look up a table by name. Comparison is against the rendered
    `schema.name` form (matching the pre-Identifier String API). -/
def Schema.findTable (s : Schema) (name : String) : Option CreateTableStmt :=
  s.find? (fun t => t.name.toSql == name)

/-- Bool-valued well-formedness check on a single table-constraint
    against its declaring table and the schema as a whole. Non-FK
    constraints (PK / UNIQUE / CHECK) are well-formed by construction
    here — they reference columns of the *same* table, which we
    leave to the column-side discipline of `CreateTableStmt`. -/
def Schema.fkWellFormedB (s : Schema) (parent : CreateTableStmt) :
    TableConstraint → Bool
  | .foreignKey srcCols refTable refCols _onDel _onUpd _name =>
      -- (1) source columns all exist in `parent`
      srcCols.all (fun src => (findColumn parent src).isSome) &&
      -- (2)+(3) target table exists, target columns all exist in it
      (match s.findTable refTable with
       | none => false
       | some refT =>
           refCols.all (fun ref => (findColumn refT ref).isSome) &&
           -- (4) source / target column-count match
           (srcCols.length == refCols.length) &&
           -- (5) per-position type match
           (srcCols.zip refCols |>.all (fun pair =>
             match findColumn parent pair.1, findColumn refT pair.2 with
             | some sc, some rc => sc.pgType == rc.pgType
             | _, _ => false)))
  | _ => true

/-- A schema is *consistent* iff every constraint of every table
    is well-formed against the schema as a whole. The headline
    cross-statement-consistency property of Tightening D. -/
def Schema.consistentB (s : Schema) : Bool :=
  s.all (fun t => t.constraints.all (fun fk => s.fkWellFormedB t fk))

end Pg.Schema
