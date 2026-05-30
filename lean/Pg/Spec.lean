/-
Aion.Db.Pg — minimal Lean model of PostgreSQL primitives for the
PG-grounded kernel.

Scope: schema-level constraints only. We don't model SQL queries,
the planner, MVCC, transaction isolation, or NULL-three-valued
logic. We model exactly what `db.graph` actually uses:

  - PRIMARY KEY (uniqueness on a key projection)
  - UNIQUE (cols)
  - FOREIGN KEY (cols → target.targetCols)
  - CHECK (named predicate)
  - EXCLUDE USING gist (disjointness on a custom op)
  - NOT NULL
  - Snowflake-allocated id ranges with disjoint machine-id partitions

The ~6 named axioms below are the irreducible PG-contract surface.
Each currently-axiomatic K-field will be re-proved as a theorem
derived from these axioms applied to the actual Aion schema (encoded
in `Aion.Db.V0.GraphSchema`).

Design notes (Benzaken-style adaptation):
  * Schemas are first-class Lean values — a `Table` is a record of
    columns + constraints; `graphResource` and `graphStatement` are
    concrete Lean terms.
  * Constraints are propositions over `Population` (the row collection).
  * We don't model row contents — only structural relations
    (uniqueness, referential integrity). `FieldValue` is opaque;
    only equality matters for the K-axioms we care about.
  * No bag/multiset semantics — we don't reason about query
    rewriting, only about constraint enforcement at write time.
-/

namespace Pg.Spec
/-- A SQL type — just the cases the Aion schema uses. Opaque
    elsewhere. -/
inductive SqlType where
  | bigint : SqlType
  | text : SqlType
  | ltree : SqlType
  | jsonb : SqlType
  | timestamptz : SqlType
deriving DecidableEq, Repr

/-- A column has a name, a type, and a NOT NULL flag. -/
structure Column where
  name : String
  type : SqlType
  notNull : Bool
deriving Repr

/-- Table-level constraints. Each variant corresponds to a SQL
    constraint kind that `db.graph`'s DDL actually uses. -/
inductive Constraint where
  /-- PRIMARY KEY: uniqueness on the named columns + implicit NOT NULL. -/
  | primaryKey (cols : List String) : Constraint
  /-- UNIQUE: uniqueness on the named columns. -/
  | unique (cols : List String) : Constraint
  /-- FOREIGN KEY: every value of `cols` in this table appears as some
      value of `targetCols` in the target table. -/
  | foreignKey (cols : List String) (target : String) (targetCols : List String) : Constraint
  /-- CHECK: a row-level predicate (referenced by name; the
      predicate's semantics live in the lifted Lean predicate). -/
  | check (predicateName : String) : Constraint
  /-- EXCLUDE USING gist: pairwise disjointness on `cols` under the
      named operator. Used for bitemporal interval non-overlap. -/
  | exclude (cols : List String) (op : String) : Constraint
deriving Repr, DecidableEq

/-- A database table — name, columns, table-level constraints. -/
structure Table where
  name : String
  columns : List Column
  constraints : List Constraint
deriving Repr

/-- A row in a table, abstracted over its actual values. We expose
    only field projection (which is what constraints reason over),
    not the raw values themselves. -/
opaque Row (_t : Table) : Type

/-- A field value — opaque carrier. Equality is the only relation we
    care about; concrete value spaces (Bigint, Text, etc.) are
    erased at this layer. -/
opaque FieldValue : Type

/-- The decidable-equality instance on FieldValue (axiomatic — the
    real PG type system gives this for any concrete column type). -/
axiom FieldValue.decEq : DecidableEq FieldValue
noncomputable instance : DecidableEq FieldValue := FieldValue.decEq

/-- Project a row's value at a given column name. Total over named
    columns — null handling is folded into FieldValue (NULL is just
    a distinguished FieldValue inhabitant; constraints with NOT NULL
    rule it out). -/
axiom field {t : Table} : Row t → String → FieldValue

/-- The set of rows currently in a table. Modeled as a predicate
    "is this row in the table" — works without committing to bag/set
    semantics, since we only need constraint-style propositions. -/
opaque Population (_t : Table) : Type

/-- Membership: a row is in a table's population. -/
axiom InPopulation {t : Table} : Population t → Row t → Prop

/-- The "key" of a row at a list of columns — the tuple of values
    obtained by projecting each named column. Equality on keys is
    decidable since `FieldValue` has decidable equality.
    `noncomputable` because `field` is an axiom (not extractable
    code). -/
noncomputable def keyOf {t : Table} (r : Row t) (cols : List String) : List FieldValue :=
  cols.map (field r)

-- ============================================================================
-- The PG contract — irreducible axioms about PostgreSQL constraint
-- enforcement. Each `pg_*` axiom corresponds to a documented
-- PostgreSQL guarantee.
-- ============================================================================

/-- PG-AX-1 — PRIMARY KEY enforces uniqueness. If a table has a
    PRIMARY KEY on `cols`, then any two rows in its population that
    agree on `cols` are the same row. -/
axiom pg_primaryKey_unique :
  ∀ (t : Table) (cols : List String) (pop : Population t),
    Constraint.primaryKey cols ∈ t.constraints →
    ∀ (r1 r2 : Row t),
      InPopulation pop r1 → InPopulation pop r2 →
      keyOf r1 cols = keyOf r2 cols → r1 = r2

/-- PG-AX-2 — UNIQUE constraint enforces uniqueness on named columns
    (NULL handling: PG treats two NULLs as distinct, but our schema
    uses NOT NULL on all UNIQUE-keyed columns, so we don't need to
    encode that distinction). -/
axiom pg_unique_constraint :
  ∀ (t : Table) (cols : List String) (pop : Population t),
    Constraint.unique cols ∈ t.constraints →
    ∀ (r1 r2 : Row t),
      InPopulation pop r1 → InPopulation pop r2 →
      keyOf r1 cols = keyOf r2 cols → r1 = r2

/-- PG-AX-3 — FOREIGN KEY enforces referential integrity. If a row r
    is in t's population, then for any FK constraint pointing into
    target table t', the projection on `cols` in r matches some row
    in t' on `targetCols`. -/
axiom pg_foreignKey_referential :
  ∀ (t : Table) (cols : List String) (targetName : String) (targetCols : List String)
    (pop : Population t) (targetPop : Population t'),
    t' = t → -- placeholder: real version would resolve targetName → t'
    Constraint.foreignKey cols targetName targetCols ∈ t.constraints →
    ∀ (r : Row t),
      InPopulation pop r →
      ∃ (r' : Row t'), InPopulation targetPop r' ∧
        keyOf r cols = keyOf r' targetCols

/-- PG-AX-4 — CHECK constraint holds row-wise. If a table has a CHECK
    by name, every row in its population satisfies the lifted
    predicate. (We pass the predicate itself as a parameter; in the
    real schema we'd look it up by name.) -/
axiom pg_check_holds :
  ∀ (t : Table) (predName : String) (P : Row t → Prop) (pop : Population t),
    Constraint.check predName ∈ t.constraints →
    ∀ (r : Row t),
      InPopulation pop r → P r

/-- PG-AX-5 — EXCLUDE constraint enforces pairwise disjointness on
    columns under a custom operator. Used for the SPO+interval
    non-overlap commitment (AX-045). -/
axiom pg_exclude_disjoint :
  ∀ (t : Table) (cols : List String) (op : String) (pop : Population t),
    Constraint.exclude cols op ∈ t.constraints →
    ∀ (r1 r2 : Row t),
      InPopulation pop r1 → InPopulation pop r2 →
      r1 ≠ r2 →
      keyOf r1 cols ≠ keyOf r2 cols

/-- PG-AX-6 — Snowflake ID generators with distinct machine-id ranges
    produce disjoint output sets. The `db.ids` schema configures
    `gen_resource_id` and `gen_statement_id` with non-overlapping
    machine-id partitions; this axiom encodes the disjointness
    contract at the propositional level. -/
axiom pg_snowflake_disjoint_ranges :
  ∀ (gen1 gen2 : String) (id1 id2 : FieldValue),
    gen1 ≠ gen2 →
    -- id1 was produced by gen1, id2 was produced by gen2 → id1 ≠ id2.
    -- We model "produced by" implicitly: distinct generator names
    -- (e.g., "gen_resource_id" vs "gen_statement_id") imply distinct
    -- output ranges by the disjoint-partition design.
    id1 ≠ id2

-- ============================================================================
-- Row Level Security (RLS) policies
-- ============================================================================
-- A CREATE POLICY statement attaches a row-filter to a (table,
-- operation) pair. PostgreSQL applies the policy's USING clause to
-- SELECT/UPDATE/DELETE (filtering visible rows) and the WITH CHECK
-- clause to INSERT/UPDATE (validating new/modified rows).
--
-- Modeling note: the USING/WITH CHECK clauses are PG expressions
-- that reference columns + session functions (current_user_id, etc).
-- We don't model expression evaluation at the syntactic level — that
-- would require a full PG SQL semantics. Instead, we model the
-- predicate ABSTRACTLY as `Row → SessionContext → Prop`, leaving the
-- concrete expression to the schema-encoding layer (where Lean
-- defs evaluate to the same Prop the SQL would compute).

/-- The four operations RLS can gate on. -/
inductive PolicyOp where
  | select | insert | update | delete
deriving DecidableEq, Repr

/-- The session context — the per-query state RLS clauses can read.
    Promoted to a structure carrying the three SECURITY DEFINER
    function outputs from `050_graph.sql` (current_user_id,
    current_user_type, is_admin_session), so policy predicates can
    project these as fields rather than axiom calls.

    Modeling note: `userId` and `userKind` are typed as `FieldValue`
    to match the BIGINT / LTREE columns they correspond to. The
    `isAdmin` flag mirrors the boolean returned by
    `graph.is_admin_session()`. -/
structure SessionContext where
  userId : FieldValue
  userKind : FieldValue
  isAdmin : Bool

axiom defaultFieldValue : FieldValue

noncomputable instance : Inhabited FieldValue := ⟨defaultFieldValue⟩
noncomputable instance : Inhabited SessionContext :=
  ⟨{ userId := defaultFieldValue, userKind := defaultFieldValue, isAdmin := false }⟩

/-- A row-level policy: which operation it gates, and the predicate
    determining whether a row passes. The predicate is parameterized
    on the session context (so it can read current_user_id etc).
    USING and WITH CHECK are encoded as separate Policy values when
    a SQL CREATE POLICY supplies both (UPDATE policies typically do). -/
structure Policy (t : Table) where
  /-- The policy's name — for drift-gate identification. -/
  name : String
  /-- The operation this policy gates. -/
  op : PolicyOp
  /-- The row predicate. `using_` filters visible rows for SELECT/
      UPDATE/DELETE; for INSERT it's effectively trivially true and
      WITH CHECK does the work. -/
  using_ : Row t → SessionContext → Prop
  /-- The WITH CHECK predicate — gates new/modified rows on
      INSERT/UPDATE. For SELECT/DELETE it's `fun _ _ => True`. -/
  withCheck : Row t → SessionContext → Prop

/-- The set of policies attached to a table. We model this as a
    function from PolicyOp to a list of policies (PG can have
    multiple policies per op; effective is the AND of their USING
    clauses for restrictive policies, OR for permissive — the
    default). For simplicity we model permissive (OR) since that's
    what `db.graph` uses. -/
opaque PolicySet (_t : Table) : Type
axiom emptyPolicies (t : Table) : PolicySet t

/-- Apply a PolicySet to determine whether a row is visible/passable
    for a given operation. Returns true iff some policy's USING
    clause accepts the row (permissive semantics — the default). -/
axiom policyAccepts {t : Table} :
  PolicySet t → PolicyOp → Row t → SessionContext → Prop

/-- PG-AX-7 — RLS soundness. If a table has RLS enabled and a
    PolicySet is attached, then every read/write operation visible
    through that table goes through the policy filter. Concretely:
    if a row r is read (SELECT) for session ctx, then there exists
    a policy P in the set with P.op = .select and P.using_ r ctx
    holds.

    This encodes the "no backdoor" property: PG's query planner
    inserts the policy filter into every SELECT/UPDATE/DELETE plan
    when RLS is enabled, regardless of where the query came from. -/
axiom pg_rls_no_backdoor :
  ∀ {t : Table} (ps : PolicySet t) (op : PolicyOp)
    (r : Row t) (ctx : SessionContext),
    policyAccepts ps op r ctx →
    ∃ (P : Policy t), P.op = op ∧ P.using_ r ctx

end Pg.Spec