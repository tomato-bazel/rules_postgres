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

Also exposes `pg_sql_catalog_library` — a thin wrapper around
`sql_catalog_library` that pre-fills `folder` with
`@rules_postgres//tools:pgpb_to_snapshot`, so consumers don't have to
hand-thread the postgres-specific catalog folder."""

load("@rules_lang//polyglot:sql.bzl", "SqlToolchainInfo", "sql_catalog_library")

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

def pg_sql_catalog_library(name, deps, module_name = None, output_format = "lean", **kwargs):
    """Catalog projection wrapper that pre-fills the postgres folder.

    Identical to `sql_catalog_library` but binds `folder` to
    `@rules_postgres//tools/pgpb_to_snapshot:pgpb_to_snapshot` so
    consumers don't need to know the dialect-specific tool name.
    """
    sql_catalog_library(
        name = name,
        deps = deps,
        folder = "@rules_postgres//tools/pgpb_to_snapshot:pgpb_to_snapshot",
        module_name = module_name,
        output_format = output_format,
        **kwargs
    )
