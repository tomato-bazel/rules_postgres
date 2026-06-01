/-
Pg.Catalog.Tables — pg_catalog 5-table kernel.

Models the five system-catalog tables that anchor ~90% of catalog
reasoning:

  pg_namespace  — schemas
  pg_class      — relations (tables, indexes, views, sequences, ...)
  pg_type       — types
  pg_proc       — functions / procedures
  pg_attribute  — columns (keyed by attrelid + attnum, no oid)

Coverage is the minimum field set needed for catalog-grounded
identifier migration (Catalog.Ref) plus the SECURITY DEFINER /
search_path / relkind discriminators required to make the auth-bug
classes provable. Field additions land here as Postgres surface
coverage grows.

Discriminators (relkind, typtype, provolatile, prokind) are encoded
as Lean inductives rather than `Char`, so case analysis on a relation
exhausts the legal alternatives. The on-disk Postgres encoding (a
single char) is recovered via `*.toChar`.

Moved from Aion's `lean/Aion/Db/Catalog/Tables.lean` as part of
PgAst extraction Phase 1b.
-/

import Pg.Catalog.Oid

namespace Pg.Catalog

/-- `pg_class.relkind` — what kind of relation this row describes.
    The chars are the on-disk Postgres encoding (`pg_class.relkind`
    is a single `char`). -/
inductive RelKind where
  | ordinaryTable    : RelKind  -- 'r' — regular table
  | index            : RelKind  -- 'i'
  | sequence         : RelKind  -- 'S'
  | toastTable       : RelKind  -- 't'
  | view             : RelKind  -- 'v'
  | materializedView : RelKind  -- 'm'
  | compositeType    : RelKind  -- 'c'
  | foreignTable     : RelKind  -- 'f'
  | partitionedTable : RelKind  -- 'p'
  | partitionedIndex : RelKind  -- 'I'
deriving DecidableEq, Repr

/-- Map back to the Postgres on-disk char encoding. -/
def RelKind.toChar : RelKind → Char
  | .ordinaryTable    => 'r'
  | .index            => 'i'
  | .sequence         => 'S'
  | .toastTable       => 't'
  | .view             => 'v'
  | .materializedView => 'm'
  | .compositeType    => 'c'
  | .foreignTable     => 'f'
  | .partitionedTable => 'p'
  | .partitionedIndex => 'I'

/-- `pg_type.typtype` — how the type is constructed. -/
inductive TypType where
  | base       : TypType  -- 'b'
  | composite  : TypType  -- 'c'  — composite types correspond to a pg_class row
  | domain     : TypType  -- 'd'
  | enum       : TypType  -- 'e'
  | pseudo     : TypType  -- 'p'
  | range      : TypType  -- 'r'
  | multirange : TypType  -- 'm'
deriving DecidableEq, Repr

def TypType.toChar : TypType → Char
  | .base       => 'b'
  | .composite  => 'c'
  | .domain     => 'd'
  | .enum       => 'e'
  | .pseudo     => 'p'
  | .range      => 'r'
  | .multirange => 'm'

/-- `pg_proc.provolatile` — function volatility classification. -/
inductive ProVolatile where
  | immutable : ProVolatile  -- 'i'
  | stable    : ProVolatile  -- 's'
  | volatile  : ProVolatile  -- 'v'
deriving DecidableEq, Repr

def ProVolatile.toChar : ProVolatile → Char
  | .immutable => 'i'
  | .stable    => 's'
  | .volatile  => 'v'

/-- `pg_proc.prokind` — distinguishes functions from aggregates,
    window functions, and procedures. -/
inductive ProKind where
  | function  : ProKind  -- 'f'
  | aggregate : ProKind  -- 'a'
  | window    : ProKind  -- 'w'
  | procedure : ProKind  -- 'p'
deriving DecidableEq, Repr

def ProKind.toChar : ProKind → Char
  | .function  => 'f'
  | .aggregate => 'a'
  | .window    => 'w'
  | .procedure => 'p'

/-- A row of `pg_namespace`. -/
structure PgNamespace where
  oid       : Oid .namespace
  nspname   : String
  nspowner  : Oid .role := Oid.invalid .role
deriving Repr

/-- A row of `pg_class`. `relnamespace` references the owning schema;
    `reltype` references this relation's row type (every relation
    has an implicit composite type in `pg_type`). `relowner`
    references `pg_authid.oid` (a role oid, not a relation oid —
    the phantom keeps them distinct). -/
structure PgClass where
  oid           : Oid .relation
  relname       : String
  relnamespace  : Oid .namespace
  relkind       : RelKind
  relowner      : Oid .role := Oid.invalid .role
  reltype       : Oid .type
deriving Repr

/-- A row of `pg_type`. For composite types, `typrelid` points back
    to the pg_class row whose `reltype` equals this type's oid; for
    non-composite types, `typrelid` is `Oid.invalid .relation`.

    `typbasetype` is the underlying type for DOMAIN rows
    (`typtype = .domain`) — the type the domain wraps. For all
    other rows it is `Oid.invalid .type`.

    `typelem` is the element type for ARRAY rows — postgres
    encodes arrays as `typtype = .base` plus
    `typcategory = 'A'` plus a non-invalid `typelem`. For all
    non-array rows it is `Oid.invalid .type`. (`typcategory`
    itself is not yet modelled; downstream code uses
    `typelem != Oid.invalid .type` as the array discriminator
    until `typcategory` lands.)

    Both fields default to `Oid.invalid .type` so existing
    `PgType` literal sites compile unchanged; consumers wanting
    the new precision populate them explicitly. -/
structure PgType where
  oid           : Oid .type
  typname       : String
  typnamespace  : Oid .namespace
  typtype       : TypType
  typrelid      : Oid .relation := Oid.invalid .relation
  typbasetype   : Oid .type     := Oid.invalid .type
  typelem       : Oid .type     := Oid.invalid .type
deriving Repr

/-- A row of `pg_proc`. `prosecdef = true` iff the function was
    declared `SECURITY DEFINER` (runs with the privileges of the
    defining role rather than the invoking role) — the centerpiece
    of one of the auth-bug classes catalog grounding aims to make
    provable. -/
structure PgProc where
  oid           : Oid .proc
  proname       : String
  pronamespace  : Oid .namespace
  prokind       : ProKind
  prosecdef     : Bool
  provolatile   : ProVolatile
  prorettype    : Oid .type
  proargtypes   : List (Oid .type) := []
  proowner      : Oid .role := Oid.invalid .role
deriving Repr

/-- A row of `pg_attribute`. Attributes have no oid of their own;
    they are keyed by `(attrelid, attnum)`. `attnum` is positive
    for user-defined columns and negative for system columns
    (`ctid`, `xmin`, etc.). -/
structure PgAttribute where
  attrelid   : Oid .relation
  attname    : String
  atttypid   : Oid .type
  attnum     : Int
  attnotnull : Bool
deriving Repr

/-- A row of `pg_authid`. Login roles, group roles, and the
    predefined system roles (`pg_read_all_data`, etc.) all live
    here. The `rolsuper` flag is the headline bit for security
    reasoning — combined with `prosecdef` on `pg_proc`, this is
    where the "who actually ran this function with what privileges"
    answer lives. -/
structure PgAuthid where
  oid            : Oid .role
  rolname        : String
  rolsuper       : Bool
  rolinherit     : Bool := true
  rolcreaterole  : Bool := false
  rolcreatedb    : Bool := false
  rolcanlogin    : Bool := false
  rolreplication : Bool := false
  rolbypassrls   : Bool := false
deriving Repr

end Pg.Catalog
