/-
Pg.Pretty — pretty-printer for the Polyglot.Sql.Ast Pg.Ast Pg.Stmt types.

Phase 3 of the libpg_query integration. Pure structural walk:
each constructor of `PgAst.Stmt` / `PgAst.BodyStmt` / `PgAst.Expr`
maps to a fixed SQL fragment. No domain logic, no boolean flattening,
no IF-chain compilation — those upstream steps live in
`Aion.Db.V1.PgEmit` so this file stays a faithful AST→string renderer
(the analogue of libpg_query's `pg_query_deparse_protobuf`, but in
Lean and over our restricted node set).

Output stability:
  Every emit is `String`-concatenation only. No HashMaps, no
  ordered-set traversals — given the same AST, the output is
  bit-identical across runs. The `lean_emit` Bazel rule consumes
  this directly via `lean --run`.

Round-trip property (target for Phase 4 / 5):
  For any well-formed `s : PgAst.Stmt`, `pg_query_parse (print s)`
  succeeds — i.e. the printer never produces SQL postgres rejects.
  Phase 2's `sql_parse_valid_test` gates this for our actual emit
  outputs; a generalized statement over arbitrary `Stmt` values
  belongs in PgPretty's own theorem file once Phase 4 is in.
-/

import Pg.Ast
import Pg.Stmt
import Pg.AstSmart
import Pg.RegexAst

namespace Pg.Pretty

open Polyglot.Sql.Ast Pg.Ast Pg.Stmt
open Pg.RegexAst

/-- Render a typed literal as its postgres-canonical surface
    syntax. Single-quote strings escape internal `'` as `''` per
    SQL convention; integers print decimal; booleans render as
    `TRUE` / `FALSE` keywords; `null` and `infinity` are special. -/
def printLitConst : LitConst → String
  | .int n     => toString n
  | .text s    => "'" ++ s.replace "'" "''" ++ "'"
  | .bool true  => "TRUE"
  | .bool false => "FALSE"
  | .null      => "NULL"
  -- `infinity` moved from LitConst to ExprExt as part of Phase 1b
  -- Step 3; rendered by the `.ext .infinity` arm of `printExpr` below.

/-- Render an `Expr` as a SQL fragment. Structurally recursive on
    Expr, so it terminates without `partial`.

    Parenthesization mirrors libpg_query's `deparse_expr` policy:
    every binary expression / NOT is wrapped in `( … )` so the
    emitted text is precedence-explicit and re-parses to the same
    tree without depending on operator-precedence rules. -/
def printExpr : Expr → String
  | .var n        => n
  | .field b n    => printExpr b ++ "." ++ n
  | .litConst c   => printLitConst c
  | .eq l r       => "(" ++ printExpr l ++ " = "   ++ printExpr r ++ ")"
  | .ge l r       => "(" ++ printExpr l ++ " >= "  ++ printExpr r ++ ")"
  | .or_ l r      => "(" ++ printExpr l ++ " OR "  ++ printExpr r ++ ")"
  | .and_ l r     => "(" ++ printExpr l ++ " AND " ++ printExpr r ++ ")"
  | .not_ e       => "NOT (" ++ printExpr e ++ ")"
  | .call n args  =>
      n ++ "(" ++ String.intercalate ", " (args.map printExpr) ++ ")"
  | .ext (.callBuiltin n args) =>
      n ++ "(" ++ String.intercalate ", " (args.map printExpr) ++ ")"
  | .ext (.callQualified callee args) =>
      Identifier.toSql callee ++ "(" ++
        String.intercalate ", " (args.map printExpr) ++ ")"
  | .existsIn table cond =>
      "EXISTS (SELECT 1 FROM " ++ table ++ " WHERE " ++ printExpr cond ++ ")"
  | .ext (.existsInQualified table cond) =>
      "EXISTS (SELECT 1 FROM " ++ Identifier.toSql table ++
        " WHERE " ++ printExpr cond ++ ")"
  | .existsInAliased table alias cond =>
      "EXISTS (SELECT 1 FROM " ++ table ++ " AS " ++ alias ++
        " WHERE " ++ printExpr cond ++ ")"
  | .ext (.existsInAliasedQualified table alias cond) =>
      "EXISTS (SELECT 1 FROM " ++ Identifier.toSql table ++ " AS " ++ alias ++
        " WHERE " ++ printExpr cond ++ ")"
  | .ext (.existsInAliasedBuiltin table alias cond) =>
      "EXISTS (SELECT 1 FROM " ++ table ++ " AS " ++ alias ++
        " WHERE " ++ printExpr cond ++ ")"
  | .ext (.regexMatch subject pattern) =>
      let regexStr := PgRegexAst.toString pattern
      "(" ++ printExpr subject ++ " ~ '" ++
        regexStr.replace "'" "''" ++ "')"
  | .isNull e =>
      "(" ++ printExpr e ++ " IS NULL)"
  | .ext (.typeCastPg e t) =>
      "(" ++ printExpr e ++ "::" ++ t.toSql ++ ")"
  -- Generic String-typed cast (from Polyglot.Sql.Ast). Aion code
  -- uses `.typeCastPg` exclusively (which carries Pg.Ty.PgType);
  -- the generic arm is present only for exhaustivity on the
  -- factored Expr inductive.
  | .typeCast e t =>
      "(" ++ printExpr e ++ "::" ++ t ++ ")"
  | .isDistinctFrom l r =>
      "(" ++ printExpr l ++ " IS DISTINCT FROM " ++ printExpr r ++ ")"
  | .isNotNull e =>
      "(" ++ printExpr e ++ " IS NOT NULL)"
  | .coalesce args =>
      "COALESCE(" ++ String.intercalate ", " (args.map printExpr) ++ ")"
  | .ext (.jsonbHasKey j k) =>
      "(" ++ printExpr j ++ " ? " ++ printExpr k ++ ")"
  | .ext (.jsonbGet j k) =>
      "(" ++ printExpr j ++ " -> " ++ printExpr k ++ ")"
  | .ext (.jsonbGetText j k) =>
      "(" ++ printExpr j ++ " ->> " ++ printExpr k ++ ")"
  | .ext (.jsonbPathGetText j p) =>
      "(" ++ printExpr j ++ " #>> " ++ printExpr p ++ ")"
  | .ext (.jsonbConcat l r) =>
      "(" ++ printExpr l ++ " || " ++ printExpr r ++ ")"
  | .ext .tgOp =>
      "TG_OP"
  | .ext .tgTableName =>
      "TG_TABLE_NAME"
  | .ext .infinity =>
      "'infinity'"
  | .countStar =>
      "COUNT(*)"
  | .ext (.jsonbExtractText obj key) =>
      "(" ++ printExpr obj ++ " ->> '" ++ key.replace "'" "''" ++ "')"
  | .ext (.eqAny x arr) =>
      "(" ++ printExpr x ++ " = ANY(" ++ printExpr arr ++ "))"
  | .minus l r =>
      "(" ++ printExpr l ++ " - " ++ printExpr r ++ ")"
  | .plus l r =>
      "(" ++ printExpr l ++ " + " ++ printExpr r ++ ")"
  | .lt l r =>
      "(" ++ printExpr l ++ " < " ++ printExpr r ++ ")"
  | .gt l r =>
      "(" ++ printExpr l ++ " > " ++ printExpr r ++ ")"
  | .arrayLit elements =>
      "ARRAY[" ++ String.intercalate ", " (elements.map printExpr) ++ "]"
  | .arrayIdx arr idx =>
      "(" ++ printExpr arr ++ ")[" ++ printExpr idx ++ "]"
  | .rowExpr fields =>
      "ROW(" ++ String.intercalate ", " (fields.map printExpr) ++ ")"
  | .aggCallOrdered name args orderBy orderDesc =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let dirStr := if orderDesc then " DESC" else " ASC"
      name ++ "(" ++ argStr ++ " ORDER BY " ++ printExpr orderBy ++ dirStr ++ ")"
  | .aggCallDistinct name arg =>
      name ++ "(DISTINCT " ++ printExpr arg ++ ")"
  | .extract field expr =>
      "EXTRACT(" ++ field ++ " FROM " ++ printExpr expr ++ ")"
  | .aggCallFiltered name args filter =>
      let argStr := String.intercalate ", " (args.map printExpr)
      name ++ "(" ++ argStr ++ ") FILTER (WHERE " ++ printExpr filter ++ ")"
  | .divide l r =>
      "(" ++ printExpr l ++ " / " ++ printExpr r ++ ")"
  | .multiply l r =>
      "(" ++ printExpr l ++ " * " ++ printExpr r ++ ")"
  | .like subject pattern =>
      "(" ++ printExpr subject ++ " LIKE " ++ printExpr pattern ++ ")"
  | .ext (.ilike subject pattern) =>
      "(" ++ printExpr subject ++ " ILIKE " ++ printExpr pattern ++ ")"
  | .between subject lo hi =>
      "(" ++ printExpr subject ++ " BETWEEN " ++ printExpr lo ++ " AND " ++ printExpr hi ++ ")"
  | .ext (.ltreeDescendantOf l r) =>
      "(" ++ printExpr l ++ " <@ " ++ printExpr r ++ ")"
  | .ext (.bitwiseOr l r) =>
      "(" ++ printExpr l ++ " | " ++ printExpr r ++ ")"
  | .selectScalar col tbl alias whereCond orderBy limit =>
      let aliasStr :=
        match alias with
        | none   => ""
        | some a => " AS " ++ a
      let whereStr :=
        match whereCond with
        | none   => ""
        | some w => " WHERE " ++ printExpr w
      let orderStr :=
        match orderBy with
        | none           => ""
        | some (e, desc) =>
            " ORDER BY " ++ printExpr e ++
            (if desc then " DESC" else " ASC")
      let limitStr :=
        match limit with
        | none   => ""
        | some n => " LIMIT " ++ toString n
      "(SELECT " ++ printExpr col ++
      " FROM " ++ tbl ++ aliasStr ++
      whereStr ++ orderStr ++ limitStr ++ ")"
  | .caseWhen conds results elseExpr =>
      let condStrs := conds.map printExpr
      let resultStrs := results.map printExpr
      let armStr := String.intercalate " "
        ((condStrs.zip resultStrs).map (fun (c, r) =>
          "WHEN " ++ c ++ " THEN " ++ r))
      let elseStr :=
        match elseExpr with
        | none   => ""
        | some e => " ELSE " ++ printExpr e
      "(CASE " ++ armStr ++ elseStr ++ " END)"
  | .inList x vals =>
      "(" ++ printExpr x ++ " IN (" ++
      String.intercalate ", " (vals.map printExpr) ++ "))"
  | .concat l r =>
      "(" ++ printExpr l ++ " || " ++ printExpr r ++ ")"
  | .caseSimple subject whenVals thenResults elseExpr =>
      let whenStrs := whenVals.map printExpr
      let thenStrs := thenResults.map printExpr
      let armStr := String.intercalate " "
        ((whenStrs.zip thenStrs).map (fun (v, r) =>
          "WHEN " ++ v ++ " THEN " ++ r))
      let elseStr :=
        match elseExpr with
        | none   => ""
        | some e => " ELSE " ++ printExpr e
      "(CASE " ++ printExpr subject ++ " " ++ armStr ++ elseStr ++ " END)"

/-- Render a single function parameter in the
    `    name pgType [DEFAULT <expr>]` form (4-space indent +
    space + type, with optional `DEFAULT <expr>` suffix when the
    param carries a default value). -/
def printParam (p : FuncParam) : String :=
  let defaultStr :=
    match p.default with
    | none   => ""
    | some e => " DEFAULT " ++ printExpr e
  let variadicPrefix := if p.variadic then "VARIADIC " else ""
  "    " ++ variadicPrefix ++ p.name ++ " " ++ p.pgType.toSql ++ defaultStr

/-- Render the parameter list — comma-separated, one per line. -/
def printParams (ps : List FuncParam) : String :=
  String.intercalate ",\n" (ps.map printParam)

/-- Render a single RAISE EXCEPTION argument list — the
    comma-separated positional substitutions following the
    format string. Empty list renders to "" (no arg suffix). -/
def printRaiseArgs (args : List Expr) : String :=
  match args with
  | []   => ""
  | _    => ", " ++ String.intercalate ", " (args.map printExpr)

/-- Render the optional `USING ERRCODE = '<code>'` clause of a
    `RAISE EXCEPTION`. -/
def printErrcode (errcode : Option String) : String :=
  match errcode with
  | none      => ""
  | some code => "\n        USING ERRCODE = '" ++ code ++ "'"

/-- Render a single local-variable declaration inside a body-level
    `DECLARE` sub-block. Indented 8 spaces (one level deeper than
    the surrounding `DECLARE` keyword), with an optional
    `:= <default>` suffix when `FuncParam.default` is set. -/
def printLocalDecl (p : FuncParam) : String :=
  let defaultStr := match p.default with
    | none   => ""
    | some e => " := " ++ printExpr e
  "        " ++ p.name ++ " " ++ p.pgType.toSql ++ defaultStr ++ ";"

/-- Render a `SelectSource` (FROM-clause shape). Recurses on the
    join tree; `Expr.field` references in the `ON` clause render
    via `printExpr`.

    Moved upstream of the body-statement mutual block in Blocker-1
    slice 6 so that body-level FOR-IN-LOOP / SELECT-INTO printer
    cases can reference it via `printSelectQuery`. -/
def printSelectSource : SelectSource → String
  | .table name none           => name
  | .table name (some a)       => name ++ " AS " ++ a
  | .tableQualified t none      => Identifier.toSql t
  | .tableQualified t (some a) => Identifier.toSql t ++ " AS " ++ a
  | .tableBuiltin n none        => n
  | .tableBuiltin n (some a)    => n ++ " AS " ++ a
  | .tableLocal n none          => n
  | .tableLocal n (some a)      => n ++ " AS " ++ a
  | .join lhs rhs kind on      =>
      printSelectSource lhs ++ " " ++ kind.toSql ++ " " ++
      printSelectSource rhs ++ " ON " ++ printExpr on
  | .functionCall name args alias =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let aliasStr :=
        match alias with
        | none   => ""
        | some a => " AS " ++ a
      name ++ "(" ++ argStr ++ ")" ++ aliasStr
  | .functionCallQualified callee args alias =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let aliasStr :=
        match alias with
        | none   => ""
        | some a => " AS " ++ a
      Identifier.toSql callee ++ "(" ++ argStr ++ ")" ++ aliasStr
  | .functionCallBuiltin name args alias =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let aliasStr :=
        match alias with
        | none   => ""
        | some a => " AS " ++ a
      name ++ "(" ++ argStr ++ ")" ++ aliasStr
  | .empty => ""
  | .functionCallWithOrdinality name args tableAlias columnAliases =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let colAliasStr := String.intercalate ", " columnAliases
      name ++ "(" ++ argStr ++ ") WITH ORDINALITY AS " ++
      tableAlias ++ "(" ++ colAliasStr ++ ")"
  | .functionCallWithOrdinalityQualified callee args tableAlias columnAliases =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let colAliasStr := String.intercalate ", " columnAliases
      Identifier.toSql callee ++ "(" ++ argStr ++ ") WITH ORDINALITY AS " ++
      tableAlias ++ "(" ++ colAliasStr ++ ")"
  | .functionCallWithOrdinalityBuiltin name args tableAlias columnAliases =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let colAliasStr := String.intercalate ", " columnAliases
      name ++ "(" ++ argStr ++ ") WITH ORDINALITY AS " ++
      tableAlias ++ "(" ++ colAliasStr ++ ")"

/-! ## Shared print helpers consumed by the `printCreate*` family.

    Each of the six `printCreate*Function` printers (plus
    `printCreateTable` and `printOneCte`) used to inline the
    same handful of optional-clause renderings — banner header,
    SECURITY DEFINER block, ORDER BY list, optional WHERE / FROM
    / LIMIT / OFFSET / GROUP BY clauses, and the
    conditional-newline params block used by SQL-language
    function declarations. The helpers below extract those
    patterns; the printers consume them so adding a new SELECT
    field doesn't require touching every printer.

    Helpers are byte-identical to the previous inline forms;
    `bazel-bin/lean/*.sql` outputs are unchanged across the
    extraction (verified by hashing all 21 sql_generated
    targets pre- and post-refactor). -/

/-- Render the optional banner comment block emitted before a
    CREATE statement. Empty list → "" (no banner). -/
def printBanner (lines : List String) : String :=
  match lines with
  | []    => ""
  | _     => String.join (lines.map (fun s => s ++ "\n")) ++ "\n"

/-- Render the optional `SECURITY DEFINER` / `SET search_path`
    block. False → "" (default INVOKER). The search_path is
    hardcoded to `graph, public, pg_temp` — the production
    convention for definer-rights functions in Aion. -/
def printSecurityDefiner (secDef : Bool) : String :=
  if secDef then
    "SECURITY DEFINER\nSET search_path = graph, public, pg_temp\n"
  else ""

/-- Render an optional `WHERE <cond>` clause. -/
def printOptWhere (whereCond : Option Expr) : String :=
  match whereCond with
  | none   => ""
  | some w => " WHERE " ++ printExpr w

/-- Render an optional `FROM <source>` clause. `.empty` source
    → "" (no FROM clause); postgres accepts `SELECT <expr>;`
    without FROM. -/
def printOptFrom (source : SelectSource) : String :=
  match source with
  | .empty => ""
  | s      => " FROM " ++ printSelectSource s

/-- Render an optional `ORDER BY` clause from a list of
    (expression, descending?) pairs. Empty list → "". -/
def printOrderBy (orderBy : List (Expr × Bool)) : String :=
  if orderBy.isEmpty then ""
  else
    " ORDER BY " ++ String.intercalate ", "
      (orderBy.map (fun (e, desc) =>
        printExpr e ++ (if desc then " DESC" else " ASC")))

/-- Render an optional `LIMIT <expr>` clause where the bound is
    an arbitrary expression (supports parameter-bound bounds
    like `LIMIT p_limit`). Used by the TABLE-returning and
    recursive-CTE function printers. -/
def printOptLimitExpr (limit : Option Expr) : String :=
  match limit with
  | none   => ""
  | some e => " LIMIT " ++ printExpr e

/-- Render an optional `LIMIT <n>` clause where the bound is a
    Nat literal. Used by `CreateSetReturningFunctionStmt`
    whose `limit` is fixed at function-declaration time. -/
def printOptLimitNat (limit : Option Nat) : String :=
  match limit with
  | none   => ""
  | some n => " LIMIT " ++ toString n

/-- Render an optional `OFFSET <expr>` clause. -/
def printOptOffsetExpr (offset : Option Expr) : String :=
  match offset with
  | none   => ""
  | some e => " OFFSET " ++ printExpr e

/-- Render an optional `GROUP BY` clause from a list of group
    expressions. Empty list → "". -/
def printOptGroupBy (groupBy : List Expr) : String :=
  if groupBy.isEmpty then ""
  else " GROUP BY " ++ String.intercalate ", " (groupBy.map printExpr)

/-- Render the params block of a SQL-language CREATE FUNCTION.
    Empty list → "" (no params, just `()`); non-empty →
    `\n<params>\n` wrapping the existing per-param rendering.
    Different from the PL/pgSQL `CreateFunctionStmt` which
    unconditionally inserts the surrounding newlines (empty
    params there render as `(\n\n)` rather than `()`). -/
def printSqlParams (params : List FuncParam) : String :=
  match params with
  | [] => ""
  | _  => "\n" ++ printParams params ++ "\n"

/-- Render a `SelectQuery` as the inline body of a SELECT — no
    leading whitespace, no trailing `;`. Used by body-level
    constructs that need a SELECT shape (FOR record IN <query>
    LOOP, SELECT INTO targets) without owning a full SQL
    statement frame.

    Layout (single-line when feasible):
      `SELECT <projs> FROM <source> [WHERE …] [ORDER BY …] [LIMIT …]` -/
def printSelectQuery (q : SelectQuery) : String :=
  let projStr := String.intercalate ", " (q.projections.map printExpr)
  "SELECT " ++ projStr ++ printOptFrom q.source ++ printOptWhere q.whereCond ++
    printOrderBy q.orderBy ++ printOptLimitExpr q.limit

/-
Render a single body statement. PL/pgSQL `IF ... THEN ... END IF;` /
`RETURN ...;` / `NEW.col := ...;` / `RETURN NEW|OLD;` /
`RAISE EXCEPTION ...;` shapes, indented 4 spaces (matches our
existing emitter's layout convention).

`printBodyStmt` is mutual with `printBodyStmts` to walk the
nested body of `ifThenStmt`.
-/
mutual

def printBodyStmt : BodyStmt → String
  | .ifThenReturn cond ret =>
      "    IF " ++ printExpr cond ++ " THEN\n" ++
      "        RETURN " ++ printExpr ret ++ ";\n" ++
      "    END IF;\n"
  | .returnLit ret =>
      "    RETURN " ++ printExpr ret ++ ";\n"
  | .assignNew col e =>
      "    NEW." ++ col ++ " := " ++ printExpr e ++ ";\n"
  | .returnRow which =>
      "    RETURN " ++ which.toSql ++ ";\n"
  | .raiseException message args errcode =>
      "    RAISE EXCEPTION '" ++ message.replace "'" "''" ++ "'" ++
      printRaiseArgs args ++ printErrcode errcode ++ ";\n"
  | .ifThenStmt cond body =>
      "    IF " ++ printExpr cond ++ " THEN\n" ++
      printBodyStmts body ++
      "    END IF;\n"
  | .ifElseIf clauses elseBody =>
      printIfElseIfClauses clauses ++
      printIfElseIfElse elseBody ++
      "    END IF;\n"
  | .assignLocal name e =>
      "    " ++ name ++ " := " ++ printExpr e ++ ";\n"
  | .updateTable table sets whereCond =>
      "    UPDATE " ++ table ++ "\n" ++
      "    SET " ++
        String.intercalate ", "
          (sets.map (fun (col, e) => col ++ " = " ++ printExpr e)) ++ "\n" ++
      "    WHERE " ++ printExpr whereCond ++ ";\n"
  | .updateTableQualified table sets whereCond =>
      "    UPDATE " ++ Identifier.toSql table ++ "\n" ++
      "    SET " ++
        String.intercalate ", "
          (sets.map (fun (col, e) => col ++ " = " ++ printExpr e)) ++ "\n" ++
      "    WHERE " ++ printExpr whereCond ++ ";\n"
  | .returnExpr e =>
      "    RETURN " ++ printExpr e ++ ";\n"
  | .returnQuerySelect exprs =>
      "    RETURN QUERY SELECT " ++
        String.intercalate ", " (exprs.map printExpr) ++ ";\n"
  | .declareBlock decls body =>
      "    DECLARE\n" ++
      String.intercalate "\n" (decls.map printLocalDecl) ++
      (match decls with | [] => "" | _ => "\n") ++
      "    BEGIN\n" ++
      printBodyStmts body ++
      "    END;\n"
  | .perform e =>
      "    PERFORM " ++ printExpr e ++ ";\n"
  | .raiseNotice message args =>
      "    RAISE NOTICE '" ++ message.replace "'" "''" ++ "'" ++
      printRaiseArgs args ++ ";\n"
  | .beginException body handlers =>
      "    BEGIN\n" ++
      printBodyStmts body ++
      "    EXCEPTION\n" ++
      printExceptionHandlers handlers ++
      "    END;\n"
  | .forRecordInLoop recordVar query body =>
      "    FOR " ++ recordVar ++ " IN " ++ printSelectQuery query ++ " LOOP\n" ++
      printBodyStmts body ++
      "    END LOOP;\n"
  | .selectInto targets query strict =>
      let projStr := String.intercalate ", " (query.projections.map printExpr)
      let strictStr := if strict then "STRICT " else ""
      let targetStr := String.intercalate ", " targets
      "    SELECT " ++ projStr ++ " INTO " ++ strictStr ++ targetStr ++
      printOptFrom query.source ++ printOptWhere query.whereCond ++
      printOrderBy query.orderBy ++ printOptLimitExpr query.limit ++ ";\n"
  | .caseStmt subject clauses elseBody =>
      let subjectStr := match subject with
        | none   => ""
        | some e => " " ++ printExpr e
      "    CASE" ++ subjectStr ++ "\n" ++
      printCaseClauses clauses ++
      printCaseElse elseBody ++
      "    END CASE;\n"
  | .executeFormat sql usingArgs =>
      let usingStr := match usingArgs with
        | []   => ""
        | args =>
            " USING " ++ String.intercalate ", " (args.map printExpr)
      "    EXECUTE " ++ printExpr sql ++ usingStr ++ ";\n"
  | .insertStmt table columns values onConflict returningInto =>
      let colStr := String.intercalate ", " columns
      let valStr := String.intercalate ", " (values.map printExpr)
      let onConflictStr :=
        match onConflict with
        | none => ""
        | some .doNothing => " ON CONFLICT DO NOTHING"
        | some (.doUpdate u) =>
            let targetStr := String.intercalate ", " u.targetCols
            let setStr := String.intercalate ", "
              (u.sets.map (fun (c, e) => c ++ " = " ++ printExpr e))
            " ON CONFLICT (" ++ targetStr ++ ") DO UPDATE SET " ++
            setStr ++ printOptWhere u.whereCond
      let returningStr :=
        match returningInto with
        | none           => ""
        | some (col, var) => " RETURNING " ++ col ++ " INTO " ++ var
      "    INSERT INTO " ++ table ++ " (" ++ colStr ++ ")" ++
      " VALUES (" ++ valStr ++ ")" ++ onConflictStr ++ returningStr ++ ";\n"
  | .insertStmtQualified table columns values onConflict returningInto =>
      let colStr := String.intercalate ", " columns
      let valStr := String.intercalate ", " (values.map printExpr)
      let onConflictStr :=
        match onConflict with
        | none => ""
        | some .doNothing => " ON CONFLICT DO NOTHING"
        | some (.doUpdate u) =>
            let targetStr := String.intercalate ", " u.targetCols
            let setStr := String.intercalate ", "
              (u.sets.map (fun (c, e) => c ++ " = " ++ printExpr e))
            " ON CONFLICT (" ++ targetStr ++ ") DO UPDATE SET " ++
            setStr ++ printOptWhere u.whereCond
      let returningStr :=
        match returningInto with
        | none           => ""
        | some (col, var) => " RETURNING " ++ col ++ " INTO " ++ var
      "    INSERT INTO " ++ Identifier.toSql table ++ " (" ++ colStr ++ ")" ++
      " VALUES (" ++ valStr ++ ")" ++ onConflictStr ++ returningStr ++ ";\n"
  | .deleteStmt table whereCond =>
      "    DELETE FROM " ++ table ++ printOptWhere whereCond ++ ";\n"
  | .deleteStmtQualified table whereCond =>
      "    DELETE FROM " ++ Identifier.toSql table ++ printOptWhere whereCond ++ ";\n"
  | .exitLoop =>
      "    EXIT;\n"
  | .returnBare =>
      "    RETURN;\n"
  | .nullStmt =>
      "    NULL;\n"
  | .executeFormatInto sql intoTargets usingArgs =>
      let intoStr := String.intercalate ", " intoTargets
      let usingStr := match usingArgs with
        | []   => ""
        | args =>
            " USING " ++ String.intercalate ", " (args.map printExpr)
      "    EXECUTE " ++ printExpr sql ++ " INTO " ++ intoStr ++ usingStr ++ ";\n"
  | .raiseReraise =>
      "    RAISE;\n"

def printBodyStmts : List BodyStmt → String
  | []        => ""
  | s :: rest => printBodyStmt s ++ printBodyStmts rest

/-- Render the IF / ELSIF clause list. The first clause is
    rendered with the `IF` keyword; every subsequent clause is
    rendered as `ELSIF`. Empty clauses list renders to "" — the
    caller (`ifElseIf` arm) is responsible for the `END IF`. -/
def printIfElseIfClauses : List (Expr × List BodyStmt) → String
  | []                  => ""
  | (cond, body) :: rest =>
      "    IF " ++ printExpr cond ++ " THEN\n" ++
      printBodyStmts body ++
      printElsifClauses rest

/-- Render the trailing ELSIF clauses (everything after the first
    IF). Separated from `printIfElseIfClauses` so the keyword
    selection (IF vs ELSIF) is structural, not conditional. -/
def printElsifClauses : List (Expr × List BodyStmt) → String
  | []                  => ""
  | (cond, body) :: rest =>
      "    ELSIF " ++ printExpr cond ++ " THEN\n" ++
      printBodyStmts body ++
      printElsifClauses rest

/-- Render the optional ELSE branch. Empty body → no ELSE keyword. -/
def printIfElseIfElse : List BodyStmt → String
  | []   => ""
  | body => "    ELSE\n" ++ printBodyStmts body

/-- Render the EXCEPTION-handler list of a `BEGIN … EXCEPTION
    … END;` sub-block. Each handler renders as
    `        WHEN <cond1> [OR <cond2>…] THEN\n<handler body>`. -/
def printExceptionHandlers : List (List String × List BodyStmt) → String
  | []                       => ""
  | (conds, hbody) :: rest =>
      "        WHEN " ++ String.intercalate " OR " conds ++ " THEN\n" ++
      printBodyStmts hbody ++
      printExceptionHandlers rest

/-- Render the WHEN-clauses of a `CASE … END CASE;` statement.
    Each clause renders as
    `        WHEN <v₁>, <v₂>, … THEN\n<body>`. The caller chooses
    between simple-CASE (values to match against the subject)
    and searched-CASE (each value is a boolean condition). -/
def printCaseClauses : List (List Expr × List BodyStmt) → String
  | []                       => ""
  | (vals, cbody) :: rest =>
      "        WHEN " ++ String.intercalate ", " (vals.map printExpr) ++
      " THEN\n" ++
      printBodyStmts cbody ++
      printCaseClauses rest

/-- Render the optional ELSE branch of a `CASE … END CASE;`.
    Empty body → no ELSE keyword (postgres raises
    `case_not_found` at runtime if no WHEN matches). -/
def printCaseElse : List BodyStmt → String
  | []   => ""
  | body => "        ELSE\n" ++ printBodyStmts body

end

/-- Render the body — concatenation of statement renderings. -/
def printBody (stmts : List BodyStmt) : String :=
  printBodyStmts stmts

/-- Render a CREATE FUNCTION statement. Layout:
    {banner}\n
    CREATE OR REPLACE FUNCTION name(\n
        params\n
    ) RETURNS type\n
    LANGUAGE PLPGSQL\n
    {volatility}\n
    [SECURITY DEFINER\nSET search_path = …\n]
    AS $$\n
    [DECLARE\n    var1 type1;\n    var2 type2;\n    ...\n]
    BEGIN\n
    {body}END;\n
    $$;\n

    The optional DECLARE block is emitted only when `fn.declare`
    is non-empty. See `printDeclareBlock`. -/
def printDeclareEntry (p : FuncParam) : String :=
  let defaultStr := match p.default with
    | none   => ""
    | some e => " := " ++ printExpr e
  "    " ++ p.name ++ " " ++ p.pgType.toSql ++ defaultStr ++ ";"

/-- Render the DECLARE block of a CREATE FUNCTION. Empty list →
    no block at all. Non-empty → `DECLARE\n<entries>\n`. -/
def printDeclareBlock (vars : List FuncParam) : String :=
  match vars with
  | []   => ""
  | _    => "DECLARE\n" ++ String.intercalate "\n" (vars.map printDeclareEntry) ++ "\n"

/-- Render a CREATE FUNCTION statement to PL/pgSQL surface SQL. -/
def printCreateFunction (fn : CreateFunctionStmt) : String :=
  let returnsStr :=
    match fn.returnTable with
    | some cols =>
        let colStr := String.intercalate ", "
          (cols.map (fun (c, t) => c ++ " " ++ t.toSql))
        "TABLE (" ++ colStr ++ ")"
    | none =>
        if fn.returnSetOf then "SETOF " ++ fn.returnType.toSql
        else fn.returnType.toSql
  printBanner fn.banner ++
  "CREATE OR REPLACE FUNCTION " ++ fn.name.toSql ++ "(\n" ++
  printParams fn.params ++ "\n" ++
  ") RETURNS " ++ returnsStr ++ "\n" ++
  "LANGUAGE PLPGSQL\n" ++
  fn.volatility.toSql ++ "\n" ++
  printSecurityDefiner fn.securityDefiner ++
  "AS $$\n" ++
  printDeclareBlock fn.declare ++
  "BEGIN\n" ++
  printBody fn.body ++
  "END;\n" ++
  "$$;\n"

-- ============================================================================
-- CREATE TABLE rendering
-- ============================================================================

/-- Render a single column definition.

    Layout: `    name pgType[ NOT NULL][ DEFAULT <expr>][ GENERATED ALWAYS AS (<expr>) STORED]`. -/
def printColumnDef (c : ColumnDef) : String :=
  let nullClause := if c.notNull then " NOT NULL" else ""
  let defaultClause :=
    match c.default with
    | none => ""
    | some e => " DEFAULT " ++ printExpr e
  let generatedClause :=
    match c.generatedAs with
    | none => ""
    | some e => " GENERATED ALWAYS AS (" ++ printExpr e ++ ") STORED"
  "    " ++ c.name ++ " " ++ c.pgType.toSql ++ nullClause
    ++ defaultClause ++ generatedClause

/-- Render the column list — comma-separated, one per line. -/
def printColumns (cs : List ColumnDef) : String :=
  String.intercalate ",\n" (cs.map printColumnDef)

-- ----------------------------------------------------------------------------
-- Table-constraint rendering
-- ----------------------------------------------------------------------------

/-- Render a comma-separated parenthesized column-name list (used
    by PRIMARY KEY / UNIQUE / FOREIGN KEY constraint bodies). -/
def printConstraintColumns (cols : List String) : String :=
  "(" ++ String.intercalate ", " cols ++ ")"

/-- Render a `CONSTRAINT <name> ` prefix when a constraint name is
    provided, empty otherwise. -/
def printConstraintName (name : Option String) : String :=
  match name with
  | none => ""
  | some n => "CONSTRAINT " ++ n ++ " "

/-- Render an optional referential-action clause as
    ` ON DELETE <action>` / ` ON UPDATE <action>`. -/
def printRefAction (label : String) (action : Option ReferentialAction) : String :=
  match action with
  | none => ""
  | some a => " ON " ++ label ++ " " ++ a.toSql

/-- Render a single table constraint. -/
def printTableConstraint : TableConstraint → String
  | .primaryKey cols name =>
      printConstraintName name ++
      "PRIMARY KEY " ++ printConstraintColumns cols
  | .unique cols name =>
      printConstraintName name ++
      "UNIQUE " ++ printConstraintColumns cols
  | .foreignKey cols refTable refCols onDel onUpd name deferrable =>
      let deferrableClause :=
        if deferrable then " DEFERRABLE INITIALLY DEFERRED" else ""
      printConstraintName name ++
      "FOREIGN KEY " ++ printConstraintColumns cols ++
      " REFERENCES " ++ refTable ++ " " ++ printConstraintColumns refCols ++
      printRefAction "DELETE" onDel ++
      printRefAction "UPDATE" onUpd ++
      deferrableClause
  | .check expr name =>
      printConstraintName name ++
      "CHECK (" ++ printExpr expr ++ ")"

/-- Render a list of table constraints — comma-separated, one per
    line, each indented 4 spaces. -/
def printTableConstraints (cs : List TableConstraint) : String :=
  String.intercalate ",\n" (cs.map (fun c => "    " ++ printTableConstraint c))

/-- Render a CREATE TABLE statement. Layout:
    {banner}\n
    CREATE TABLE [IF NOT EXISTS] name (\n
        col1 type1[ NOT NULL][ DEFAULT …],\n
        …,\n
        [    CONSTRAINT … table-constraints …]\n
    );\n -/
def printCreateTable (t : CreateTableStmt) : String :=
  let ifne := if t.ifNotExists then "IF NOT EXISTS " else ""
  let body :=
    match t.constraints with
    | [] => printColumns t.columns
    | cs => printColumns t.columns ++ ",\n" ++ printTableConstraints cs
  let partitionStr :=
    match t.partitionBy with
    | none => ""
    | some pb =>
        "\nPARTITION BY " ++ pb.strategy.toSql ++
        " (" ++ String.intercalate ", " pb.columns ++ ")"
  printBanner t.banner ++
  "CREATE TABLE " ++ ifne ++ t.name.toSql ++ " (\n" ++
  body ++ "\n" ++
  ")" ++ partitionStr ++ ";\n"

-- ============================================================================
-- CREATE INDEX rendering
-- ============================================================================

/-- Render a single index column element — currently just the
    column name (operator-class / collation / sort-order extensions
    join when emit coverage requires them). -/
def printIndexElem (e : IndexElem) : String := e.column

/-- Render a comma-separated index column list. -/
def printIndexColumns (es : List IndexElem) : String :=
  String.intercalate ", " (es.map printIndexElem)

/-- Render a CREATE INDEX statement. Layout:
    {banner}\n
    CREATE [UNIQUE ]INDEX [IF NOT EXISTS ]name ON table USING method (cols)[ WHERE <pred>];\n -/
def printCreateIndex (i : CreateIndexStmt) : String :=
  let unique := if i.unique then "UNIQUE " else ""
  let ifne := if i.ifNotExists then "IF NOT EXISTS " else ""
  printBanner i.banner ++
  "CREATE " ++ unique ++ "INDEX " ++ ifne ++ i.name.toSql ++
  " ON " ++ i.table.toSql ++
  " USING " ++ i.method.toSql ++
  " (" ++ printIndexColumns i.columns ++ ")" ++
  printOptWhere i.whereExpr ++ ";\n"

/-- Render a CREATE FUNCTION with `LANGUAGE SQL` (declarative
    expression body). The body is wrapped in `SELECT ... ;` per
    Postgres SQL-function semantics. Used by the pure-SQL track
    (runtime-emit strategy track C); shrinks the trust chain by
    eliminating PL/pgSQL operational semantics for functions
    that can be expressed as one expression.

    Layout:
      {banner}\n
      CREATE OR REPLACE FUNCTION name(params) RETURNS type\n
      LANGUAGE SQL\n
      {volatility}\n
      [SECURITY DEFINER\nSET search_path = …\n]
      AS $$\n
        SELECT <expr>;\n
      $$;\n -/
def printCreateSqlFunction (fn : CreateSqlFunctionStmt) : String :=
  printBanner fn.banner ++
  "CREATE OR REPLACE FUNCTION " ++ fn.name.toSql ++
  "(" ++ printSqlParams fn.params ++ ") RETURNS " ++
  fn.returnType.toSql ++ "\n" ++
  "LANGUAGE SQL\n" ++
  fn.volatility.toSql ++ "\n" ++
  printSecurityDefiner fn.securityDefiner ++
  "AS $$\n" ++
  "  SELECT " ++ printExpr fn.body ++ ";\n" ++
  "$$;\n"

/-- Render a single CTE body as `<name> AS (SELECT <projs> [FROM …]
    [WHERE …] [GROUP BY …] [ORDER BY …] [LIMIT …])`. Helper for the
    multi-CTE `printWithCte` below. -/
def printOneCte (cte : WithCte) : String :=
  let projStr := String.intercalate ", " (cte.projections.map printExpr)
  let colsStr :=
    if cte.columnNames.isEmpty then ""
    else "(" ++ String.intercalate ", " cte.columnNames ++ ")"
  cte.name ++ colsStr ++ " AS (SELECT " ++ projStr ++
    printOptFrom cte.source ++ printOptWhere cte.whereCond ++
    printOptGroupBy cte.groupBy ++ printOrderBy cte.orderBy ++
    printOptLimitExpr cte.limit ++ ")"

/-- Render the non-recursive CTE prefix of a TABLE-returning /
    scalar-select function body: zero or more `WITH <cte> AS (...)`
    clauses, comma-separated. Empty list returns "" (no prefix);
    one or more emit `WITH <cte1> AS (...), <cte2> AS (...), …`. -/
def printWithCte : List WithCte → String
  | []   => ""
  | ctes => "WITH " ++ String.intercalate ", " (ctes.map printOneCte) ++ "\n  "

/-- Render a `CREATE FUNCTION` with `LANGUAGE SQL` that returns
    `SETOF <rowType>`. Body shape:

      SELECT <projectAlias>.* | *  FROM <source>
       [WHERE …] [ORDER BY …] [LIMIT …]

    Where `source` is a `SelectSource` (single table or JOIN tree),
    and `projectAlias` selects the named alias's `.*` projection
    when joining (so we get only the function's declared row type,
    not the cross-product).

    Layout:
      {banner}\n
      CREATE OR REPLACE FUNCTION name(params) RETURNS SETOF rowType\n
      LANGUAGE SQL\n
      {volatility}\n
      [SECURITY DEFINER\nSET search_path = …\n]
      AS $$\n
        SELECT <alias>.* | * FROM <source> [WHERE …] [ORDER …] [LIMIT n];\n
      $$;\n -/
def printCreateSetReturningFunction
    (fn : CreateSetReturningFunctionStmt) : String :=
  let projection :=
    match fn.projectAlias with
    | none   => "*"
    | some a => a ++ ".*"
  printBanner fn.banner ++
  "CREATE OR REPLACE FUNCTION " ++ fn.name.toSql ++
  "(" ++ printSqlParams fn.params ++
  ") RETURNS SETOF " ++ fn.rowType.toSql ++ "\n" ++
  "LANGUAGE SQL\n" ++
  fn.volatility.toSql ++ "\n" ++
  printSecurityDefiner fn.securityDefiner ++
  "AS $$\n" ++
  "  SELECT " ++ projection ++ " FROM " ++ printSelectSource fn.source ++
  printOptWhere fn.whereCond ++ printOrderBy fn.orderBy ++
  printOptLimitNat fn.limit ++ ";\n" ++
  "$$;\n"

/-- Render a `CREATE FUNCTION` with `LANGUAGE SQL` that returns
    an inline-typed result set via `RETURNS TABLE (col1 T1, …)`.

    Body shape:
      SELECT <projects…> FROM <source> [WHERE …] [ORDER BY …]
                              [LIMIT <expr>] [OFFSET <expr>]

    Differences from `printCreateSetReturningFunction`:
      * Return clause is `TABLE (name1 T1, name2 T2, …)` not
        `SETOF rowType`.
      * Projection list is explicit `printExpr` of each column
        (not `*` / `<alias>.*`).
      * LIMIT / OFFSET render printed exprs (not Nat literals) —
        supports parameter-bound bounds like `LIMIT p_limit`. -/
def printCreateTableReturningFunction
    (fn : CreateTableReturningFunctionStmt) : String :=
  let tableColsStr :=
    String.intercalate ", "
      (fn.tableCols.map (fun (n, t) => n ++ " " ++ t.toSql))
  let projectStr :=
    String.intercalate ", " (fn.projects.map printExpr)
  let selectKw := if fn.distinct then "SELECT DISTINCT " else "SELECT "
  printBanner fn.banner ++
  "CREATE OR REPLACE FUNCTION " ++ fn.name.toSql ++
  "(" ++ printSqlParams fn.params ++
  ") RETURNS TABLE (" ++ tableColsStr ++ ")\n" ++
  "LANGUAGE SQL\n" ++
  fn.volatility.toSql ++ "\n" ++
  printSecurityDefiner fn.securityDefiner ++
  "AS $$\n" ++
  "  " ++ printWithCte fn.withCte ++ selectKw ++ projectStr ++
  printOptFrom fn.source ++ printOptWhere fn.whereCond ++
  printOptGroupBy fn.groupBy ++ printOrderBy fn.orderBy ++
  printOptLimitExpr fn.limit ++ printOptOffsetExpr fn.offset ++ ";\n" ++
  "$$;\n"

/-- Render a `CREATE FUNCTION` with `LANGUAGE SQL` that returns a
    scalar value computed via `SELECT <projectExpr> FROM <source>
    [WHERE …]`. Body shape sits between `CreateSqlFunctionStmt`
    (no FROM at all) and `CreateSetReturningFunctionStmt`
    (returns a set of rows). -/
def printCreateScalarSelectFunction
    (fn : CreateScalarSelectFunctionStmt) : String :=
  printBanner fn.banner ++
  "CREATE OR REPLACE FUNCTION " ++ fn.name.toSql ++
  "(" ++ printSqlParams fn.params ++
  ") RETURNS " ++ fn.returnType.toSql ++ "\n" ++
  "LANGUAGE SQL\n" ++
  fn.volatility.toSql ++ "\n" ++
  printSecurityDefiner fn.securityDefiner ++
  "AS $$\n" ++
  "  " ++ printWithCte fn.withCte ++ "SELECT " ++ printExpr fn.project ++
  printOptFrom fn.source ++ printOptWhere fn.whereCond ++ ";\n" ++
  "$$;\n"

/-- Render a `CREATE FUNCTION` with `LANGUAGE SQL` whose body is
    a `WITH RECURSIVE` CTE followed by an outer
    `SELECT * FROM <cteName>`. Used for tree / graph traversal
    helpers. -/
def printCreateRecursiveCteFunction
    (fn : CreateRecursiveCteFunctionStmt) : String :=
  let tableColsStr :=
    String.intercalate ", "
      (fn.tableCols.map (fun (n, t) => n ++ " " ++ t.toSql))
  let baseProjStr :=
    String.intercalate ", " (fn.baseProjections.map printExpr)
  let recProjStr :=
    String.intercalate ", " (fn.recursiveProjections.map printExpr)
  let cycleStr :=
    match fn.cycle with
    | none   => ""
    | some c =>
        "  CYCLE " ++ c.column ++ " SET " ++ c.flagCol ++
        " USING " ++ c.pathCol ++ "\n"
  printBanner fn.banner ++
  "CREATE OR REPLACE FUNCTION " ++ fn.name.toSql ++
  "(" ++ printSqlParams fn.params ++
  ") RETURNS TABLE (" ++ tableColsStr ++ ")\n" ++
  "LANGUAGE SQL\n" ++
  fn.volatility.toSql ++ "\n" ++
  printSecurityDefiner fn.securityDefiner ++
  "AS $$\n" ++
  "  WITH RECURSIVE " ++ fn.cteName ++ " AS (\n" ++
  "    SELECT " ++ baseProjStr ++
  printOptFrom fn.baseSource ++ printOptWhere fn.baseWhere ++ "\n" ++
  "    UNION ALL\n" ++
  "    SELECT " ++ recProjStr ++
  printOptFrom fn.recursiveSource ++ printOptWhere fn.recursiveWhere ++ "\n" ++
  "  )\n" ++
  cycleStr ++
  "  SELECT * FROM " ++ fn.cteName ++
  printOptWhere fn.outerWhere ++ printOrderBy fn.outerOrderBy ++
  printOptLimitExpr fn.outerLimit ++ printOptOffsetExpr fn.outerOffset ++ ";\n" ++
  "$$;\n"

/-- Render a `TriggerTiming` to PG keywords. -/
def printTiming : TriggerTiming → String
  | .before    => "BEFORE"
  | .after     => "AFTER"
  | .insteadOf => "INSTEAD OF"

/-- Render a `TriggerEvent` to its PG keyword. -/
def printEvent : TriggerEvent → String
  | .insertEvent   => "INSERT"
  | .updateEvent   => "UPDATE"
  | .deleteEvent   => "DELETE"
  | .truncateEvent => "TRUNCATE"

/-- Render a `TriggerLevel` to its PG `FOR EACH …` clause. -/
def printLevel : TriggerLevel → String
  | .row       => "FOR EACH ROW"
  | .statement => "FOR EACH STATEMENT"

/-- Join trigger events with " OR ". An empty list is invalid by
    construction; we render the empty string and rely on the
    libpg_query gate to reject it. -/
def printEvents : List TriggerEvent → String
  | []      => ""
  | [e]     => printEvent e
  | e :: es => printEvent e ++ " OR " ++ printEvents es

/-- Render a CREATE TRIGGER statement. Layout:
    {banner}\n
    CREATE [OR REPLACE ]TRIGGER name timing events
    ON table
    level
    EXECUTE FUNCTION fn();\n -/
def printCreateTrigger (t : CreateTriggerStmt) : String :=
  let bannerStr :=
    match t.banner with
    | [] => ""
    | lines => String.join (lines.map (fun s => s ++ "\n")) ++ "\n"
  let orReplace := if t.orReplace then "OR REPLACE " else ""
  bannerStr ++
  "CREATE " ++ orReplace ++ "TRIGGER " ++ t.name.toSql ++ "\n" ++
  "  " ++ printTiming t.timing ++ " " ++ printEvents t.events ++ "\n" ++
  "  ON " ++ t.table.toSql ++ "\n" ++
  "  " ++ printLevel t.level ++ "\n" ++
  "  EXECUTE FUNCTION " ++ t.function ++ "();\n"

/-- Render a CREATE SCHEMA statement. Layout:
    {banner}\n
    CREATE SCHEMA [IF NOT EXISTS ]name[ AUTHORIZATION role];\n -/
def printCreateSchema (s : CreateSchemaStmt) : String :=
  let bannerStr :=
    match s.banner with
    | [] => ""
    | lines => String.join (lines.map (fun l => l ++ "\n")) ++ "\n"
  let ifne := if s.ifNotExists then "IF NOT EXISTS " else ""
  let authStr :=
    match s.authorization with
    | none      => ""
    | some role => " AUTHORIZATION " ++ role
  bannerStr ++
  "CREATE SCHEMA " ++ ifne ++ s.name.toSql ++ authStr ++ ";\n"

/-- Render a CREATE DOMAIN statement. Layout:
    {banner}\n
    CREATE DOMAIN name AS base_type[\n  CHECK (check_expr)];\n -/
def printCreateDomain (d : CreateDomainStmt) : String :=
  let bannerStr :=
    match d.banner with
    | [] => ""
    | lines => String.join (lines.map (fun l => l ++ "\n")) ++ "\n"
  let checkStr :=
    match d.check with
    | none   => ""
    | some e => "\n  CHECK (" ++ printExpr e ++ ")"
  bannerStr ++
  "CREATE DOMAIN " ++ d.name.toSql ++ " AS " ++ d.baseType.toSql ++
  checkStr ++ ";\n"

/-- Render one composite-type field: `name type`. -/
def printCompositeField (f : CompositeField) : String :=
  "  " ++ f.name ++ " " ++ f.type.toSql

/-- Render the comma-separated field list, one field per line. -/
def printCompositeFields : List CompositeField → String
  | []      => ""
  | [f]     => printCompositeField f ++ "\n"
  | f :: fs => printCompositeField f ++ ",\n" ++ printCompositeFields fs

/-- Render one enum variant: `'variant'`. Single quotes are
    doubled per the same SQL-literal escaping as `printLitConst`. -/
def printEnumVariant (v : String) : String :=
  "'" ++ v.replace "'" "''" ++ "'"

/-- Render the comma-separated enum-variant list. -/
def printEnumVariants : List String → String
  | []      => ""
  | [v]     => printEnumVariant v
  | v :: vs => printEnumVariant v ++ ", " ++ printEnumVariants vs

/-- Render a CREATE TYPE statement. Layout for composite:
    {banner}\n
    CREATE TYPE name AS (
      f1 t1,
      f2 t2
    );\n

    Layout for enum:
    {banner}\n
    CREATE TYPE name AS ENUM ('v1', 'v2');\n -/
def printCreateType (t : CreateTypeStmt) : String :=
  let bannerStr :=
    match t.banner with
    | [] => ""
    | lines => String.join (lines.map (fun l => l ++ "\n")) ++ "\n"
  bannerStr ++
  match t.shape with
  | .composite fs =>
    "CREATE TYPE " ++ t.name.toSql ++ " AS (\n" ++
    printCompositeFields fs ++
    ");\n"
  | .enum vs =>
    "CREATE TYPE " ++ t.name.toSql ++ " AS ENUM (" ++
    printEnumVariants vs ++ ");\n"

/-- Render a CREATE POLICY statement. Layout:
    {banner}\n
    CREATE POLICY name ON table\n
    FOR command\n
    [USING (expr)\n]
    [WITH CHECK (expr)\n]
    ;\n -/
def printCreatePolicy (p : CreatePolicyStmt) : String :=
  let bannerStr :=
    match p.banner with
    | [] => ""
    | lines => String.join (lines.map (fun l => l ++ "\n")) ++ "\n"
  let usingStr :=
    match p.using_ with
    | none   => ""
    | some e => "  USING (" ++ printExpr e ++ ")\n"
  let withCheckStr :=
    match p.withCheck with
    | none   => ""
    | some e => "  WITH CHECK (" ++ printExpr e ++ ")\n"
  bannerStr ++
  "CREATE POLICY " ++ p.name.toSql ++ " ON " ++ p.table.toSql ++ "\n" ++
  "  FOR " ++ p.command.toSql ++ "\n" ++
  usingStr ++
  withCheckStr ++
  ";\n"

/-- Render a top-level statement. -/
def printStmt : Stmt → String
  | .createFunction               fn => printCreateFunction fn
  | .createTable                  t  => printCreateTable t
  | .createIndex                  i  => printCreateIndex i
  | .createSqlFunction            fn => printCreateSqlFunction fn
  | .createSetReturningFunction   fn => printCreateSetReturningFunction fn
  | .createTableReturningFunction fn => printCreateTableReturningFunction fn
  | .createScalarSelectFunction   fn => printCreateScalarSelectFunction fn
  | .createRecursiveCteFunction   fn => printCreateRecursiveCteFunction fn
  | .createTrigger                t  => printCreateTrigger t
  | .createSchema                 s  => printCreateSchema s
  | .createDomain                 d  => printCreateDomain d
  | .createType                   t  => printCreateType t
  | .createPolicy                 p  => printCreatePolicy p

end Pg.Pretty
