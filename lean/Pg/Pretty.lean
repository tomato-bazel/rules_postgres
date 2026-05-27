/-
Pg.Pretty — pretty-printer for `Pg.Ast.Expr` / `Pg.Ast.SelectSource`
/ `Pg.Ast.SelectQuery` / `Pg.Ast.BodyStmt` to PL/pgSQL source.

Pattern A factor of Aion's monolithic PgPretty.lean. The split:

  * `printLitConst` — generic literal printer (4 cases:
    int / text / bool / null). The PG-specific `infinity` literal
    moved into `ExprExt.infinity` and is rendered by
    `printExprExt`.
  * `printExpr` + `printExprExt` — mutual recursion over the
    factored Expr shape. `printExpr` handles the 32 generic
    `Polyglot.Sql.Ast.Expr` ctors and dispatches `.ext e` to
    `printExprExt`, which handles the 22 PG-specific
    `Pg.Ast.ExprExt` ctors.
  * `printSelectSource` + `printSelectSourceExt` — same shape
    for the FROM-clause source AST.
  * `printSelectQuery` — uses `printSelectSource` + helpers.
  * `printBodyStmt` and friends — unchanged structure since
    `BodyStmt` is fully PG-specific (no factor needed); just
    consumes the factored `Expr` + `SelectQuery`.

Output stability: every emit is `String`-concatenation only.
No HashMaps, no ordered-set traversals — given the same AST,
the output is bit-identical across runs.

Moved from Aion's `lean/Aion/Db/PgPretty.lean` as part of PgAst
extraction Phase 1b. The Create*Stmt-level statement printers
(printCreateFunctionStmt etc.) stay in Aion for now since their
input structures (CreateFunctionStmt etc.) haven't been factored
yet; they land in a sibling `Pg.PrettyStmt` follow-up.
-/

import Pg.Ast

namespace Pg.Pretty

open Pg.Ast
open Polyglot.Sql.Ast

/-! ## Literal printing -/

/-- Render the generic literal sum. PG's `infinity` literal moved to
    `ExprExt.infinity` and is handled by `printExprExt`. -/
def printLitConst : LitConst → String
  | .int n      => toString n
  | .text s     => "'" ++ s.replace "'" "''" ++ "'"
  | .bool true  => "TRUE"
  | .bool false => "FALSE"
  | .null       => "NULL"

/-! ## Expression printing — mutual recursion across the split shape.

    `partial def` because the parameterized inductive
    `Polyglot.Sql.Ast.Expr Ext` doesn't have a structural
    termination proof under Lean's default well-founded checks
    (the same property the POC walker / EmitImmunity recursors
    used). Concrete production terms terminate; the structural
    bound is provable via a size measure if needed for proof
    development. -/

mutual

partial def printExpr : Expr → String
  -- Leaves
  | .var n        => n
  | .field b n    => printExpr b ++ "." ++ n
  | .litConst c   => printLitConst c
  | .countStar    => "COUNT(*)"
  -- Binary boolean / comparison
  | .eq l r       => "(" ++ printExpr l ++ " = "   ++ printExpr r ++ ")"
  | .ge l r       => "(" ++ printExpr l ++ " >= "  ++ printExpr r ++ ")"
  | .lt l r       => "(" ++ printExpr l ++ " < "   ++ printExpr r ++ ")"
  | .gt l r       => "(" ++ printExpr l ++ " > "   ++ printExpr r ++ ")"
  | .and_ l r     => "(" ++ printExpr l ++ " AND " ++ printExpr r ++ ")"
  | .or_ l r      => "(" ++ printExpr l ++ " OR "  ++ printExpr r ++ ")"
  | .isDistinctFrom l r =>
      "(" ++ printExpr l ++ " IS DISTINCT FROM " ++ printExpr r ++ ")"
  -- Unary
  | .not_ e       => "NOT (" ++ printExpr e ++ ")"
  | .isNull e     => "(" ++ printExpr e ++ " IS NULL)"
  | .isNotNull e  => "(" ++ printExpr e ++ " IS NOT NULL)"
  -- Function call (raw String name)
  | .call n args  =>
      n ++ "(" ++ String.intercalate ", " (args.map printExpr) ++ ")"
  -- EXISTS
  | .existsIn table cond =>
      "EXISTS (SELECT 1 FROM " ++ table ++ " WHERE " ++ printExpr cond ++ ")"
  | .existsInAliased table alias cond =>
      "EXISTS (SELECT 1 FROM " ++ table ++ " AS " ++ alias ++
        " WHERE " ++ printExpr cond ++ ")"
  -- Coalesce + typeCast (generic — String type label)
  | .coalesce args =>
      "COALESCE(" ++ String.intercalate ", " (args.map printExpr) ++ ")"
  | .typeCast e t =>
      "(" ++ printExpr e ++ "::" ++ t ++ ")"
  -- Arithmetic
  | .plus l r     => "(" ++ printExpr l ++ " + " ++ printExpr r ++ ")"
  | .minus l r    => "(" ++ printExpr l ++ " - " ++ printExpr r ++ ")"
  | .multiply l r => "(" ++ printExpr l ++ " * " ++ printExpr r ++ ")"
  | .divide l r   => "(" ++ printExpr l ++ " / " ++ printExpr r ++ ")"
  -- Pattern + range
  | .like subject pattern =>
      "(" ++ printExpr subject ++ " LIKE " ++ printExpr pattern ++ ")"
  | .between subject lo hi =>
      "(" ++ printExpr subject ++ " BETWEEN " ++ printExpr lo ++
        " AND " ++ printExpr hi ++ ")"
  -- Aggregates
  | .aggCallOrdered name args orderBy orderDesc =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let dirStr := if orderDesc then " DESC" else " ASC"
      name ++ "(" ++ argStr ++ " ORDER BY " ++ printExpr orderBy ++ dirStr ++ ")"
  | .aggCallDistinct name arg =>
      name ++ "(DISTINCT " ++ printExpr arg ++ ")"
  | .aggCallFiltered name args filter =>
      let argStr := String.intercalate ", " (args.map printExpr)
      name ++ "(" ++ argStr ++ ") FILTER (WHERE " ++ printExpr filter ++ ")"
  -- Array / row
  | .arrayLit elements =>
      "ARRAY[" ++ String.intercalate ", " (elements.map printExpr) ++ "]"
  | .arrayIdx arr idx =>
      "(" ++ printExpr arr ++ ")[" ++ printExpr idx ++ "]"
  | .rowExpr fields =>
      "ROW(" ++ String.intercalate ", " (fields.map printExpr) ++ ")"
  -- EXTRACT
  | .extract field expr =>
      "EXTRACT(" ++ field ++ " FROM " ++ printExpr expr ++ ")"
  -- CASE (searched + simple) — parallel-lists encoding.
  | .caseWhen conds results elseExpr =>
      let condStrs := conds.map printExpr
      let resultStrs := results.map printExpr
      let armStr := String.intercalate " "
        ((condStrs.zip resultStrs).map (fun (c, r) =>
          "WHEN " ++ c ++ " THEN " ++ r))
      let elseStr := match elseExpr with
        | none   => ""
        | some e => " ELSE " ++ printExpr e
      "(CASE " ++ armStr ++ elseStr ++ " END)"
  | .caseSimple subject whenVals thenResults elseExpr =>
      let whenStrs := whenVals.map printExpr
      let thenStrs := thenResults.map printExpr
      let armStr := String.intercalate " "
        ((whenStrs.zip thenStrs).map (fun (v, r) =>
          "WHEN " ++ v ++ " THEN " ++ r))
      let elseStr := match elseExpr with
        | none   => ""
        | some e => " ELSE " ++ printExpr e
      "(CASE " ++ printExpr subject ++ " " ++ armStr ++ elseStr ++ " END)"
  -- IN list / concat
  | .inList x vals =>
      "(" ++ printExpr x ++ " IN (" ++
      String.intercalate ", " (vals.map printExpr) ++ "))"
  | .concat l r =>
      "(" ++ printExpr l ++ " || " ++ printExpr r ++ ")"
  -- Scalar subquery — full production shape.
  | .selectScalar col fromTable alias whereCond orderBy limit =>
      let aliasStr := match alias with
        | none   => ""
        | some a => " AS " ++ a
      let whereStr := match whereCond with
        | none   => ""
        | some w => " WHERE " ++ printExpr w
      let orderStr := match orderBy with
        | none           => ""
        | some (e, desc) =>
            " ORDER BY " ++ printExpr e ++
            (if desc then " DESC" else " ASC")
      let limitStr := match limit with
        | none   => ""
        | some n => " LIMIT " ++ toString n
      "(SELECT " ++ printExpr col ++
      " FROM " ++ fromTable ++ aliasStr ++
      whereStr ++ orderStr ++ limitStr ++ ")"
  -- Dialect extension hatch
  | .ext e => printExprExt e

partial def printExprExt : ExprExt → String
  -- Catalog-grounded calls
  | .callQualified callee args =>
      Identifier.toSql callee ++ "(" ++
        String.intercalate ", " (args.map printExpr) ++ ")"
  | .callBuiltin n args =>
      n ++ "(" ++ String.intercalate ", " (args.map printExpr) ++ ")"
  -- EXISTS variants
  | .existsInQualified table cond =>
      "EXISTS (SELECT 1 FROM " ++ Identifier.toSql table ++
        " WHERE " ++ printExpr cond ++ ")"
  | .existsInAliasedQualified table alias cond =>
      "EXISTS (SELECT 1 FROM " ++ Identifier.toSql table ++ " AS " ++ alias ++
        " WHERE " ++ printExpr cond ++ ")"
  | .existsInAliasedBuiltin table alias cond =>
      "EXISTS (SELECT 1 FROM " ++ table ++ " AS " ++ alias ++
        " WHERE " ++ printExpr cond ++ ")"
  -- POSIX regex
  | .regexMatch subject pattern =>
      let regexStr := Pg.RegexAst.PgRegexAst.toString pattern
      "(" ++ printExpr subject ++ " ~ '" ++
        regexStr.replace "'" "''" ++ "')"
  -- PG-specific operators
  | .ilike subject pattern =>
      "(" ++ printExpr subject ++ " ILIKE " ++ printExpr pattern ++ ")"
  | .eqAny x arr =>
      "(" ++ printExpr x ++ " = ANY(" ++ printExpr arr ++ "))"
  | .ltreeDescendantOf l r =>
      "(" ++ printExpr l ++ " <@ " ++ printExpr r ++ ")"
  -- JSONB ops
  | .jsonbHasKey j k =>
      "(" ++ printExpr j ++ " ? " ++ printExpr k ++ ")"
  | .jsonbGet j k =>
      "(" ++ printExpr j ++ " -> " ++ printExpr k ++ ")"
  | .jsonbGetText j k =>
      "(" ++ printExpr j ++ " ->> " ++ printExpr k ++ ")"
  | .jsonbPathGetText j path =>
      "(" ++ printExpr j ++ " #>> " ++ printExpr path ++ ")"
  | .jsonbConcat l r =>
      "(" ++ printExpr l ++ " || " ++ printExpr r ++ ")"
  | .jsonbExtractText obj key =>
      "(" ++ printExpr obj ++ " ->> '" ++ key.replace "'" "''" ++ "')"
  -- Trigger context atoms
  | .tgOp        => "TG_OP"
  | .tgTableName => "TG_TABLE_NAME"
  -- PG-typed CAST
  | .typeCastPg e t =>
      "(" ++ printExpr e ++ "::" ++ t.toSql ++ ")"
  -- PG-specific literal
  | .infinity => "'infinity'"

end

/-! ## SelectSource / SelectQuery printing -/

mutual

partial def printSelectSource : SelectSource → String
  | .table name none         => name
  | .table name (some a)     => name ++ " AS " ++ a
  | .join lhs rhs kind on    =>
      printSelectSource lhs ++ " " ++ kind.toSql ++ " " ++
      printSelectSource rhs ++ " ON " ++ printExpr on
  | .functionCall name args alias =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let aliasStr := match alias with | none => "" | some a => " AS " ++ a
      name ++ "(" ++ argStr ++ ")" ++ aliasStr
  | .functionCallWithOrdinality name args tableAlias columnAliases =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let colAliasStr := String.intercalate ", " columnAliases
      name ++ "(" ++ argStr ++ ") WITH ORDINALITY AS " ++
      tableAlias ++ "(" ++ colAliasStr ++ ")"
  | .empty => ""
  | .ext s => printSelectSourceExt s

partial def printSelectSourceExt : SelectSourceExt → String
  | .tableQualified t none      => Identifier.toSql t
  | .tableQualified t (some a)  => Identifier.toSql t ++ " AS " ++ a
  | .tableBuiltin n none        => n
  | .tableBuiltin n (some a)    => n ++ " AS " ++ a
  | .tableLocal n none          => n
  | .tableLocal n (some a)      => n ++ " AS " ++ a
  | .functionCallQualified callee args alias =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let aliasStr := match alias with | none => "" | some a => " AS " ++ a
      Identifier.toSql callee ++ "(" ++ argStr ++ ")" ++ aliasStr
  | .functionCallBuiltin name args alias =>
      let argStr := String.intercalate ", " (args.map printExpr)
      let aliasStr := match alias with | none => "" | some a => " AS " ++ a
      name ++ "(" ++ argStr ++ ")" ++ aliasStr
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

end

/-! ## SELECT query + helpers consumed by BodyStmt -/

def printOptWhere (whereCond : Option Expr) : String :=
  match whereCond with
  | none   => ""
  | some w => " WHERE " ++ printExpr w

def printOptFrom (source : SelectSource) : String :=
  match source with
  | .empty => ""
  | s      => " FROM " ++ printSelectSource s

def printOptOrderBy (orderBy : List (Expr × Bool)) : String :=
  match orderBy with
  | []   => ""
  | _    =>
      " ORDER BY " ++ String.intercalate ", "
        (orderBy.map (fun (e, desc) =>
          printExpr e ++ (if desc then " DESC" else " ASC")))

def printOptLimit (limit : Option Expr) : String :=
  match limit with
  | none   => ""
  | some e => " LIMIT " ++ printExpr e

def printSelectQuery (q : SelectQuery) : String :=
  let projStr := String.intercalate ", " (q.projections.map printExpr)
  "SELECT " ++ projStr ++ printOptFrom q.source ++ printOptWhere q.whereCond ++
    printOptOrderBy q.orderBy ++ printOptLimit q.limit

/-! ## PL/pgSQL body / function-parameter printing -/

def printParam (p : FuncParam) : String :=
  let defaultStr := match p.default with
    | none   => ""
    | some e => " DEFAULT " ++ printExpr e
  let variadicPrefix := if p.variadic then "VARIADIC " else ""
  "    " ++ variadicPrefix ++ p.name ++ " " ++ p.pgType.toSql ++ defaultStr

def printParams (ps : List FuncParam) : String :=
  String.intercalate ",\n" (ps.map printParam)

def printRaiseArgs (args : List Expr) : String :=
  match args with
  | []   => ""
  | _    => ", " ++ String.intercalate ", " (args.map printExpr)

def printErrcode (errcode : Option String) : String :=
  match errcode with
  | none   => ""
  | some c => " USING ERRCODE = '" ++ c ++ "'"

def printLocalDecl (p : FuncParam) : String :=
  let defaultStr := match p.default with
    | none   => ""
    | some e => " := " ++ printExpr e
  "        " ++ p.name ++ " " ++ p.pgType.toSql ++ defaultStr ++ ";"

mutual

partial def printBodyStmt : BodyStmt → String
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
      printOptOrderBy query.orderBy ++ printOptLimit query.limit ++ ";\n"
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
        | args => " USING " ++ String.intercalate ", " (args.map printExpr)
      "    EXECUTE " ++ printExpr sql ++ usingStr ++ ";\n"
  | .insertStmt table columns values onConflict returningInto =>
      let colStr := String.intercalate ", " columns
      let valStr := String.intercalate ", " (values.map printExpr)
      let onConflictStr := match onConflict with
        | none => ""
        | some .doNothing => " ON CONFLICT DO NOTHING"
        | some (.doUpdate u) =>
            let targetStr := String.intercalate ", " u.targetCols
            let setStr := String.intercalate ", "
              (u.sets.map (fun (c, e) => c ++ " = " ++ printExpr e))
            " ON CONFLICT (" ++ targetStr ++ ") DO UPDATE SET " ++
            setStr ++ printOptWhere u.whereCond
      let returningStr := match returningInto with
        | none           => ""
        | some (col, var) => " RETURNING " ++ col ++ " INTO " ++ var
      "    INSERT INTO " ++ table ++ " (" ++ colStr ++ ")" ++
      " VALUES (" ++ valStr ++ ")" ++ onConflictStr ++ returningStr ++ ";\n"
  | .insertStmtQualified table columns values onConflict returningInto =>
      let colStr := String.intercalate ", " columns
      let valStr := String.intercalate ", " (values.map printExpr)
      let onConflictStr := match onConflict with
        | none => ""
        | some .doNothing => " ON CONFLICT DO NOTHING"
        | some (.doUpdate u) =>
            let targetStr := String.intercalate ", " u.targetCols
            let setStr := String.intercalate ", "
              (u.sets.map (fun (c, e) => c ++ " = " ++ printExpr e))
            " ON CONFLICT (" ++ targetStr ++ ") DO UPDATE SET " ++
            setStr ++ printOptWhere u.whereCond
      let returningStr := match returningInto with
        | none           => ""
        | some (col, var) => " RETURNING " ++ col ++ " INTO " ++ var
      "    INSERT INTO " ++ Identifier.toSql table ++ " (" ++ colStr ++ ")" ++
      " VALUES (" ++ valStr ++ ")" ++ onConflictStr ++ returningStr ++ ";\n"
  | .deleteStmt table whereCond =>
      "    DELETE FROM " ++ table ++ printOptWhere whereCond ++ ";\n"
  | .deleteStmtQualified table whereCond =>
      "    DELETE FROM " ++ Identifier.toSql table ++ printOptWhere whereCond ++ ";\n"
  | .exitLoop      => "    EXIT;\n"
  | .returnBare    => "    RETURN;\n"
  | .nullStmt      => "    NULL;\n"
  | .executeFormatInto sql intoTargets usingArgs =>
      let intoStr := String.intercalate ", " intoTargets
      let usingStr := match usingArgs with
        | []   => ""
        | args => " USING " ++ String.intercalate ", " (args.map printExpr)
      "    EXECUTE " ++ printExpr sql ++ " INTO " ++ intoStr ++ usingStr ++ ";\n"
  | .raiseReraise  => "    RAISE;\n"

partial def printBodyStmts : List BodyStmt → String
  | []        => ""
  | s :: rest => printBodyStmt s ++ printBodyStmts rest

partial def printIfElseIfClauses : List (Expr × List BodyStmt) → String
  | []                  => ""
  | (cond, body) :: rest =>
      "    IF " ++ printExpr cond ++ " THEN\n" ++
      printBodyStmts body ++
      printElsifClauses rest

partial def printElsifClauses : List (Expr × List BodyStmt) → String
  | []                  => ""
  | (cond, body) :: rest =>
      "    ELSIF " ++ printExpr cond ++ " THEN\n" ++
      printBodyStmts body ++
      printElsifClauses rest

partial def printIfElseIfElse : List BodyStmt → String
  | []   => ""
  | body => "    ELSE\n" ++ printBodyStmts body

partial def printExceptionHandlers : List (List String × List BodyStmt) → String
  | []                       => ""
  | (conds, hbody) :: rest =>
      "        WHEN " ++ String.intercalate " OR " conds ++ " THEN\n" ++
      printBodyStmts hbody ++
      printExceptionHandlers rest

partial def printCaseClauses : List (List Expr × List BodyStmt) → String
  | []                       => ""
  | (vals, cbody) :: rest =>
      "        WHEN " ++ String.intercalate ", " (vals.map printExpr) ++
      " THEN\n" ++
      printBodyStmts cbody ++
      printCaseClauses rest

partial def printCaseElse : List BodyStmt → String
  | []   => ""
  | body => "        ELSE\n" ++ printBodyStmts body

end

/-- Render a complete PL/pgSQL function body. -/
def printBody (stmts : List BodyStmt) : String :=
  printBodyStmts stmts

end Pg.Pretty
