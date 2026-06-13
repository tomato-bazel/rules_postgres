<!-- Generated with Stardoc: http://skydoc.bazel.build -->

User-facing rules for rules_postgres.

* `pg_parse_valid_test` wraps the `parse_check` C binary as a `sh_test`
  that gates a `.sql` file against PostgreSQL's own parser (via
  libpg_query). Passes iff parse_check exits 0, fails with the parser's
  error + cursor position on stderr otherwise. Use this to keep
  emitted-SQL or hand-written-DDL in sync with what PostgreSQL accepts.

* `pg_parse_tree` runs the `sql_to_protobuf` C binary on a `.sql` file
  and captures the marshalled `pg_query.ParseResult` protobuf bytes as
  a `.pgpb` artifact. This is the single-file convenience macro;
  multi-file pipelines should use `sql_library` + `sql_ast_library` from
  `@rules_lang//polyglot:sql.bzl` instead.

<a id="pg_parse_tree"></a>

## pg_parse_tree

<pre>
load("@rules_postgres//postgres:defs.bzl", "pg_parse_tree")

pg_parse_tree(<a href="#pg_parse_tree-name">name</a>, <a href="#pg_parse_tree-sql">sql</a>, <a href="#pg_parse_tree-out">out</a>, <a href="#pg_parse_tree-kwargs">**kwargs</a>)
</pre>

Run libpg_query over a `.sql` file, capture the protobuf AST.

Single-file convenience around `@rules_postgres//tools:sql_to_protobuf`.
For multi-file pipelines, prefer `sql_library` + `sql_ast_library`
from `@rules_lang//polyglot:sql.bzl`, which use the same C tool via
`pg_sql_toolchain` and propagate `SqlAstInfo` so downstream
projections (json, lean, catalog) compose cleanly.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="pg_parse_tree-name"></a>name |  genrule target name.   |  none |
| <a id="pg_parse_tree-sql"></a>sql |  label of the .sql file to parse.   |  none |
| <a id="pg_parse_tree-out"></a>out |  output filename. Defaults to `name + ".pgpb"`.   |  `None` |
| <a id="pg_parse_tree-kwargs"></a>kwargs |  forwarded to the underlying `genrule`.   |  none |

**RETURNS**

A `.pgpb` file whose bytes are exactly the marshalled
`pg_query.ParseResult` (see `@libpg_query//:pg_query.proto`).


<a id="pg_parse_valid_test"></a>

## pg_parse_valid_test

<pre>
load("@rules_postgres//postgres:defs.bzl", "pg_parse_valid_test")

pg_parse_valid_test(<a href="#pg_parse_valid_test-name">name</a>, <a href="#pg_parse_valid_test-sql">sql</a>, <a href="#pg_parse_valid_test-kwargs">**kwargs</a>)
</pre>

Assert that a SQL file parses cleanly under PostgreSQL's parser.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="pg_parse_valid_test-name"></a>name |  test target name.   |  none |
| <a id="pg_parse_valid_test-sql"></a>sql |  label of the .sql file to validate (source, genrule output, or filegroup member — anything with a single-file location).   |  none |
| <a id="pg_parse_valid_test-kwargs"></a>kwargs |  forwarded to the underlying sh_test (e.g. `tags`, `size`, `timeout`).   |  none |


