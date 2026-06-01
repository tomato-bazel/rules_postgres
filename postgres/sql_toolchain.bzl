"""pg_sql_toolchain — registers libpg_query as the postgres SQL parser
for the generic `sql_*_library` rules in `@rules_lang//polyglot:sql.bzl`.

Usage in the consuming module's BUILD:

    load("@rules_postgres//postgres:sql_toolchain.bzl", "pg_sql_toolchain")

    pg_sql_toolchain(
        name = "pg17_libpg_query",
        version = "17-6.2.2",
    )

    toolchain(
        name = "pg_sql_toolchain",
        toolchain = ":pg17_libpg_query",
        toolchain_type = "@rules_lang//polyglot/sql:postgres_toolchain_type",
    )

(register the `toolchain` target via `register_toolchains(...)` in
MODULE.bazel or `--extra_toolchains` on the command line.)

Also exposes:

  * `pg_sql_typed_library` — runs `pgpb_to_lean_ast --typed` over a
    set of `sql_ast_library` deps, producing a `Pg.Query.Top`-typed
    parse result Lean module.

  * `pg_sql_catalog_library_lean` — full catalog projection via the
    kernel-checked Lean fold (`Pg.Catalog.Fold` +
    `Snapshot.toLeanSource`). Drop-in target for `lean_emit` consumers
    that want a `Pg.Catalog.Snapshot` Lean module."""

load("@rules_lang//polyglot:sql.bzl", "SqlAstInfo", "SqlToolchainInfo")
load("@rules_lean//lean:lean.bzl", "lean_emit")

def _pg_sql_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            sqltoolchaininfo = SqlToolchainInfo(
                parser = ctx.executable.parser,
                parser_format = "libpg_query_protobuf",
                proto_descriptor = ctx.file.proto_descriptor,
                version = ctx.attr.version,
                dialect = "postgres",
            ),
        ),
    ]

pg_sql_toolchain = rule(
    implementation = _pg_sql_toolchain_impl,
    attrs = {
        "parser": attr.label(
            executable = True,
            cfg = "exec",
            default = "@rules_postgres//tools:sql_to_protobuf",
            doc = "Parser binary — `.sql` arg, writes protobuf bytes to stdout.",
        ),
        "proto_descriptor": attr.label(
            allow_single_file = [".proto"],
            default = "@libpg_query//:protobuf/pg_query.proto",
            doc = "The `pg_query.proto` schema describing the parser's output.",
        ),
        "version": attr.string(
            mandatory = True,
            doc = "libpg_query release tag, e.g. '17-6.2.2'.",
        ),
    },
    doc = """Postgres dialect toolchain for the rules_lang SQL pipeline.

    Wraps `tools:sql_to_protobuf` (a `pg_query_parse_protobuf` CLI) and
    exposes its output format as `libpg_query_protobuf`. The same
    libpg_query release is used for the schema descriptor, so encoder
    and decoder versions are bound by Bazel resolution.""",
)

# ─── pg_sql_typed_library ──────────────────────────────────────────
#
# Produces a `Pg.Query.Top.TopParseResult` Lean module from a list
# of `sql_ast_library` deps, using `pgpb_to_lean_ast --typed`. The
# resulting `.lean` source can be fed into the kernel-checked Lean
# catalog fold (`Snapshot.ofTopParseResultAugmented`) — the
# Phase 0-7 path that's byte-equivalent to `pg_sql_catalog_library`'s
# C-tool output.
#
# Inputs are sorted by short_path for determinism (same convention
# `sql_catalog_library` uses), so the resulting `TopParseResult.stmts`
# list mirrors the C tool's stmt order exactly.

def _pg_sql_typed_library_impl(ctx):
    entries = []
    for d in ctx.attr.deps:
        entries.extend(d[SqlAstInfo].asts.to_list())
    entries = sorted(entries, key = lambda e: e.sql.short_path)
    ast_files = [e.ast for e in entries]

    out = ctx.actions.declare_file(ctx.attr.module_name + ".lean")
    args = ctx.actions.args()
    args.add("--typed")
    if ctx.attr.skip_other_bytes:
        args.add("--skip-other-bytes")
    args.add("--module", ctx.attr.module_name)
    args.add("--output", out.path)
    for ast in ast_files:
        args.add(ast.path)

    ctx.actions.run(
        inputs = ast_files,
        outputs = [out],
        executable = ctx.executable._tool,
        arguments = [args],
        mnemonic = "PgSqlTyped",
        progress_message = "pgpb_to_lean_ast --typed: %d AST(s) -> %s" %
                           (len(ast_files), out.short_path),
    )
    return [DefaultInfo(files = depset(direct = [out]))]

pg_sql_typed_library = rule(
    implementation = _pg_sql_typed_library_impl,
    attrs = {
        "deps": attr.label_list(
            providers = [SqlAstInfo],
            mandatory = True,
            doc = "`sql_ast_library` targets to combine.",
        ),
        "module_name": attr.string(
            mandatory = True,
            doc = "Lean module name AND output filename stem " +
                  "(no dots — Bazel target names can't have them).",
        ),
        "skip_other_bytes": attr.bool(
            default = False,
            doc = "Replace unrecognized stmts' opaque payload with " +
                  "`_root_.ByteArray.empty`. Saves a lot of Lean " +
                  "elaboration time on schemas heavy in PLpgSQL " +
                  "function bodies. The fold ignores `.other` Nodes " +
                  "entirely, so this never affects Snapshot semantics " +
                  "— only debug info that nothing currently consumes.",
        ),
        "_tool": attr.label(
            default = "@rules_postgres//tools/pgpb_to_lean_ast:pgpb_to_lean_ast",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = """Run `pgpb_to_lean_ast --typed` over all `.pgpb` files in
    the dep closure, producing a single `<module_name>.lean` file
    with a `def parseResult : Pg.Query.Top.TopParseResult`.

    Downstream `lean_test` / `lean_emit` consumers depend on this
    rule and `import <module_name>` to pull in the parsed value.""",
)

# ─── pg_sql_catalog_library_lean ──────────────────────────────────
#
# Full catalog projection via the kernel-checked Lean fold
# (`Pg.Catalog.Fold` + the `Snapshot.toLeanSource` printer).
#
# Pipeline expanded by the macro:
#
#   pg_sql_typed_library(name + "_typed", deps)
#       → <typed_module>.lean   (Pg.Query.Top.TopParseResult)
#
#   genrule(name + "_main_lean") writes a small Main.lean that
#   imports the typed parse result + the printer, runs
#       Snapshot.ofTopParseResultAugmentedWithEnums
#   on it, and IO.println's the printer output.
#
#   lean_emit(name) runs Main.lean and captures stdout to
#       <name>.lean — a `Pg.Catalog.Snapshot` Lean module ready for
#       downstream consumers.

_LEAN_DEPS = [
    "@rules_postgres//lean:Pg/Catalog/Oid.lean",
    "@rules_postgres//lean:Pg/Catalog/Tables.lean",
    "@rules_postgres//lean:Pg/Catalog/RegTypes.lean",
    "@rules_postgres//lean:Pg/Catalog/Snapshot.lean",
    "@rules_postgres//lean:Pg/Catalog/SnapshotEmit.lean",
    "@rules_postgres//lean:Pg/Query/Top.lean",
    "@rules_postgres//lean:Pg/Catalog/Fold.lean",
]

def pg_sql_catalog_library_lean(
        name,
        deps,
        module_name,
        skip_other_bytes = True,
        **kwargs):
    """Catalog projection backed by the kernel-checked Lean fold.

    Args:
      name: output target name; emits `<name>.lean`.
      deps: `sql_ast_library` targets to fold over.
      module_name: Lean `namespace` for the emitted file (e.g.
        `"Aion.V0.Codegen.SavviInitialSchema"`). Inside it,
        `def snapshot : Snapshot` and `def enumLabels` are exported.
      skip_other_bytes: drop bytes of unrecognized DDL stmts in the
        typed decoder output. Default `True` — fold ignores them.
      **kwargs: forwarded to the underlying `lean_emit`.
    """
    typed_name = name + "_typed"
    typed_module = "Typed_" + name

    pg_sql_typed_library(
        name = typed_name,
        deps = deps,
        module_name = typed_module,
        skip_other_bytes = skip_other_bytes,
    )

    main_genrule = name + "_main_lean"
    main_lean = main_genrule + ".lean"

    native.genrule(
        name = main_genrule,
        outs = [main_lean],
        cmd = (
            "cat > $@ <<'EOF'\n" +
            "import Pg.Catalog.SnapshotEmit\n" +
            "import Pg.Catalog.Fold\n" +
            "import " + typed_module + "\n\n" +
            "def main : IO Unit :=\n" +
            "  let (snap, enums) := Pg.Catalog.Snapshot.ofTopParseResultAugmentedWithEnums\n" +
            "      " + typed_module + ".parseResult\n" +
            "  IO.println (Pg.Catalog.Snapshot.toLeanSource snap enums " +
            "\"" + module_name + "\")\n" +
            "EOF\n"
        ),
    )

    lean_emit(
        name = name,
        srcs = _LEAN_DEPS + [
            ":" + typed_name,
            ":" + main_genrule,
        ],
        entry = main_lean,
        out = name + ".lean",
        **kwargs
    )
