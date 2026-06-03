/-
Pg.Ast — Postgres-specific extensions to the generic SQL atlas.

Pattern A factor of the original monolithic PgAst.lean (Aion's
`lean/Aion/Db/PgAst.lean`): the 32 generic SQL Expr constructors
live in `@rules_lang//lean/Polyglot/Sql/Ast.lean`; this module
adds the 22 PG-specific Expr constructors as `ExprExt`, the
7 PG-specific SelectSource constructors as `SelectSourceExt`, the
29-case PL/pgSQL `BodyStmt`, and supporting structures
(`Identifier`, `Volatility`, `RowAlias`, `FuncParam`,
`ConflictUpdate`, `ConflictAction`).

`abbrev Expr := Polyglot.Sql.Ast.Expr ExprExt` is the PG-flavored
expression type. Constructor-style construction works via the
generic ctors (`Expr.var`, `Expr.eq`, `Expr.litConst`, …) AND the
PG ones routed through the `.ext` hatch (`Expr.ext
(ExprExt.callQualified …)`). Aion-side smart constructors keep
call-site usage ergonomic.

Moved from Aion's `lean/Aion/Db/PgAst.lean` as part of PgAst
extraction Phase 1b — see Aion's
`narrative/sql-split-phase-1b-execution-plan.md`. The Create*Stmt
top-level statement structures (CreateFunctionStmt,
CreateSqlFunctionStmt, etc.) land in a sibling `Pg.Stmt` module
in a follow-up sub-step; they don't need the mutual-recursion
treatment that Expr/SelectSource require.

The `infinity` literal moved from the generic LitConst into
`ExprExt.infinity` (it's PG-specific — Aion call sites using
`LitConst.infinity` migrate to `Expr.ext .infinity` via the
shim's smart constructor).
-/

import Polyglot.Sql.Ast
import Pg.Ty
import Pg.RegexAst
import Pg.Catalog.RegTypes

namespace Pg.Ast

/-- Schema-qualified PG identifier. Alias of
    `Pg.Catalog.QualifiedName` so the same value can be used both
    as an emit input and as a key into a `Pg.Catalog.Snapshot`
    for resolution + immunity proofs. -/
abbrev Identifier := Pg.Catalog.QualifiedName

namespace Identifier

/-- Schema-qualified constructor. -/
@[inline] def qualified (schema name : String) : Identifier :=
  Pg.Catalog.QualifiedName.qualified schema name

/-- Unqualified constructor (schema resolution deferred to
    `search_path` at resolve time). -/
@[inline] def unqualified (name : String) : Identifier :=
  Pg.Catalog.QualifiedName.unqualified name

/-- Render to the bare `schema.name` (or `name`) form. -/
@[inline] def toSql (id : Identifier) : String :=
  Pg.Catalog.QualifiedName.renderBare id

end Identifier

/-! ## PG function-volatility classes -/

inductive Volatility where
  | volatile  : Volatility   -- default; can do anything
  | stable    : Volatility   -- same in/out within a transaction
  | immutable : Volatility   -- pure function (no DB access)
deriving DecidableEq

def Volatility.toSql : Volatility → String
  | .volatile  => "VOLATILE"
  | .stable    => "STABLE"
  | .immutable => "IMMUTABLE"

/-! ## PL/pgSQL trigger NEW/OLD row aliases -/

inductive RowAlias where
  | newRow : RowAlias
  | oldRow : RowAlias
deriving DecidableEq

def RowAlias.toSql : RowAlias → String
  | .newRow => "NEW"
  | .oldRow => "OLD"

/-! ## PG-specific Expr extensions (22 constructors)

    Mutual with `Polyglot.Sql.Ast.Expr ExprExt` — sub-Exprs in
    extension constructors route back through the generic AST. -/

mutual
inductive ExprExt where
  -- Catalog-grounded calls (Track R A1)
  | callQualified
      (callee : Identifier)
      (args : List (Polyglot.Sql.Ast.Expr ExprExt))
    : ExprExt
  -- pg_catalog implicit-search-path call (A1c)
  | callBuiltin
      (name : String)
      (args : List (Polyglot.Sql.Ast.Expr ExprExt))
    : ExprExt
  -- Catalog-grounded EXISTS (A1b2)
  | existsInQualified
      (table : Identifier)
      (cond : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  | existsInAliasedQualified
      (table : Identifier)
      (alias : String)
      (cond : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  -- pg_catalog table in EXISTS (A1g)
  | existsInAliasedBuiltin
      (table : String)
      (alias : String)
      (cond : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  -- PG POSIX regex (uses PgRegexAst)
  | regexMatch
      (subject : Polyglot.Sql.Ast.Expr ExprExt)
      (pattern : Pg.RegexAst.PgRegexAst)
    : ExprExt
  -- PG case-insensitive LIKE
  | ilike
      (subject : Polyglot.Sql.Ast.Expr ExprExt)
      (pattern : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  -- PG `= ANY(arr)` (ANSI uses `IN`)
  | eqAny
      (x : Polyglot.Sql.Ast.Expr ExprExt)
      (arr : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  -- PG ltree extension
  | ltreeDescendantOf
      (l : Polyglot.Sql.Ast.Expr ExprExt)
      (r : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  -- Bitwise OR `a | b` — integer/bitmask operator. Used by
  -- `graph.compute_permission_bits` to combine resource-policy and
  -- statement-policy bitmasks. PG dispatches via `int2or` /
  -- `int4or` / `int8or` based on operand types; the renderer just
  -- emits `(<l> | <r>)`.
  | bitwiseOr
      (l : Polyglot.Sql.Ast.Expr ExprExt)
      (r : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  -- PG JSONB ops
  | jsonbHasKey
      (j : Polyglot.Sql.Ast.Expr ExprExt)
      (k : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  | jsonbGet
      (j : Polyglot.Sql.Ast.Expr ExprExt)
      (k : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  | jsonbGetText
      (j : Polyglot.Sql.Ast.Expr ExprExt)
      (k : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  | jsonbPathGetText
      (j : Polyglot.Sql.Ast.Expr ExprExt)
      (path : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  | jsonbConcat
      (l : Polyglot.Sql.Ast.Expr ExprExt)
      (r : Polyglot.Sql.Ast.Expr ExprExt)
    : ExprExt
  | jsonbExtractText
      (obj : Polyglot.Sql.Ast.Expr ExprExt)
      (key : String)
    : ExprExt
  -- PL/pgSQL trigger context (atoms)
  | tgOp        : ExprExt
  | tgTableName : ExprExt
  -- PG-typed CAST (uses PgType inductive)
  | typeCastPg
      (e : Polyglot.Sql.Ast.Expr ExprExt)
      (t : Pg.Ty.PgType)
    : ExprExt
  -- PG-specific literals
  | infinity : ExprExt
end

/-! ## PG-specific SelectSource extensions (7 constructors) -/

inductive SelectSourceExt where
  -- Catalog-grounded FROM table (A1e)
  | tableQualified
      (table : Identifier)
      (alias : Option String)
    : SelectSourceExt
  -- pg_catalog table in FROM (A1g)
  | tableBuiltin
      (name : String)
      (alias : Option String)
    : SelectSourceExt
  -- CTE / local-scope table ref (A1g)
  | tableLocal
      (name : String)
      (alias : Option String)
    : SelectSourceExt
  -- Catalog-grounded set-returning function in FROM (A1e)
  | functionCallQualified
      (callee : Identifier)
      (args : List (Polyglot.Sql.Ast.Expr ExprExt))
      (alias : Option String)
    : SelectSourceExt
  -- pg_catalog set-returning function (A1g)
  | functionCallBuiltin
      (name : String)
      (args : List (Polyglot.Sql.Ast.Expr ExprExt))
      (alias : Option String)
    : SelectSourceExt
  -- Catalog-grounded WITH ORDINALITY
  | functionCallWithOrdinalityQualified
      (callee : Identifier)
      (args : List (Polyglot.Sql.Ast.Expr ExprExt))
      (tableAlias : String)
      (columnAliases : List String)
    : SelectSourceExt
  -- pg_catalog WITH ORDINALITY (A1g)
  | functionCallWithOrdinalityBuiltin
      (name : String)
      (args : List (Polyglot.Sql.Ast.Expr ExprExt))
      (tableAlias : String)
      (columnAliases : List String)
    : SelectSourceExt

/-- The PG-flavored expression — `Polyglot.Sql.Ast.Expr` carrying
    PG-specific extensions via the `ext` hatch. -/
abbrev Expr := Polyglot.Sql.Ast.Expr ExprExt

/-- The PG-flavored SelectSource. -/
abbrev SelectSource :=
  Polyglot.Sql.Ast.SelectSource SelectSourceExt ExprExt

/-- The PG-flavored SelectQuery. -/
abbrev SelectQuery :=
  Polyglot.Sql.Ast.SelectQuery SelectSourceExt ExprExt

/-! ## PG-specific structures used by BodyStmt -/

/-- Function parameter for PG CREATE FUNCTION + DECLARE blocks. -/
structure FuncParam where
  name : String
  pgType : Pg.Ty.PgType
  default : Option Expr := none
  variadic : Bool := false

/-- ON CONFLICT DO UPDATE target — PG-specific upsert clause. -/
structure ConflictUpdate where
  targetCols : List String
  sets : List (String × Expr)
  whereCond : Option Expr := none

inductive ConflictAction where
  | doNothing : ConflictAction
  | doUpdate  (u : ConflictUpdate) : ConflictAction

/-! ## BodyStmt — PL/pgSQL procedural language (29 cases)

    All PG-specific. References `Expr` (= `Polyglot.Sql.Ast.Expr
    ExprExt`) for sub-expressions and `SelectQuery` for FOR/SELECT
    INTO loops. -/

inductive BodyStmt where
  | ifThenReturn (cond : Expr) (ret : Expr) : BodyStmt
  | returnLit    (ret : Expr) : BodyStmt
  | assignNew    (col : String) (e : Expr) : BodyStmt
  | returnRow    (which : RowAlias) : BodyStmt
  | raiseException
      (message : String) (args : List Expr) (errcode : Option String)
    : BodyStmt
  | ifThenStmt (cond : Expr) (body : List BodyStmt) : BodyStmt
  | ifElseIf
      (clauses : List (Expr × List BodyStmt))
      (elseBody : List BodyStmt)
    : BodyStmt
  | assignLocal (name : String) (e : Expr) : BodyStmt
  -- Legacy String-table DML (unmigrated form)
  | updateTable
      (table : String)
      (sets : List (String × Expr))
      (whereCond : Expr)
    : BodyStmt
  -- Catalog-grounded DML (A1d)
  | updateTableQualified
      (table : Identifier)
      (sets : List (String × Expr))
      (whereCond : Expr)
    : BodyStmt
  | returnExpr  (e : Expr) : BodyStmt
  | returnQuerySelect (exprs : List Expr) : BodyStmt
  | declareBlock (decls : List FuncParam) (body : List BodyStmt) : BodyStmt
  | perform (e : Expr) : BodyStmt
  | raiseNotice (message : String) (args : List Expr) : BodyStmt
  | beginException
      (body : List BodyStmt)
      (handlers : List (List String × List BodyStmt))
    : BodyStmt
  | forRecordInLoop
      (recordVar : String)
      (query : SelectQuery)
      (body : List BodyStmt)
    : BodyStmt
  | selectInto
      (targets : List String)
      (query : SelectQuery)
      (strict : Bool := false)
    : BodyStmt
  | caseStmt
      (subject : Option Expr)
      (clauses : List (List Expr × List BodyStmt))
      (elseBody : List BodyStmt)
    : BodyStmt
  | executeFormat
      (sql : Expr)
      (usingArgs : List Expr)
    : BodyStmt
  | insertStmt
      (table : String)
      (columns : List String)
      (values : List Expr)
      (onConflict : Option ConflictAction := none)
      (returningInto : Option (String × String) := none)
    : BodyStmt
  | insertStmtQualified
      (table : Identifier)
      (columns : List String)
      (values : List Expr)
      (onConflict : Option ConflictAction := none)
      (returningInto : Option (String × String) := none)
    : BodyStmt
  | deleteStmt
      (table : String)
      (whereCond : Option Expr)
    : BodyStmt
  | deleteStmtQualified
      (table : Identifier)
      (whereCond : Option Expr)
    : BodyStmt
  | exitLoop : BodyStmt
  | returnBare : BodyStmt
  | nullStmt : BodyStmt
  | executeFormatInto
      (sql : Expr)
      (intoTargets : List String)
      (usingArgs : List Expr)
    : BodyStmt
  | raiseReraise : BodyStmt

end Pg.Ast
