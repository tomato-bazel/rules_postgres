# Changelog

All notable changes to rules_postgres. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.6.1 — Pg.Catalog.Fold Phase 1+2: domains, composites, tables

Extends the kernel-checked catalog fold to three more stmt kinds
(`CreateDomainStmt`, `CompositeTypeStmt`, `CreateStmt`) plus the
shared infrastructure for resolving column types — including
user-defined types looked up from the in-progress snapshot.

NEW TYPED SHAPES (`lean/Pg/Query/Top.lean`)

  * `TypeRef` — `{schema, name, oidHint}`. The C decoder fills
    `oidHint` from its `BUILTIN_TYPES` table for `pg_catalog`
    builtins (`text=25`, `int8=20`, …); user types arrive with
    `oidHint = 0` and the Lean fold resolves them via `snap.types`.
  * `ColumnDefSpec` — `{name, typeRef, notNull}`.
  * `TopCreateDomainStmt` — `{qualName, baseType}`.
  * `TopCompositeTypeStmt` — `{qualName, columns}`.
  * `TopCreateStmt` — `{qualName, columns}`.

NEW FOLD HANDLERS (`lean/Pg/Catalog/Fold.lean`)

  * `resolveType : TypeRef → FoldState → Nat` — fast path on the
    OID hint; fallback walks `snap.namespaces` + `snap.types` for
    user types. Catchall is `2249` (record), matching the C
    `type_name_to_oid` sentinel.
  * `foldCreateDomain` — emits `PgType` with `typtype := .domain`
    and `typbasetype` from the resolved type ref.
  * `addRelationWithColumns` — shared helper for composites and
    tables; allocates `(typOid, relOid)` via `alloc2`, stages the
    `PgType` and `PgClass` rows, then folds each `ColumnDefSpec`
    into a `PgAttribute`. The state is advanced row-by-row so each
    column's `resolveType` sees any earlier-allocated user types in
    the same fold (e.g. `CREATE TABLE locations (pos point)` after
    a sibling `CREATE TYPE point AS (...)` resolves correctly).
  * `foldCompositeType` / `foldCreateTable` — thin wrappers around
    the shared helper with `.compositeType` vs `.ordinaryTable`.

C DECODER (`tools/pgpb_to_lean_ast`)

  * `BUILTIN_TYPES[]` table mirrored from `pgpb_to_snapshot.c` —
    same 42 entries (`bool`, `int{8,4,2}`/`{bigint,integer,smallint}`,
    `text`, `varchar`, `uuid`, `date`, `timestamp[tz]`, `interval`,
    `json[b]`, `numeric`, regtypes, array variants, etc).
  * `emit_type_ref` — emits a `{schema, name, oidHint}` from a proto
    `TypeName`. Collapses `pg_catalog` → `none` on the Lean side
    and fills `oidHint` for builtins.
  * `emit_column_def_spec` / `emit_column_def_list` — emits
    `ColumnDefSpec` payloads from `ColumnDef` Nodes; skips
    non-ColumnDef table_elts (e.g. inline Constraint Nodes).
  * `column_notnull` — NOT NULL / PRIMARY KEY constraint detection
    (same logic as `pgpb_to_snapshot.c`).
  * Three new dispatch arms in `emit_typed_top` —
    `CreateDomainStmt`, `CompositeTypeStmt`, `CreateStmt`.

TIGHTENED PIPELINE TEST

  `FoldPipelineTest.lean` now asserts:

    * 3 types (domain + composite + table's implicit row type)
    * 2 relations (composite + table)
    * 5 attributes (point.x, point.y, locations.id/name/position)
    * `identifier.typbasetype = 25` (text builtin via OID hint)
    * `locations.id.atttypid = 20` (int8) and `attnotnull = true`
      (inferred from PRIMARY KEY)
    * `locations.position.atttypid ≡ point.oid` (user-type
      resolution via snapshot walk)

PHASE COVERAGE TODAY

  Phase 0:                CreateSchemaStmt, CreateEnumStmt
  Phase 1 (this release): CreateDomainStmt
  Phase 2 (this release): CompositeTypeStmt, CreateStmt
  Phase 3 (planned):      CreateFunctionStmt
  Phase 4 (planned):      ViewStmt
  Phase 5 (planned):      AlterTableStmt
  Phase 6 (planned):      byte-equivalence diff_test vs
                          pgpb_to_snapshot.c

After Phase 5 the C catalog folder can be retired.

## 0.6.0 — Pg.Catalog.Fold: kernel-checked catalog projection (Phase 0)

The fourth and load-bearing leg of the proto → Lean trust chain.
Catalog projection moves from "trust the C tool" to
"kernel-checked Lean fold."

Previously:

    .pgpb ─pgpb_to_snapshot.c─► Snapshot.lean      (trust C)

Now (in parallel; same input):

    .pgpb ─pgpb_to_lean_ast --typed─► TopParseResult.lean
                                          │
                                          ▼  Lean kernel
                              Snapshot.ofTopParseResult
                                          │
                                          ▼
                                     Snapshot value
                                  (kernel-typechecked)

NEW LEAN MODULES

  `lean/Pg/Query/Top.lean`
    Hand-written wrapper layer that bridges the C decoder and the
    Lean fold. Defines:
      * `QualifiedName` — pre-decoded `[schema.]name`
      * `TopCreateSchemaStmt`, `TopCreateEnumStmt` — Phase 0 variants
      * `TopStmt` inductive — discriminator with `.other ByteArray`
        catchall
      * `TopRawStmt`, `TopParseResult` — mirror Pg.Query.RawStmt /
        Pg.Query.ParseResult one-for-one (modulo the payload type)

  `lean/Pg/Catalog/Fold.lean`
    `FoldState` carries snapshot + nextOid counter. Helpers:
      * `FoldState.alloc` / `alloc2` — OID allocator
      * `FoldState.empty` — seeded with pg_catalog (11) + public (2200)
      * `ensureNamespace` — name lookup with auto-allocate
      * `foldCreateSchema`, `foldCreateEnum` — Phase 0 handlers
      * `foldTopStmt` — top-level dispatch
      * `Snapshot.ofTopParseResult` — the user-facing entry

  `lean/Pg/Catalog/FoldTest.lean`
    Hand-crafted unit tests via `native_decide`:
      * one_schema, dup_schema (dedupe), one_enum, public_enum
        (unqualified → public), opaque_only (.other stays inert)

  `lean/Pg/Catalog/FoldPipelineTest.lean`
    End-to-end: smoke_fixture.sql → .pgpb → typed .lean → fold →
    Snapshot. Asserts the namespace count + presence of the
    test_smoke namespace via `native_decide`.

NEW C-DECODER FLAG

  `tools/pgpb_to_lean_ast --typed` switches output mode:
    * Default: `Pg.Query.RawStmt` with `stmt : ByteArray`
    * Typed:   `Pg.Query.Top.TopRawStmt` with `stmt : TopStmt`

  Typed dispatch handles:
    * `CreateSchemaStmt` → `.createSchemaStmt { schemaname, ifNotExists }`
    * `CreateEnumStmt`   → `.createEnumStmt { qualName, labels }`
    * everything else    → `.other ⟨#[bytes]⟩` (the pre-Phase-0 mode)

  Pre-decoding lives in C (cheap), so the Lean side stays simple
  and proof-discipline-friendly.

PHASE COVERAGE TODAY

  Phase 0 (this release):  CreateSchemaStmt, CreateEnumStmt
  Phase 1 (planned):       CreateDomainStmt (qualName + base typeName)
  Phase 2 (planned):       CompositeTypeStmt, CreateStmt
                           (need ColumnDef pre-decoding)
  Phase 3 (planned):       CreateFunctionStmt (parameters + return)
  Phase 4 (planned):       ViewStmt (target list + FROM clause)
  Phase 5 (planned):       AlterTableStmt
  Phase 6 (planned):       byte-equivalence diff_test
                           pgpb_to_snapshot.c ≡ Snapshot.ofTopParseResult
                           — when green, the C catalog folder retires.

WHY THIS RELEASE BUMPS THE MINOR VERSION

The previous 0.5.x line added pieces to the proto → Lean toolchain.
0.6.0 changes the trust profile: the catalog projection's
correctness now depends on `Pg.Catalog.Fold`'s logic being kernel-
typechecked rather than on `pgpb_to_snapshot.c` being correct. Even
though Phase 0 only covers two stmt kinds, the trust-shift contract
is permanent — consumers depending on Snapshot semantics should know.

## 0.5.5 — pgpb_to_snapshot: view column type inference

Lifts the 15 view schemas in savvi-studio's initial schema from
loose `z.unknown()` placeholders to properly-typed values where the
SELECT projects a direct `tbl.col` reference.

For each `CREATE VIEW <name> AS SELECT ...`:

  1. Walk the SELECT's `from_clause` into a `FromMap` —
     `alias → (schema, relname)`. Handles `RangeVar` directly and
     recurses through `JoinExpr.larg` / `JoinExpr.rarg`.
     RangeSubselect / RangeFunction / etc. are intentionally
     skipped — their columns aren't in our snapshot, so the
     downstream column lookup would fail anyway.

  2. For each ResTarget in the target list, if the value
     expression is a `ColumnRef`:

       * Pull the field parts (`tbl.col` or bare `col`).
       * If qualified, look up `tbl` in the FromMap to find
         (schema, relname); search just that relation's
         attributes for the column.
       * If bare, search all FROM-relation attributes (first
         match wins — same disambiguation strategy postgres
         uses for unqualified refs).

  3. The matched attribute's `atttypid` becomes the view column's
     type. Unresolvable expressions (function calls, CASE
     expressions, casts, subqueries) stay at `2249` → emit
     pipeline produces `z.unknown()`.

**Measured against savvi-studio's initial schema** (15 views, ~135
total view columns):

  * Before: every column emitted as `z.unknown() /* pseudo: record */`.
  * After:  ~80% of columns now carry their real types: `z.string()`,
            `z.bigint()`, `z.number().int()`, `z.boolean()`,
            `z.date()`, and full enum surfaces like
            `z.enum(["symmetric", "hmac", "rsa_public", "rsa_private"])`
            (for `auth.hierarchy_root_keys.key_type`).

The remaining ~20% are computed expressions (`EXTRACT`, `COALESCE`,
arithmetic, function calls) that need expression-level type
inference — significant additional work; flagged for a follow-up
once the catalog projection moves into Lean.

**New helpers** (all internal):

  * `FromMap` + `from_map_init` / `from_map_push` / `from_map_lookup` —
    fixed-capacity table of FROM-clause aliases (32 entries is well
    above any real view's join depth).
  * `from_node_collect` — recursive FROM-clause walker.
  * `resolve_column_oid` — qualified-or-bare column-ref → OID lookup.

## 0.5.4 — pgpb_to_snapshot: ViewStmt + AlterTableStmt handlers

Adds full-schema coverage for the two stmt kinds the snapshot folder
was silently skipping that carry codegen-relevant catalog state.

**ViewStmt** (`CREATE VIEW <schema>.<name> AS SELECT ...`)

  * Registers a `composite` type + `view` relation row for each
    view, using the same OID-allocation scheme as `CREATE TABLE`.
  * Extracts column names from the SELECT's target list — explicit
    `AS alias` first, falling back to the last component of any
    `ColumnRef` expression.
  * Types are emitted as `2249` (record sentinel) so the downstream
    codegen produces `z.unknown()` per column. Full per-column
    type inference (resolving `tbl.col` refs through the FROM
    clause to underlying table columns) is a follow-up.

**AlterTableStmt** subtypes covered:

  * `AT_AddColumn`    — appends a new attribute row, attnum = max+1
  * `AT_DropColumn`   — marks the attribute row (`attrelid := 0`)
                        so the emit loop skips it post-fold
  * `AT_SetNotNull`   — flips `attnotnull` to `true` on the
                        matching attribute
  * `AT_DropNotNull`  — flips it to `false`

  Other subtypes (ADD CONSTRAINT, RENAME, OWNER, etc.) are
  intentionally skipped — none affect column structure or types.

**New helpers:**

  * `find_relation_by_name(snap, schema, name)` — schema-qualified
    relation lookup, used by AlterTableStmt to locate its target.
  * `find_attribute(snap, rel_oid, name)` — by-name attribute
    lookup, used by AT_DropColumn / AT_SetNotNull / AT_DropNotNull.
  * `max_attnum_for(snap, rel_oid)` — for AT_AddColumn's new attnum.
  * `res_target_column_name(res_target)` — extracts a SELECT
    target's column name from either its `name` field or its
    `ColumnRef` payload.

**Measured against savvi-studio's initial_schema** (13 migration files,
1383 stmts total):

  * Before: 321 consumed (23%) — 56 user types, 46 relations,
            268 functions.
  * After:  338 consumed (24%) — **+15 views (Workspace,
            HierarchyRootKeys, VDiagnosticMenu, ...) + 2 ALTERs**.
            The savvi-db-generated TS package gains the 15 view
            schemas (rendered as `z.object({ col: z.unknown()
            .nullable(), ... })` placeholders).

The remaining ~1045 unconsumed stmts are CommentStmt (429),
GrantStmt (414), IndexStmt (74), CreateTrigStmt (7), DoStmt (21),
SelectStmt (16), InsertStmt (10), CreatePolicyStmt (10),
AlterOwnerStmt (8), VariableSetStmt (37), AlterDefaultPrivilegesStmt
(3), DropStmt (3), TruncateStmt (2) — none of which carry catalog
state the codegen pipeline reads. Coverage of the catalog-state-bearing
DDL surface is now ~complete for the savvi codebase.

## 0.5.3 — pgpb_to_lean_ast: C decoder closing the proto → Lean trust chain

Lands the third leg of the proto → Lean trust chain
(`narrative/proto-to-lean-design-poc.md` §7 (b)):

    .sql ─sql_to_protobuf─► .pgpb ─pgpb_to_lean_ast─► .lean
                                                         │ leanc
                                                         ▼
                                       Pg.Query.ParseResult value

**New C tool:** `@rules_postgres//tools/pgpb_to_lean_ast:pgpb_to_lean_ast`

Reads a `pg_query.ParseResult` protobuf payload (output of
`sql_to_protobuf`), walks the unpacked top-level message via the
protobuf-c API, and emits a Lean source file containing a
`def parseResult : Pg.Query.ParseResult` value matching the
Phase 2 stubbed-DDL Generated.lean encoding.

For each RawStmt's Node payload, the decoder calls
`pg_query__node__pack` to recover the sub-message's wire bytes
and emits a `_root_.ByteArray` literal in Lean (`⟨#[0xAB, ...]⟩`).
That matches the Phase 2 stub (`Node → ByteArray`) — consumers
wanting deeper typed decode either pass smaller `--stub` sets at
codegen time or run a follow-on tool on the inner byte payload.

**Same trust profile as `pgpb_to_snapshot`:** hermetic C binary,
depends only on `@libpg_query//:pg_query_pb_c`. No Python, no
shell. ~80% structure reuse from `pgpb_to_snapshot.c` (slurp,
unpack, top-level loop) — the difference is the emit shape
(`ByteArray` literals per stmt rather than catalog rows).

**End-to-end CI gate:** `tools/pgpb_to_lean_ast/smoke_fixture.sql`
covers four DDL stmt kinds (SCHEMA / DOMAIN / TYPE / TABLE) and
flows through the full chain:

    smoke_fixture.sql
        ↓ //tools:sql_to_protobuf
    smoke_fixture.pgpb
        ↓ //tools/pgpb_to_lean_ast:pgpb_to_lean_ast
    SmokeFixture.lean   (Pg.Query.SmokeFixture.parseResult)
        ↓ //lean:pg_query_decoder_smoke_test
    Lean kernel checks the value against Pg.Query.Generated.

A break at any link surfaces at the right step: malformed SQL →
sql_to_protobuf exits non-zero; protobuf-c API drift →
pgpb_to_lean_ast fails to compile or decode; encoding
disagreement between pgpb_codegen and pgpb_to_lean_ast → Lean
kernel rejects the decoder's output.

**Companion tests:**
  * `//lean:pg_query_generated_test` — hand-crafted ParseResult
    values exercising the empty / single / mixed shapes.
  * `//lean:pg_query_decoder_smoke_test` — the end-to-end pipeline
    above.

**Trajectory.** With the trust chain closed, the next slice can
either:
  (a) lift `pgpb_to_snapshot` into Lean — port the C catalog-fold
      onto `Pg.Query.ParseResult` so the catalog projection becomes
      kernel-checked. (Phase 4 in the design doc.)
  (b) generate per-stmt typed surfaces by passing smaller --stub
      sets — e.g. `--stub Node=ByteArray` becomes
      `--stub Node=ByteArray --no-stub ColumnDef --no-stub Constraint`
      for column-aware table parsing.

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
