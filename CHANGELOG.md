# Changelog

All notable changes to rules_postgres. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.5.2 — pgpb_codegen Phase 2: --stub + --roots; DDL-aligned default

The design-doc file-split strategy doesn't actually work: every
stmt's fields reference `Node` (via `repeated Node coldeflist` /
`tableElts` / `parameters` / `vals`), and `Node`'s oneof references
every stmt — so all 273 messages form one SCC. Lean can't elaborate
the resulting mutual block even with `maxHeartbeats` bumped 16×.

This release pivots to a different tactic: **stub-based SCC break.**

**New flags on `pgpb_codegen.py`:**

  * `--roots Foo,Bar,...` — scope the generated output to the
    transitive closure from the named messages. Closure traversal
    stops at stubbed types (see below).

  * `--stub 'Name=LeanType:default'` — replace every reference to
    the proto message `Name` with the given Lean type literal, and
    treat it as a terminal node in the reachability walk. The
    canonical use is

        --stub 'Node=_root_.ByteArray:_root_.ByteArray.empty'

    which makes every `Node` field an opaque `ByteArray`. The SCC
    breaks; the remaining types form a DAG; Lean elaborates in
    seconds.

**Default generation is now DDL-aligned.** The committed
`lean/Pg/Query/Generated.lean` regenerates with:

    --roots ParseResult,CreateSchemaStmt,CreateDomainStmt, \
            CompositeTypeStmt,CreateEnumStmt,CreateStmt, \
            CreateFunctionStmt
    --stub  Node=_root_.ByteArray:_root_.ByteArray.empty

This matches the six DDL statements `pgpb_to_snapshot.c` already
dispatches on. Output: 156 lines, 15 messages + 3 enums (RoleSpec,
PartitionStrategy, OnCommitAction), elaborates in ~1.4 s.

**What the stub means semantically.** Inside a `CreateStmt`, the
field `tableElts : List ByteArray` carries the raw protobuf bytes
for each ColumnDef / Constraint / TableLikeClause Node payload.
This mirrors what `pgpb_to_snapshot.c` already does (it walks
ColumnDef via the protobuf-c API, treating each `tableElts[i]` as
a typed sub-tree). Consumers that need typed sub-trees decode the
bytes via a future `pgpb_to_lean_ast` lift (Phase 3).

**Trajectory.** Future regenerations can pass smaller stub sets
to expand the typed surface incrementally — e.g. unstub
`ColumnDef` and `Constraint` to add column-level structure
without re-introducing the full SCC. The encoding decisions
from §4 of the design doc (`_root_.` shadow handling, enum
prefix-strip, oneof → inductive, proto3 zero-value defaults)
all carry over.

**Design doc addendum needed.** The §9.2 "split into 5 files"
recommendation is wrong. Phase 2 is not a file split — it's a
SCC break via stubbing. The design doc in
`narrative/proto-to-lean-design-poc.md` (consumer's repo)
should get an addendum reflecting this; left for a follow-up
since the implementation now diverges from §9.2 in a clear way.

## 0.5.1 — pgpb_codegen Phase 1: proto → Lean generator (preview)

Lands the Python generator for the `Pg.Ast`-from-`pg_query.proto`
track designed in `narrative/proto-to-lean-design-poc.md` (in the
consumer's repo).

**New tool**: `@rules_postgres//tools/pgpb_codegen:pgpb_codegen.py`
— standalone Python descriptor walker. Reads a protoc-emitted
`FileDescriptorSet` and emits Lean source matching the proto's
message + enum shape:

  * 273 message types → `structure`s (or `inductive`s for pure-oneof
    messages like `Node`) inside one `mutual ... end` block.
  * 71 enum types → `inductive`s with prefix-stripped, camelCased
    variant names. `_UNDEFINED` 0-values become `.undefined`;
    enums without a sentinel use their first value as default.
  * Field types use `_root_.` qualifiers (`_root_.String`,
    `_root_.List`, `_root_.Float`, etc.) so generated structures
    like `Pg.Query.Float` / `Pg.Query.List` (real proto messages!)
    don't shadow the stdlib inside `namespace Pg.Query`.
  * Reserved-word collisions (`do`, `where`, `default`, `public`,
    etc.) get a trailing underscore.

**Initial output**: `@rules_postgres//lean:Pg/Query/Generated.lean`
— 3793 lines covering the full `pg_query.proto` surface. Committed
as the source of truth; Phase 1c's drift gate (forthcoming) will
re-run the generator on every CI build and byte-diff against this
file.

**Known limitation, Phase 1 → Phase 2**

The whole proto's message universe is one SCC through `Node`, so
the single-file approach uses one giant `mutual ... end`. Lean's
elaborator can't typecheck a 273-type mutual block in any
reasonable time even with `maxHeartbeats` bumped 8×. **The file
parses cleanly but does not yet elaborate.**

Phase 2 (queued, design doc §9.2) splits into five sub-files
under `Pg/Query/Generated/`:

  * `Primitives.lean` — String, Integer, Float, Boolean, etc.
  * `Enums.lean`      — all 71 enums (no mutual)
  * `Node.lean`       — `Node` oneof + Alias, RangeVar, TypeName
  * `Expr.lean`       — expression messages
  * `Stmt.lean`       — statement messages

with carefully-sized `mutual` blocks per file. Each file
elaborates in seconds.

**Why ship Phase 1 anyway**

The encoding decisions in §4 of the design doc — `_root_.` shadow
handling, enum prefix-stripping, oneof → inductive, message →
structure with proto3 zero-value defaults — are all validated by
the parses-cleanly output. Phase 2's split only rearranges; it
doesn't change shape. Committing the generator now means Phase 2
is purely about file partitioning.

**Bazel wiring deferred**

`tools/pgpb_codegen/BUILD.bazel` references a `protoc` binary
that's not in Bazel's hermetic sandbox PATH (host-only). Phase 1c
wires `rules_proto` for a hermetic `protoc` + adds the drift gate.
For now, regen runs as:

    protoc --descriptor_set_out=/tmp/pgquery.desc \\
        --proto_path=<libpg_query>/protobuf \\
        <libpg_query>/protobuf/pg_query.proto
    python3 tools/pgpb_codegen/pgpb_codegen.py \\
        --descriptor /tmp/pgquery.desc \\
        --output lean/Pg/Query/Generated.lean \\
        --version 17-6.2.2

## 0.5.0 — SQL toolchain pipeline (sql_to_protobuf + pgpb_to_snapshot)

Adds the rules_postgres half of the `proto_library`-shaped SQL
toolchain layering jointly hosted with rules_lang 0.0.7+
(`@rules_lang//polyglot:sql.bzl`). Lands two C tools, a toolchain
implementation, and a thin macro wrapper for the catalog projection.

**New C tools** (both hermetic, no Python/shell prerequisite):

- `@rules_postgres//tools:sql_to_protobuf` — CLI around libpg_query's
  `pg_query_parse_protobuf()`. Reads a `.sql` file, writes the
  marshalled `pg_query.ParseResult` protobuf bytes to stdout. This
  is the canonical AST format consumed by every `sql_*_library`
  projection rule. Companion to `parse_check` (which discards the
  parse tree) and `plpgsql_to_json` (which handles the PL/pgSQL
  sub-grammar).

- `@rules_postgres//tools/pgpb_to_snapshot:pgpb_to_snapshot` — folds
  a sequence of `.pgpb` files into a `Pg.Catalog.Snapshot` Lean
  source. Walks CREATE SCHEMA / DOMAIN / COMPOSITE TYPE / ENUM TYPE /
  TABLE / FUNCTION across the input series, maintains running catalog
  state (namespaces, types, relations, attributes, procs, enum-label
  side-table), and emits a self-contained Lean module ready to feed
  downstream codegen. Decodes the `.pgpb` bytes via the protobuf-c
  bindings shipped under `@libpg_query//:pg_query_pb_c` — no protoc
  step, no Python.

**New toolchain + macro** (`postgres/sql_toolchain.bzl`):

- `pg_sql_toolchain(name, version)` — implements the
  `postgres_sql_toolchain_type` declared in
  `@rules_lang//polyglot/sql:BUILD.bazel`. Wraps the
  `sql_to_protobuf` binary; carries the proto descriptor and
  version string for downstream readers.

- `pg_sql_catalog_library(name, deps, module_name, output_format)` —
  thin wrapper around `sql_catalog_library` that pre-fills the
  `folder` attribute with `pgpb_to_snapshot`. Lets consumers omit
  the dialect-specific tool name.

**Single-file convenience macro** (`postgres/defs.bzl`):

- `pg_parse_tree(name, sql, out)` — runs `sql_to_protobuf` on a
  single `.sql` file via a genrule, captures the `.pgpb` output.
  For one-off inspection; multi-file pipelines should use the full
  `sql_library` + `sql_ast_library` stack.

**Schema export tightening** (`postgres/extensions.bzl`):

The `@libpg_query//:pg_query_pb_c` cc_library now declares
`includes = ["protobuf"]` so consumers can `#include "pg_query.pb-c.h"`
without the directory prefix.

**Why now**

Motivated by Aion's V0 codegen track wanting to derive
`Pg.Catalog.Snapshot` values directly from savvi-studio's migration
`.sql` files instead of hand-mirroring them. The full chain
(0.5.0 layered on the 0.4.3 PgProc fields) is:

    sql_library                  (raw .sql, dialect-tagged)
        ↓ pg_sql_toolchain
    sql_ast_library              (.pgpb canonical AST)
        ↓ pg_sql_catalog_library (pgpb_to_snapshot)
    Pg.Catalog.Snapshot.lean
        ↓ functionSpecFromPgProc (Aion-side, 0.4.3 fields)
    FunctionSpec list → codegen output

Plus an `sql_ast_aspect` for sweeps that need to attach parsed ASTs
to every transitively-reachable `sql_library` without per-file rules.

## 0.4.3 — Pg.Catalog.PgProc: + proargnames + proretset + proargmodes

Extends `lean/Pg/Catalog/Tables.lean`'s `PgProc` structure with
three new fields + introduces an `ArgMode` enum:

- `proargnames : List String  := []` — per-argument source name.
  Empty means "fall back to positional `arg0` / `arg1` / …".
- `proretset   : Bool         := false` — set-returning flag
  (`SETOF X`, `RETURNS TABLE(...)`).
- `proargmodes : List ArgMode := []` — IN / OUT / INOUT /
  VARIADIC / TABLE_OUT per argument. Empty means "all IN".

`ArgMode` mirrors postgres's single-char encoding via a closed
inductive (`.in_` / `.out` / `.inout` / `.variadic` / `.tableOut`)
plus a `.toChar` projection for round-tripping with on-disk
representations.

All three new fields default to safe sentinels so existing
`PgProc` literal sites (notably `Pg.Catalog.Generated`'s 3314
procs) compile unchanged. Consumers wanting the precision
populate them explicitly.

Motivated by Aion's V0 codegen Slice 1 (catalog → FunctionSpec
derivation, replacing the hand-coded FunctionSpec list with one
mechanically built from a `Snapshot`'s `procs`). The new fields
are the data the deriver needs:

  * `proargnames` — for naming the TS wrapper's input fields
                    (`p_username` rather than `arg0`).
  * `proretset`   — drives `FunctionSpec.isSetOf`.
  * `proargmodes` — separates IN args (input schema) from OUT
                    args (composite return) and handles INOUT
                    (input AND output) properly.

The extension is additive — no breaking changes — so the
upgrade is a one-line bazel_dep bump.

## 0.4.2 — Pg.Catalog.PgType: + typbasetype + typelem

Extends `lean/Pg/Catalog/Tables.lean`'s `PgType` structure with two
new fields:

- `typbasetype : Oid .type` — for DOMAIN rows, the underlying type
  the domain wraps. `Oid.invalid .type` for non-domain rows.
- `typelem : Oid .type` — for ARRAY rows, the element type. Postgres
  encodes arrays as `typtype = .base` plus `typcategory = 'A'` plus
  a non-invalid `typelem`. `Oid.invalid .type` for non-array rows.

Both default to `Oid.invalid .type` so existing `PgType` literal
sites (in particular `Pg.Catalog.Generated.bootstrapSnapshot`'s 185
type entries) compile unchanged; consumers wanting the precision
populate the fields explicitly.

Motivated by Aion's V0 codegen Slice C, which needs to emit
`z.array(elementSchema)` for array types and walk domains down to
their underlying primitive. The extension is additive — no breaking
changes — so the upgrade is a one-line bazel_dep bump for consumers.

## 0.2.0 — delegate libpg_query fetch to rules_github

- Replace the in-tree libpg_query download logic with a dependency on
  `rules_github`'s `github_source_repository` so the parser source is
  pulled via the shared substrate.
- Update the install snippet to point at the `fastverk/bazel-registry`.

## 0.1.0 — initial release

- First cut of Bazel rules for PostgreSQL tooling: `pg.query` (fetches
  and builds [libpg_query](https://github.com/pganalyze/libpg_query) as
  a `cc_library`), experimental `pg.source` (full PG tarball with a
  minimal BUILD overlay), `pg_parse_valid_test` (sh_test wrapper that
  asserts a `.sql` parses cleanly), and the `parse_check` +
  `plpgsql_to_json` C tools.
