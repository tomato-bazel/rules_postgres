/-
Pg.Query.Top — typed top-level DDL dispatch.

A hand-written wrapper layer that bridges the C decoder
(`tools/pgpb_to_lean_ast` with `--typed`) and the Lean catalog
fold (`Pg.Catalog.Fold`).

Why a separate file from `Pg.Query.Generated`:
  * Generated.lean is auto-regenerated from pg_query.proto on every
    libpg_query bump; this module lives alongside but isn't
    regenerated. It encodes the small, hand-curated set of stmt
    shapes the catalog fold cares about.
  * Each `Top*Stmt` struct contains FIELDS PRE-DECODED FROM PROTOBUF
    bytes — e.g. `qualName : QualifiedName` (already split into
    schema + name) rather than `typeName : List ByteArray` (raw proto
    String message bytes). Pre-decoding lives in the C tool, keeping
    Lean kernel-side simple.

What the Lean catalog fold needs to see for each DDL kind:

    CREATE SCHEMA foo               → schemaname only
    CREATE DOMAIN s.x AS t          → qualified name + type ref
    CREATE TYPE s.x AS (cols...)    → qualified name + column defs
    CREATE TYPE s.x AS ENUM (...)   → qualified name + label strings
    CREATE TABLE s.x (cols...)      → qualified name + column defs
    CREATE FUNCTION s.f(args)...    → qualified name + params + return
    CREATE VIEW s.v AS SELECT ...   → qualified name + SELECT shape
    ALTER TABLE s.x ADD COLUMN ...  → relation + cmd list

This module covers CreateSchemaStmt + CreateEnumStmt as Phase 0.
Additional variants land in follow-up commits as the C decoder
grows pre-decode support for them.
-/

namespace Pg.Query.Top

/-- A qualified `[schema.]name` from a 1-3 part proto qualified-name
    list. The C decoder pre-decodes the proto `String` payloads
    into Lean strings. -/
structure QualifiedName where
  /-- `none` means "no explicit schema" — folder defaults to "public". -/
  schema : Option String := none
  name   : String
deriving Repr, Inhabited

/-- A reference to a type by name + an optional pre-resolved OID hint.

    For `pg_catalog` builtins (`text`, `int8`, `bigint`, …), the C
    decoder fills `oidHint` from its `BUILTIN_TYPES` table. For
    user-defined types, `oidHint = 0` and the Lean fold resolves
    the name against `snap.types` at fold time. This keeps the
    decoder cheap (no snapshot-walking in C) while preserving
    accurate cross-references for user types defined earlier in
    the same .sql input. -/
structure TypeRef where
  schema  : Option String := none
  name    : String
  /-- 0 means "not resolved by the C decoder"; Lean searches by name. -/
  oidHint : Nat := 0
deriving Repr, Inhabited

/-- `CREATE SCHEMA <schemaname> [IF NOT EXISTS]`. -/
structure TopCreateSchemaStmt where
  schemaname  : String
  ifNotExists : Bool := false
deriving Repr, Inhabited

/-- `CREATE TYPE <qualName> AS ENUM (<labels>)`. -/
structure TopCreateEnumStmt where
  qualName : QualifiedName
  labels   : List String := []
deriving Repr, Inhabited

/-- `CREATE DOMAIN <qualName> AS <baseType> [CHECK ...]`.

    Constraints (CHECK / NOT NULL / DEFAULT) are not modeled at
    snapshot level — `pgpb_to_snapshot.c` ignores them too. Only
    the typbasetype is load-bearing for codegen. -/
structure TopCreateDomainStmt where
  qualName : QualifiedName
  baseType : TypeRef
deriving Repr, Inhabited

/-- A single column definition (used inside `CREATE TABLE` and
    `CREATE TYPE ... AS (..)`). -/
structure ColumnDefSpec where
  name    : String
  typeRef : TypeRef
  notNull : Bool := false
deriving Repr, Inhabited

/-- `CREATE TYPE <qualName> AS (<columns>)` — composite type. -/
structure TopCompositeTypeStmt where
  qualName : QualifiedName
  columns  : List ColumnDefSpec := []
deriving Repr, Inhabited

/-- `CREATE TABLE <qualName> (<columns>)`. -/
structure TopCreateStmt where
  qualName : QualifiedName
  columns  : List ColumnDefSpec := []
deriving Repr, Inhabited

/-- The top-level DDL discriminator the catalog fold dispatches on.

    Variants intentionally enumerate only what the fold handles;
    everything else — function bodies, expressions, indices,
    grants — collapses into `.other ByteArray` and the fold leaves
    the snapshot unchanged for those stmts. -/
inductive TopStmt where
  | createSchemaStmt   : TopCreateSchemaStmt   → TopStmt
  | createEnumStmt     : TopCreateEnumStmt     → TopStmt
  | createDomainStmt   : TopCreateDomainStmt   → TopStmt
  | compositeTypeStmt  : TopCompositeTypeStmt  → TopStmt
  | createStmt         : TopCreateStmt         → TopStmt
  | other              : ByteArray             → TopStmt
deriving Inhabited  -- ByteArray has no Repr; skip the derive

/-- The C decoder's `--typed` output shape — a `ParseResult` where
    each `RawStmt`'s payload is the typed `TopStmt` sum rather than
    raw `ByteArray`. Mirrors `Pg.Query.RawStmt` / `Pg.Query.ParseResult`
    one-for-one (modulo the payload type). -/
structure TopRawStmt where
  stmt         : TopStmt
  stmtLocation : Int32 := 0
  stmtLen      : Int32 := 0
deriving Inhabited

structure TopParseResult where
  version : Int32 := 0
  stmts   : List TopRawStmt := []
deriving Inhabited

end Pg.Query.Top
