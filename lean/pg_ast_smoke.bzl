"""pg_ast_smoke_test — macro for Pg AST per-constructor smoke tests.

Each smoke test follows an identical pattern: imports the
Polyglot SQL kernel + Pg.Ast / Pg.Stmt / Pg.AstSmart /
Pg.Pretty / Pg.ProceduralSurface; pins printer renderings +
surface-lock examples for one or two BodyStmt constructors.

This macro factors out the common srcs list so adding a new
constructor is one `pg_ast_smoke_test(name, entry)` line
instead of a 12-line `lean_test` invocation.
"""

load("@rules_lean//lean:lean.bzl", "lean_test")

# Common srcs prefix for Pg/AstX*Test.lean files.
_PG_AST_SMOKE_SRCS = [
    "@polyglot_ast//lean:Polyglot/Sql/Ast.lean",
    "Pg/Ty.lean",
    "Pg/RegexAst.lean",
    "Pg/Catalog/Oid.lean",
    "Pg/Catalog/Tables.lean",
    "Pg/Catalog/RegTypes.lean",
    "Pg/Ast.lean",
    "Pg/Stmt.lean",
    "Pg/AstSmart.lean",
    "Pg/Pretty.lean",
    "Pg/ProceduralSurface.lean",
]

def pg_ast_smoke_test(name, entry):
    """Generates a lean_test target for a Pg/AstX*Test.lean file.

    Args:
      name: target name (e.g. "pg_ast_perform_test").
      entry: path to the *.lean test file
        (e.g. "Pg/AstPerformTest.lean"). Used both as the
        lean_test entry and as the trailing srcs entry.
    """
    lean_test(
        name = name,
        srcs = _PG_AST_SMOKE_SRCS + [entry],
        entry = entry,
        visibility = ["//visibility:public"],
    )
