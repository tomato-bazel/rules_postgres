/-
Pg.Smoke — load-test the scaffolded Pg.* stubs.

This file imports every Pg.* and Pg.Catalog.* module declared by the
scaffolding and touches each `placeholder` so the type-checker proves
the imports actually resolve. Run by `:smoke_test` in `lean/BUILD.bazel`.

Once Phase 1 of the PgAst extraction lands real content, this smoke
test stays in place as a structural assertion that the receiving
modules continue to load cleanly. It does NOT exercise the moved
content's semantics — that's Aion's existing test suite's job.

See: ~/Documents/rfcs/narrative/pgast-extraction-*.md
-/

import Pg.Ty
import Pg.RegexAst
import Pg.Ast
import Pg.Pretty
import Pg.Catalog.Oid
import Pg.Catalog.Tables
import Pg.Catalog.RegTypes
import Pg.Catalog.Snapshot
import Pg.Catalog.Resolution
import Pg.Catalog.AttributeRef
import Pg.Catalog.Generated
import Pg.Catalog

namespace Pg.Smoke

/-- Touch every scaffolded module so the import resolution is verified
    at type-check time. As modules transition from stub to real
    content, the touch target moves from `<module>.placeholder` to
    a real symbol exposed by the moved file. -/
def touch : Unit :=
  -- Pg.Ty: real content landed Phase 1b. Touch PgType.toSql.
  let _ := Pg.Ty.PgType.toSql Pg.Ty.PgType.bigint
  -- Pg.RegexAst: real content landed Phase 1b. Touch the inductive.
  let _ : Pg.RegexAst.PgRegexAst := Pg.RegexAst.PgRegexAst.anchorStart
  -- Pg.Catalog.Oid: real content landed Phase 1b.
  let _ : Pg.Catalog.OidKind := Pg.Catalog.OidKind.relation
  -- Pg.Catalog.Tables: real content landed Phase 1b.
  let _ : Pg.Catalog.RelKind := Pg.Catalog.RelKind.ordinaryTable
  -- Pg.Catalog.Snapshot: real content landed Phase 1b.
  let _ : Pg.Catalog.Snapshot := {}
  -- Pg.Catalog.RegTypes: real content landed Phase 1b.
  let _ : Pg.Catalog.QualifiedName :=
    Pg.Catalog.QualifiedName.qualified "pg_catalog" "pg_class"
  -- Pg.Catalog.Resolution: real content landed Phase 1b.
  let _ : Pg.Catalog.SearchPath := []
  -- Pg.Catalog.AttributeRef: real content landed Phase 1b.
  let _ : Pg.Catalog.AttributeRef :=
    { table := Pg.Catalog.QualifiedName.qualified "pg_catalog" "pg_class"
      column := "oid" }
  -- Pg.Catalog.Generated: real content landed Phase 1b.
  -- Touch bootstrapSuperuserid (PG 17.6 reserved oid 10).
  let _ : Pg.Catalog.PgAuthid := Pg.Catalog.Generated.bootstrapSuperuserid
  -- Pg.Ast: real content landed Phase 1b — the Pattern A factor.
  -- Touch a value constructed via the ext hatch to exercise the
  -- mutual-recursion shape end-to-end.
  let _ : Pg.Ast.Expr :=
    Polyglot.Sql.Ast.Expr.ext
      (Pg.Ast.ExprExt.callQualified
        (Pg.Ast.Identifier.qualified "graph" "has_permission") [])
  -- Pg.Ast.BodyStmt: touch a simple case.
  let _ : Pg.Ast.BodyStmt := Pg.Ast.BodyStmt.exitLoop
  -- Pg.Pretty: real content landed Phase 1b. Render the
  -- Pg.Ast.Expr value above to a SQL fragment to exercise the
  -- printExpr ↔ printExprExt mutual dispatch.
  let _ : String := Pg.Pretty.printExpr
    (Polyglot.Sql.Ast.Expr.ext
      (Pg.Ast.ExprExt.callQualified
        (Pg.Ast.Identifier.qualified "graph" "has_permission") []))
  -- Pg.Catalog (umbrella): re-exports the 7 sub-modules; no
  -- placeholder to touch.
  ()

end Pg.Smoke
