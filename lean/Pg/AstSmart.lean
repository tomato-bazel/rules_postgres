/-
Pg.AstSmart — smart constructors for the PG-extension Pg.Ast.Expr
and Pg.Ast.SelectSource constructors.

The Pattern A factor moved Aion's monolithic `Pg.Ast.Expr` into
`Polyglot.Sql.Ast.Expr` (generic 32 ctors) + `Pg.Ast.ExprExt` (22
PG-specific ctors). Construction via `.ext (.callQualified ...)`
works but is verbose. This module provides smart constructors that
let existing Aion call sites continue to write
`Pg.Ast.Expr.callQualified callee args` (without source change) by
defining matching `def`s under `namespace Pg.Ast` that wrap the
`.ext` indirection.

Pattern matches still need to use the `.ext (.X ...)` form (Lean's
dot patterns can't refer to defs); those sites migrate in-place.

This file extends the `Pg.Ast` namespace from Aion-side — Lean
allows namespace extension across modules/repos. Imports of
`Pg.Ast` automatically see these smart ctors.
-/

import Pg.Ast

/-! Smart ctors are added to the `Polyglot.Sql.Ast.Expr` and
    `Polyglot.Sql.Ast.SelectSource` namespaces (the HEADS of the
    types) so Lean's dot notation (`.regexMatch e p` etc.) resolves
    them. Lean's dot notation looks at the type's HEAD symbol, not
    the type's abbreviation — `.X` on a value of type
    `Polyglot.Sql.Ast.Expr Pg.Ast.ExprExt` looks for
    `Polyglot.Sql.Ast.Expr.X`, never for `Pg.Ast.Expr.X`. -/

open Pg.Ast

namespace Polyglot.Sql.Ast

namespace Expr

@[inline] def callQualified (callee : Pg.Ast.Identifier) (args : List Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.callQualified callee args)

@[inline] def callBuiltin (name : String) (args : List Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.callBuiltin name args)

@[inline] def existsInQualified (table : Pg.Ast.Identifier) (cond : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.existsInQualified table cond)

@[inline] def existsInAliasedQualified
    (table : Pg.Ast.Identifier) (alias : String) (cond : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.existsInAliasedQualified table alias cond)

@[inline] def existsInAliasedBuiltin
    (table : String) (alias : String) (cond : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.existsInAliasedBuiltin table alias cond)

@[inline] def regexMatch (subject : Pg.Ast.Expr) (pattern : Pg.RegexAst.PgRegexAst) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.regexMatch subject pattern)

@[inline] def ilike (subject pattern : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.ilike subject pattern)

@[inline] def eqAny (x arr : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.eqAny x arr)

@[inline] def ltreeDescendantOf (l r : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.ltreeDescendantOf l r)

@[inline] def jsonbHasKey (j k : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.jsonbHasKey j k)

@[inline] def jsonbGet (j k : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.jsonbGet j k)

@[inline] def jsonbGetText (j k : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.jsonbGetText j k)

@[inline] def jsonbPathGetText (j path : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.jsonbPathGetText j path)

@[inline] def jsonbConcat (l r : Pg.Ast.Expr) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.jsonbConcat l r)

@[inline] def jsonbExtractText (obj : Pg.Ast.Expr) (key : String) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.jsonbExtractText obj key)

@[inline] def tgOp : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext ExprExt.tgOp

@[inline] def tgTableName : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext ExprExt.tgTableName

@[inline] def typeCastPg (e : Pg.Ast.Expr) (t : Pg.Ty.PgType) : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext (ExprExt.typeCastPg e t)

@[inline] def infinity : Pg.Ast.Expr :=
  Polyglot.Sql.Ast.Expr.ext ExprExt.infinity

end Expr

namespace SelectSource

@[inline] def tableQualified (table : Pg.Ast.Identifier) (alias : Option String) : Pg.Ast.SelectSource :=
  Polyglot.Sql.Ast.SelectSource.ext (SelectSourceExt.tableQualified table alias)

@[inline] def tableBuiltin (name : String) (alias : Option String) : Pg.Ast.SelectSource :=
  Polyglot.Sql.Ast.SelectSource.ext (SelectSourceExt.tableBuiltin name alias)

@[inline] def tableLocal (name : String) (alias : Option String) : Pg.Ast.SelectSource :=
  Polyglot.Sql.Ast.SelectSource.ext (SelectSourceExt.tableLocal name alias)

@[inline] def functionCallQualified
    (callee : Pg.Ast.Identifier) (args : List Pg.Ast.Expr) (alias : Option String) : Pg.Ast.SelectSource :=
  Polyglot.Sql.Ast.SelectSource.ext (SelectSourceExt.functionCallQualified callee args alias)

@[inline] def functionCallBuiltin
    (name : String) (args : List Pg.Ast.Expr) (alias : Option String) : Pg.Ast.SelectSource :=
  Polyglot.Sql.Ast.SelectSource.ext (SelectSourceExt.functionCallBuiltin name args alias)

@[inline] def functionCallWithOrdinalityQualified
    (callee : Pg.Ast.Identifier) (args : List Pg.Ast.Expr)
    (tableAlias : String) (columnAliases : List String) : Pg.Ast.SelectSource :=
  Polyglot.Sql.Ast.SelectSource.ext
    (SelectSourceExt.functionCallWithOrdinalityQualified callee args tableAlias columnAliases)

@[inline] def functionCallWithOrdinalityBuiltin
    (name : String) (args : List Pg.Ast.Expr)
    (tableAlias : String) (columnAliases : List String) : Pg.Ast.SelectSource :=
  Polyglot.Sql.Ast.SelectSource.ext
    (SelectSourceExt.functionCallWithOrdinalityBuiltin name args tableAlias columnAliases)

end SelectSource

end Polyglot.Sql.Ast
