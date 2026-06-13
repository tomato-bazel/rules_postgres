<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Module extension for rules_postgres.

Exposes two tag classes:

  pg.query(version = ...)  — fetches libpg_query and builds it as a
                             `cc_library`. Creates @libpg_query.

  pg.source(version = ...) — fetches the full PostgreSQL source tarball
                             and lays a minimal BUILD overlay on top
                             (filegroups for source dirs + a probe
                             `pg_common_string` cc_library). Creates
                             @postgres_src.

The two paths are independent. Most consumers want only `pg.query` for
SQL parse-validation gates; `pg.source` is for advanced tooling that
needs the full PG codebase under Bazel.

Default usage:

    pg = use_extension("@rules_postgres//postgres:extensions.bzl", "pg")
    pg.query(version = "17-6.2.2")
    use_repo(pg, "libpg_query")

With full PG source as well:

    pg.source(version = "17.6")
    use_repo(pg, "libpg_query", "postgres_src")

For generating compile_commands.json (consumable by rules_lang's
c_ast_dump_from_compdb), see `pg_meson_configure` in
`postgres/meson.bzl`. That rule runs a hermetic `meson setup` as a
Bazel build action using rules_foreign_cc's meson + ninja toolchains.

<a id="pg"></a>

## pg

<pre>
pg = use_extension("@rules_postgres//postgres:extensions.bzl", "pg")
pg.query(<a href="#pg.query-version">version</a>)
pg.source(<a href="#pg.source-lay_overlay">lay_overlay</a>, <a href="#pg.source-version">version</a>)
</pre>

Module extension fetching libpg_query and/or the full PostgreSQL source tree.


**TAG CLASSES**

<a id="pg.query"></a>

### query

Pull libpg_query as @libpg_query.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="pg.query-version"></a>version |  libpg_query release tag (e.g. "17-6.2.2").   | String | required |  |

<a id="pg.source"></a>

### source

Pull the PostgreSQL source tarball as @postgres_src.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="pg.source-lay_overlay"></a>lay_overlay |  If True (default), symlink hand-written pg_config.h overlay headers into src/include/. Set False when using pg_meson_configure for AST extraction — see the lay_overlay attr on _postgres_src_repository for the shadowing-via-same-dir-#include explanation.   | Boolean | optional |  `True`  |
| <a id="pg.source-version"></a>version |  PostgreSQL release version (e.g. "17.6").   | String | required |  |


