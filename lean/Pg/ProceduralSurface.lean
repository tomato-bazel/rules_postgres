/-
Pg.ProceduralSurface — discipline lock on the PL/pgSQL
                                 procedural surface we emit.

Tightening E of the libpg_query integration plan, and the last
of the five. After A (typed literals), B (typed signatures + HasTy),
C (semantic correspondence), and D (schema cross-statement
consistency), the only remaining gap is:

  Without a forcing function, someone could quietly add a new
  `BodyStmt` constructor (a `whileLoop`, a `raiseException`,
  an `executeDynSql`) without:
    - updating the pretty-printer (`PgPretty.printBodyStmt`),
    - updating the semantics (`evalIfChain` in `PgEmitSemantics`),
    - updating the faithfulness theorem
      (`compileBoolBody_faithful`),
    - documenting what the new shape means in PL/pgSQL.

This file enforces that discipline at kernel-check time, by
defining a `bodyStmtShape : BodyStmt → BodyStmtShape` function
via a non-default-catchall pattern match over the *currently-
known* constructors. Lean's exhaustivity check makes adding a
new `BodyStmt` constructor without extending `bodyStmtShape`
a build error.

The exhaustivity theorem `BodyStmt.exhaustive_known` provides a
named anchor reviewers can grep for when they see a new
constructor.

The contract for adding a new `BodyStmt` constructor:

  1. Extend `BodyStmtShape` with a new variant.
  2. Extend `bodyStmtShape`'s pattern match with the new arm.
  3. Extend `Aion.Db.PgPretty.printBodyStmt` with a rendering rule.
  4. Extend `Aion.Db.V1.PgTriggerSemantics.runStmt` with the
     PL/pgSQL semantics of the new shape, OR document why the
     `.undefined` (= "spec undefined") branch is the right answer.
  5. If `Aion.Db.V1.PgEmit.compileBoolBody` (or any future emit
     compiler) starts producing the new shape, extend the
     corresponding faithfulness theorem to cover it.

The point is not to forbid extension — it's to make extension
*visible*. Each step above is a deliberate decision; the
exhaustivity break on `bodyStmtShape` makes "I forgot one"
impossible.

What this discipline does NOT cover:
  - Bugs introduced by misclassifying an existing constructor
    (those are caught by the semantic / typing theorems, not
    by exhaustivity).
  - The full PL/pgSQL surface. Constructors that don't yet
    exist as `BodyStmt` arms aren't part of our emit surface —
    adding them invokes the contract above.

Historical note: earlier versions of this file encoded
`BodyStmt.exhaustive_known` (and a sibling `bodyStmtShape_classifies`)
as right-nested disjunctions whose proofs were towers of
`Sum.inr` constructors — one nesting level per `BodyStmt`
constructor. That representation was tautological (every
`BodyStmt` is one of its constructors by definition; the
classifier consistent with the constructor by `rfl`) and
doubled the maintenance burden on every new constructor —
adding e.g. `BodyStmt.selectInto` meant counting parens for
the new disjunct's `.inr^N (.inl ⟨…⟩)` witness, with
off-by-one bugs caught only by the elaborator. The towers
were replaced with the one-liner below; the surface lock
remains via `bodyStmtShape`'s match exhaustivity.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart

namespace Pg.ProceduralSurface

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt

/-- The BodyStmt shapes our emit pipeline currently produces.

    The classification is structural — when a new constructor is
    added to `BodyStmt`, the `bodyStmtShape` pattern match below
    becomes non-exhaustive and Lean refuses to compile it,
    forcing the engineer to extend the discipline (see file-level
    doc). -/
inductive BodyStmtShape where
  | ifThenReturnShape      : BodyStmtShape
  | returnLitShape         : BodyStmtShape
  | assignNewShape         : BodyStmtShape
  | returnRowShape         : BodyStmtShape
  | raiseExceptionShape    : BodyStmtShape
  | ifThenStmtShape        : BodyStmtShape
  | ifElseIfShape          : BodyStmtShape
  | assignLocalShape       : BodyStmtShape
  | updateTableShape       : BodyStmtShape
  | returnExprShape        : BodyStmtShape
  | returnQuerySelectShape : BodyStmtShape   -- Blocker-1 slice 1
  | declareBlockShape      : BodyStmtShape   -- Blocker-1 slice 2
  | performShape           : BodyStmtShape   -- Blocker-1 slice 3
  | raiseNoticeShape       : BodyStmtShape   -- Blocker-1 slice 4
  | beginExceptionShape    : BodyStmtShape   -- Blocker-1 slice 5
  | forRecordInLoopShape   : BodyStmtShape   -- Blocker-1 slice 6
  | selectIntoShape        : BodyStmtShape   -- Blocker-1 slice 7
  | caseStmtShape          : BodyStmtShape   -- Blocker-1 slice 8
  | executeFormatShape     : BodyStmtShape   -- Blocker-1 slice 9
  | insertStmtShape        : BodyStmtShape   -- Blocker-1 slice 10
  | deleteStmtShape        : BodyStmtShape   -- Blocker-1 slice 10
  | updateTableQualifiedShape : BodyStmtShape -- A1 slice 1d (DML qualified)
  | insertStmtQualifiedShape  : BodyStmtShape -- A1 slice 1d
  | deleteStmtQualifiedShape  : BodyStmtShape -- A1 slice 1d
  | exitLoopShape          : BodyStmtShape   -- defect-6 surface
  | returnBareShape        : BodyStmtShape   -- defect-7 surface
  | nullStmtShape          : BodyStmtShape   -- defect-7 surface
  | executeFormatIntoShape : BodyStmtShape   -- defect-7 surface
  | raiseReraiseShape      : BodyStmtShape   -- defect-12 surface
deriving DecidableEq, Repr

/-- Classify a `BodyStmt` by its surface shape. The non-default-
    catchall match is intentional: it's what makes adding a new
    constructor break the build. -/
def bodyStmtShape : BodyStmt → BodyStmtShape
  | .ifThenReturn _ _      => .ifThenReturnShape
  | .returnLit _           => .returnLitShape
  | .assignNew _ _         => .assignNewShape
  | .returnRow _           => .returnRowShape
  | .raiseException _ _ _  => .raiseExceptionShape
  | .ifThenStmt _ _        => .ifThenStmtShape
  | .ifElseIf _ _          => .ifElseIfShape
  | .assignLocal _ _       => .assignLocalShape
  | .updateTable _ _ _     => .updateTableShape
  | .returnExpr _          => .returnExprShape
  | .returnQuerySelect _   => .returnQuerySelectShape
  | .declareBlock _ _      => .declareBlockShape
  | .perform _             => .performShape
  | .raiseNotice _ _       => .raiseNoticeShape
  | .beginException _ _    => .beginExceptionShape
  | .forRecordInLoop _ _ _ => .forRecordInLoopShape
  | .selectInto _ _ _      => .selectIntoShape
  | .caseStmt _ _ _        => .caseStmtShape
  | .executeFormat _ _     => .executeFormatShape
  | .insertStmt _ _ _ _ _  => .insertStmtShape
  | .deleteStmt _ _        => .deleteStmtShape
  | .updateTableQualified _ _ _   => .updateTableQualifiedShape
  | .insertStmtQualified _ _ _ _ _ => .insertStmtQualifiedShape
  | .deleteStmtQualified _ _      => .deleteStmtQualifiedShape
  | .exitLoop              => .exitLoopShape
  | .returnBare            => .returnBareShape
  | .nullStmt              => .nullStmtShape
  | .executeFormatInto _ _ _ => .executeFormatIntoShape
  | .raiseReraise          => .raiseReraiseShape

/-- Every `BodyStmt` is classified by `bodyStmtShape`.

    The Tightening-E discipline is enforced **structurally** by
    `bodyStmtShape` itself: that function is a non-default-
    catchall pattern match over every `BodyStmt` constructor.
    Adding a new constructor without extending `bodyStmtShape`'s
    match makes the kernel refuse to elaborate the `def`,
    forcing the engineer to update the printer
    (`PgPretty.printBodyStmt`), the trigger semantics
    (`PgTriggerSemantics.runStmt`), and any faithfulness
    theorems.

    This theorem is a named anchor for the contract; the
    structural enforcement lives in `bodyStmtShape`'s match. -/
theorem BodyStmt.exhaustive_known (s : BodyStmt) :
    ∃ shape, bodyStmtShape s = shape :=
  ⟨bodyStmtShape s, rfl⟩

end Pg.ProceduralSurface
