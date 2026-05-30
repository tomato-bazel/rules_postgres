/-
Pg.TyExtTest — #guard tests for the Phase-3b PgType
                       widening (oid, userDefined, array).

Pins the rendering of the three new constructors so that future
refactors can't silently break their SQL surface. Each #guard
asserts `(value).toSql = "expected-string"`.
-/

import Pg.Ty

namespace Pg.TyExtTest

open Pg.Ty

#guard PgType.oid.toSql == "OID"
#guard (PgType.userDefined "queries.cursor").toSql == "queries.cursor"
#guard (PgType.userDefined "auth.key_type").toSql == "auth.key_type"
#guard (PgType.array .bigint).toSql == "BIGINT[]"
#guard (PgType.array .text).toSql == "TEXT[]"
#guard (PgType.array (.userDefined "queries.query_predicate")).toSql
        == "queries.query_predicate[]"
#guard (PgType.array (.array .bigint)).toSql == "BIGINT[][]"

end Pg.TyExtTest
