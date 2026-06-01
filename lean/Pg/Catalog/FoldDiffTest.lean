/-
Pg.Catalog.FoldDiffTest — Phase 6: byte-equivalence gate.

Runs the SAME `.pgpb` (the smoke fixture's protobuf parse tree)
through two folders side by side, in one Lean elaboration:

  smoke_fixture.pgpb
    │
    ├──► pgpb_to_snapshot.c (the canonical C tool)
    │         └─► SmokeFixtureC.snapshot      (def in SmokeFixtureC.lean)
    │
    └──► pgpb_to_lean_ast --typed
              │
              └─► SmokeFixtureTyped.parseResult
                       └─► Snapshot.ofTopParseResult   (Lean fold)
                                └─► leanFolded

Both folders allocate OIDs starting at 16384 with identical
sequencing on identical inputs, so the user-allocated rows MUST
match field-by-field. The asserts below pin every load-bearing
field on every kind of catalog row.

What the asserts deliberately DON'T check (yet):

  * Builtin pg_catalog type rows — the C tool emits an
    "as-referenced" set (`int8`, `text`, `record`, …); the Lean
    fold doesn't. Adding a builtins-augmentation pass to the fold
    lifts the diff to FULL byte equivalence, at which point
    `pgpb_to_snapshot.c` retires. That's tracked as a follow-up.

  * Enum labels — the smoke fixture has no enum types, so this
    isn't load-bearing for the gate today.

  * Proc volatility / security — the C tool hard-codes
    `provolatile = .stable` and `prosecdef = false`; the Lean fold
    does the same. They match for the fixture, but a real codegen
    consumer probably wants these inferred from the function's
    options list (Phase 7 work).
-/
import Pg.Catalog.Fold
import SmokeFixtureTyped
import SmokeFixtureC

namespace Pg.Catalog.FoldDiffTest

open Pg.Catalog

/-- The kernel-checked snapshot produced by the Lean fold. -/
def leanFolded : Snapshot :=
  Snapshot.ofTopParseResult SmokeFixtureTyped.parseResult

/-- The C tool's snapshot — what `pgpb_to_snapshot` writes today. -/
def cFolded : Snapshot := SmokeFixtureC.snapshot

/-! ### Namespaces

Both folders seed `pg_catalog` (oid 11) + `public` (oid 2200) and
add user namespaces in stmt order. Full equality. -/

/-- Project a namespace to a (oid, name) tuple — both fields have
    decidable equality so the list comparison reduces under
    `native_decide`. -/
def nsKey (n : PgNamespace) : Nat × String := (n.oid.raw, n.nspname)

example :
    leanFolded.namespaces.map nsKey = cFolded.namespaces.map nsKey := by
  native_decide

/-! ### User types (OID ≥ 16384)

The fold doesn't emit referenced builtin rows (yet), so we filter
the C tool's output to the user-allocated range and compare. -/

/-- (oid, name, namespace_oid, typtype, typbasetype, typrelid). -/
def typKey (t : PgType) : Nat × String × Nat × TypType × Nat × Nat :=
  (t.oid.raw, t.typname, t.typnamespace.raw, t.typtype,
   t.typbasetype.raw, t.typrelid.raw)

def userTypes (s : Snapshot) : List (Nat × String × Nat × TypType × Nat × Nat) :=
  (s.types.filter (fun t => t.oid.raw >= 16384)).map typKey

example : userTypes leanFolded = userTypes cFolded := by native_decide

/-! ### Relations

All emitted relations are user-allocated (the C tool doesn't emit
`pg_class` builtin rows either). Full equality on (oid, name,
namespace, kind, type). -/

def relKey (r : PgClass) : Nat × String × Nat × RelKind × Nat :=
  (r.oid.raw, r.relname, r.relnamespace.raw, r.relkind, r.reltype.raw)

example :
    leanFolded.relations.map relKey = cFolded.relations.map relKey := by
  native_decide

/-! ### Attributes

Same shape on both sides. Both tools filter tombstoned (dropped)
attributes before emit, so the orderings match. -/

def attrKey (a : PgAttribute) : Nat × String × Nat × Int × Bool :=
  (a.attrelid.raw, a.attname, a.atttypid.raw, a.attnum, a.attnotnull)

example :
    leanFolded.attributes.map attrKey = cFolded.attributes.map attrKey := by
  native_decide

/-! ### Procs

The smoke fixture has one function (`distance`); both folders
emit the same `PgProc` row. Includes argtypes + argnames + setof
flag for tight coverage. -/

def procKey (p : PgProc)
    : Nat × String × Nat × Nat × List Nat × List String × Bool :=
  (p.oid.raw, p.proname, p.pronamespace.raw, p.prorettype.raw,
   p.proargtypes.map (·.raw), p.proargnames, p.proretset)

/-- Use `BEq`/`==` here because `DecidableEq` doesn't auto-synth on
    a tuple containing `List Nat` + `List String` in this position
    (the `BEq` instances chain cleanly via the product). -/
example :
    (leanFolded.procs.map procKey == cFolded.procs.map procKey) = true := by
  native_decide

end Pg.Catalog.FoldDiffTest
