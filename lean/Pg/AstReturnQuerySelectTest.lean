/-
Pg.AstReturnQuerySelectTest — smoke tests for the
`BodyStmt.returnQuerySelect` constructor added in PgEmit
AST extension slice 1 (Blocker 1).

The constructor models the production PL/pgSQL pattern:

  RETURN QUERY SELECT <e₁>, <e₂>, …;

used in auth.jwt_validate_claims, auth.jwt_validate_audience,
auth.jwt_map_claims_to_context, and other functions whose
return type is `RETURNS TABLE (...)` or `RETURNS SETOF ...`.

This slice adds:
  - The AST constructor (PgAst.lean)
  - The pretty-printer rule (PgPretty.lean)
  - The procedural-surface lock (PgProceduralSurface.lean)
  - The trigger-semantics fallthrough (PgTriggerSemantics.lean
    marks the constructor as `.undefined` — RETURN QUERY is
    not a trigger-body construct)

Subsequent Blocker-1 slices will add:
  - DECLARE blocks with variable scopes
  - FOR record IN <query> LOOP / END LOOP
  - CASE WHEN ... END CASE
  - BEGIN ... EXCEPTION WHEN OTHERS THEN ... END
  - PERFORM, RAISE NOTICE, SELECT INTO, EXECUTE format(...)
  - INSERT/UPDATE/DELETE statements within function bodies
  - The libpg_query gate over functions using the new constructors

Once all the procedural constructors land, the auth.* PL/pgSQL
emit chain extends to cover jwt_validate_claims +
jwt_validate_audience + jwt_map_claims_to_context +
jwt_determine_role + set_session_id + create_resource +
create_statement etc. The 16 currently-Tier-A-candidate defects
promote to hard CI gates as the corresponding functions ship
into the diff gate.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.Pretty
import Pg.ProceduralSurface

namespace Pg.AstReturnQuerySelectTest

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.Pretty
open Pg.ProceduralSurface

/-! ## Printer rendering

    The production shape is `RETURN QUERY SELECT <comma-separated
    expressions>;` indented with 4 spaces, terminated by `;` + `\n`. -/

/-- Two-column RETURN QUERY SELECT, the
    `jwt_validate_claims` happy-path shape:
        `RETURN QUERY SELECT TRUE, NULL;` -/
example :
    printBodyStmt
      (.returnQuerySelect [.litConst (.bool true), .litConst .null])
    = "    RETURN QUERY SELECT TRUE, NULL;\n" := by native_decide

/-- Single-column RETURN QUERY SELECT (`SETOF TEXT` shape). -/
example :
    printBodyStmt (.returnQuerySelect [.litConst (.text "studio_user")])
    = "    RETURN QUERY SELECT 'studio_user';\n" := by native_decide

/-- Empty SELECT list — degenerate but the printer handles it
    cleanly (PG would reject this but the AST representation is
    structural). -/
example :
    printBodyStmt (.returnQuerySelect [])
    = "    RETURN QUERY SELECT ;\n" := by native_decide

/-! ## Surface lock

    The new constructor must be visible in `bodyStmtShape` +
    `BodyStmt.exhaustive_known`. If a future change drops the
    `returnQuerySelect` case from either, the build breaks. -/

example :
    bodyStmtShape (.returnQuerySelect [.litConst (.bool true)])
    = .returnQuerySelectShape := rfl

end Pg.AstReturnQuerySelectTest
