/-
Pg.Typing — typing judgement `HasTy` for `PgAst.Expr`.

Tightening B of the libpg_query integration plan. With `PgType`
in place (Tightening B's first half), this module adds the
typing-rules half: a propositional relation
  HasTy cat Γ e τ
saying "under callee-signature catalog cat and variable-binding
context Γ, expression `e` has postgres type `τ`".

The pieces:
  * `Sig`        — a callee's `(params, ret)` signature.
  * `SigCatalog` — String → Option Sig; the set of known callees.
  * `TyCtx`      — String → Option PgType; the variable bindings
                    in scope (function parameters, columns of a
                    record, etc.).
  * `HasTy / HasTyArgs` — the typing rules themselves.

What `HasTy` rules out at the AST level:
  - Calling an unknown function: the catalog returns `none`.
  - Calling a function with the wrong arity / arg types:
    `HasTyArgs` requires the arg list to match the param-types
    list element-wise.
  - Comparing values of different types via `eq` / `ge`.
  - Boolean-combining non-boolean operands.
  - Referencing a variable not in scope.

What `HasTy` does NOT (yet) check, by design — left for later
tightenings:
  - `litConst .null` (no rule) — would need a polymorphic /
    dependent rule. We don't currently emit `null`, so the gap
    is honest, not a leak.
  - Cross-statement consistency (FK target columns exist) —
    Tightening D.
  - Semantic equivalence with the kernel boolean expression —
    Tightening C.
-/

import Pg.Ty
import Pg.Ast
import Pg.Stmt
import Pg.AstSmart

namespace Pg.Typing

open Pg.Ty Polyglot.Sql.Ast Pg.Ast Pg.Stmt

/-- A callee's signature: param types in declaration order, plus
    return type. -/
structure Sig where
  params : List PgType
  ret    : PgType
deriving DecidableEq, Repr

/-- A catalog of known function signatures, keyed by qualified
    function name (e.g. `graph.is_admin_session`). Return `none`
    for unknown names — calling an unknown function is a typing
    failure. -/
abbrev SigCatalog : Type := String → Option Sig

/-- A variable-binding context — variable name → its type, or
    `none` if unbound. Built from a function's params, a record's
    columns, etc. -/
abbrev TyCtx : Type := String → Option PgType

/-- Merge two type contexts, with `inner` winning on conflict.

    Used by `HasTy.existsIn` to type a subquery's `WHERE` cond:
    column references from the FROM table (the inner ctx) shadow
    same-named outer-scope variables.

    Example: in `EXISTS (SELECT 1 FROM graph.resource WHERE
    kind = p_kind)`, `kind` resolves to the table column (LTREE),
    `p_kind` falls through to the outer function-parameter context. -/
def mergeCtx (inner outer : TyCtx) : TyCtx := fun name =>
  match inner name with
  | some τ => some τ
  | none   => outer name

mutual

/-- The typing judgement: under signature catalog `cat` and
    variable context `Γ`, expression `e` has type `τ`.

    Each constructor is one syntactic form's typing rule. Closed —
    a derivation cannot be built for an ill-typed expression.

    Soundness target (Tightening C): for any well-typed `e`,
    evaluating the emitted SQL in any matching env produces a
    value of type `τ`. -/
inductive HasTy (cat : SigCatalog) : TyCtx → Expr → PgType → Prop
  | var       (Γ : TyCtx) (name : String) (τ : PgType)
              (h : Γ name = some τ) :
                HasTy cat Γ (.var name) τ
  | litInt    (Γ : TyCtx) (n : Int) :
                HasTy cat Γ (.litConst (.int n)) .bigint
  | litText   (Γ : TyCtx) (s : String) :
                HasTy cat Γ (.litConst (.text s)) .text
  | litBool   (Γ : TyCtx) (b : Bool) :
                HasTy cat Γ (.litConst (.bool b)) .boolean
  | litInf    (Γ : TyCtx) :
                HasTy cat Γ (.ext .infinity) .timestamptz
  | eq        (Γ : TyCtx) (τ : PgType) (l r : Expr)
              (hl : HasTy cat Γ l τ) (hr : HasTy cat Γ r τ) :
                HasTy cat Γ (.eq l r) .boolean
  | ge        (Γ : TyCtx) (τ : PgType) (l r : Expr)
              (hl : HasTy cat Γ l τ) (hr : HasTy cat Γ r τ) :
                HasTy cat Γ (.ge l r) .boolean
  | or_       (Γ : TyCtx) (l r : Expr)
              (hl : HasTy cat Γ l .boolean) (hr : HasTy cat Γ r .boolean) :
                HasTy cat Γ (.or_ l r) .boolean
  | and_      (Γ : TyCtx) (l r : Expr)
              (hl : HasTy cat Γ l .boolean) (hr : HasTy cat Γ r .boolean) :
                HasTy cat Γ (.and_ l r) .boolean
  | not_      (Γ : TyCtx) (e : Expr) (h : HasTy cat Γ e .boolean) :
                HasTy cat Γ (.not_ e) .boolean
  | call      (Γ : TyCtx) (name : String) (args : List Expr) (sig : Sig)
              (hSig : cat name = some sig)
              (hArgs : HasTyArgs cat Γ args sig.params) :
                HasTy cat Γ (.call name args) sig.ret
  -- pg_catalog builtin call. A1 slice 1c: same typing shape as
  -- `call`, distinct AST constructor for documentation/lint.
  | callBuiltin (Γ : TyCtx) (name : String) (args : List Expr) (sig : Sig)
              (hSig : cat name = some sig)
              (hArgs : HasTyArgs cat Γ args sig.params) :
                HasTy cat Γ (.callBuiltin name args) sig.ret
  -- Schema-qualified call: keyed against `cat` by the rendered
  -- qualified name (`Identifier.toSql` produces `"schema.name"`).
  -- Track R A1 slice 1b4: extends the HasTy judgement to the
  -- catalog-grounded `Expr.callQualified` constructor. Same
  -- arity + per-arg type checks; same return-type lookup.
  | callQualified (Γ : TyCtx) (callee : Identifier) (args : List Expr) (sig : Sig)
              (hSig : cat (Identifier.toSql callee) = some sig)
              (hArgs : HasTyArgs cat Γ args sig.params) :
                HasTy cat Γ (.callQualified callee args) sig.ret
  -- `existsIn table cond` is boolean. The cond is type-checked
  -- against `mergeCtx Γinner Γouter` — column references from the
  -- FROM table (`Γinner`) shadow same-named outer-scope vars.
  -- The caller of this rule supplies the inner context that
  -- reflects the table's columns; tying that to a real schema
  -- is Tightening D's territory (cross-statement consistency
  -- against `aionSchema`), kept decoupled here.
  | existsIn  (Γouter Γinner : TyCtx) (table : String) (cond : Expr)
              (hCond : HasTy cat (mergeCtx Γinner Γouter) cond .boolean) :
                HasTy cat Γouter (.existsIn table cond) .boolean

/-- Element-wise typing of an argument list against a parameter-types
    list. The two lists have the same length and pairwise-matching
    types; this captures both arity and per-argument type checks. -/
inductive HasTyArgs (cat : SigCatalog) : TyCtx → List Expr → List PgType → Prop
  | nil  (Γ : TyCtx) : HasTyArgs cat Γ [] []
  | cons (Γ : TyCtx) (a : Expr) (τ : PgType) (as : List Expr) (τs : List PgType)
         (hHead : HasTy cat Γ a τ)
         (hTail : HasTyArgs cat Γ as τs) :
           HasTyArgs cat Γ (a :: as) (τ :: τs)

end

end Pg.Typing
