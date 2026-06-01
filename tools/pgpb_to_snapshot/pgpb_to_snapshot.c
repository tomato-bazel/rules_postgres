/*
 * pgpb_to_snapshot — fold a sequence of .pgpb AST files into a
 * Pg.Catalog.Snapshot Lean source.
 *
 * Postgres-dialect `folder` for `sql_catalog_library`
 * (@rules_lang//polyglot:sql.bzl). Reads one or more `.pgpb` files
 * (pg_query.ParseResult protobuf payloads from `tools:sql_to_protobuf`),
 * walks the DDL statements in declaration order via the protobuf-c
 * bindings shipped with libpg_query, and writes a self-contained Lean
 * source file containing the resulting `snapshot : Pg.Catalog.Snapshot`.
 *
 * DDL kinds covered:
 *   CreateSchemaStmt    → namespace
 *   CreateDomainStmt    → type (typtype=.domain)
 *   CompositeTypeStmt   → type (typtype=.composite) + relation + attributes
 *   CreateEnumStmt      → type (typtype=.enum) + enum-label side-table
 *   CreateStmt          → relation + attributes (CREATE TABLE)
 *   CreateFunctionStmt  → proc (proargnames + proargmodes + proretset)
 *
 * Skipped (no catalog impact in savvi's corpus):
 *   AlterTableStmt, DropStmt, DoStmt, CommentStmt, VariableSetStmt,
 *   CreateTrigStmt, IndexStmt, GrantStmt, CreatePolicyStmt.
 *
 * Invocation:
 *   pgpb_to_snapshot --module <NAME> --output <FILE> [--format lean] \
 *       <ast1.pgpb> [<ast2.pgpb> ...]
 *
 * Hermetic; no Python or shell prerequisite. Companion to
 * sql_to_protobuf — same libpg_query release governs both encoder
 * and decoder via the same Bazel resolution.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pg_query.pb-c.h"

/* Lean's `⟨…⟩` (U+27E8, U+27E9) — UTF-8 sequences. Used as adjacent
 * string-literal concatenation in the printf format strings below.
 * Inlining `" LE "123` as a single literal misparses because the
 * compiler greedily consumes hex digits past the codepoint boundary. */
#define LE "\xe2\x9f\xa8"
#define RE "\xe2\x9f\xa9"

/* ─── Built-in postgres-17 type OIDs ────────────────────────────── */

typedef struct { const char *name; uint32_t oid; } BuiltinType;
static const BuiltinType BUILTIN_TYPES[] = {
    {"bool", 16}, {"bytea", 17}, {"char", 18}, {"name", 19},
    {"int8", 20}, {"bigint", 20},
    {"int2", 21}, {"smallint", 21},
    {"int4", 23}, {"integer", 23}, {"int", 23},
    {"text", 25}, {"oid", 26},
    {"float4", 700}, {"real", 700},
    {"float8", 701}, {"double", 701}, {"double_precision", 701},
    {"numeric", 1700}, {"decimal", 1700},
    {"varchar", 1043}, {"bpchar", 1042},
    {"uuid", 2950},
    {"date", 1082},
    {"time", 1083}, {"timetz", 1266},
    {"timestamp", 1114}, {"timestamptz", 1184},
    {"interval", 1186},
    {"json", 114}, {"jsonb", 3802},
    {"void", 2278}, {"record", 2249},
    {"_int8", 1016}, {"_int4", 1007}, {"_text", 1009}, {"_bool", 1000},
    {"regclass", 2205}, {"regproc", 24}, {"regprocedure", 2202},
    {"regoper", 2203}, {"regoperator", 2204}, {"regtype", 2206},
    {"regrole", 4096}, {"regnamespace", 4089},
    {NULL, 0}
};

static int builtin_oid_lookup(const char *name) {
    for (const BuiltinType *b = BUILTIN_TYPES; b->name; b++) {
        if (strcasecmp(b->name, name) == 0) return (int)b->oid;
    }
    return -1;
}

/* `void` and `record` are the pseudo types; everything else in the
 * builtin table is `.base`. */
static int builtin_is_pseudo(const char *name) {
    return (strcmp(name, "void") == 0) || (strcmp(name, "record") == 0);
}

static const char *builtin_name_for_oid(uint32_t oid) {
    for (const BuiltinType *b = BUILTIN_TYPES; b->name; b++) {
        if (b->oid == oid) return b->name;
    }
    return NULL;
}

/* ─── Dynamic-array helper ──────────────────────────────────────── */

#define ARR_INIT_CAP 16

#define DEFINE_ARR(NAME, ELT) \
    typedef struct { ELT *data; size_t len, cap; } NAME; \
    static void NAME##_init(NAME *a) { a->data = NULL; a->len = 0; a->cap = 0; } \
    static ELT *NAME##_push(NAME *a) { \
        if (a->len == a->cap) { \
            a->cap = a->cap ? a->cap * 2 : ARR_INIT_CAP; \
            a->data = (ELT *)realloc(a->data, a->cap * sizeof(ELT)); \
        } \
        return &a->data[a->len++]; \
    }

/* ─── Snapshot rows ─────────────────────────────────────────────── */

typedef struct { uint32_t oid; char *nspname; } NsRow;
DEFINE_ARR(NsArr, NsRow)

typedef struct {
    uint32_t oid;
    char *schema;
    char *typname;
    const char *typtype;   /* "domain" | "composite" | "enum" */
    uint32_t typbasetype;
    uint32_t typelem;
    uint32_t typrelid;
} TypeRow;
DEFINE_ARR(TypeArr, TypeRow)

typedef struct {
    uint32_t oid; char *relname; uint32_t relnamespace;
    const char *relkind;   /* "compositeType" | "ordinaryTable" */
    uint32_t reltype;
} RelRow;
DEFINE_ARR(RelArr, RelRow)

typedef struct {
    uint32_t attrelid; char *attname; uint32_t atttypid;
    int attnum; int attnotnull;
} AttrRow;
DEFINE_ARR(AttrArr, AttrRow)

typedef struct {
    uint32_t oid; char *proname; uint32_t pronamespace;
    uint32_t prorettype;
    uint32_t *proargtypes; size_t n_proargtypes;
    char **proargnames; size_t n_proargnames;
    const char **proargmodes; size_t n_proargmodes;   /* empty if all IN */
    int proretset;
} ProcRow;
DEFINE_ARR(ProcArr, ProcRow)

typedef struct {
    uint32_t type_oid;
    char **labels; size_t n_labels;
} EnumRow;
DEFINE_ARR(EnumArr, EnumRow)

typedef struct {
    uint32_t next_oid;
    NsArr namespaces;        /* pg_catalog + public seeded; user-added rows tracked separately for emit order */
    TypeArr types;
    RelArr relations;
    AttrArr attributes;
    ProcArr procs;
    EnumArr enums;
    /* user namespaces in insertion order, for stable emit */
    char **user_ns; size_t n_user_ns, cap_user_ns;
} Snapshot;

static void snap_init(Snapshot *s) {
    s->next_oid = 16384;
    NsArr_init(&s->namespaces);
    TypeArr_init(&s->types);
    RelArr_init(&s->relations);
    AttrArr_init(&s->attributes);
    ProcArr_init(&s->procs);
    EnumArr_init(&s->enums);
    s->user_ns = NULL; s->n_user_ns = 0; s->cap_user_ns = 0;

    NsRow *pg = NsArr_push(&s->namespaces);
    pg->oid = 11; pg->nspname = strdup("pg_catalog");
    NsRow *pu = NsArr_push(&s->namespaces);
    pu->oid = 2200; pu->nspname = strdup("public");
}

static uint32_t snap_alloc_oid(Snapshot *s) { return s->next_oid++; }

static uint32_t snap_ensure_namespace(Snapshot *s, const char *name) {
    for (size_t i = 0; i < s->namespaces.len; i++) {
        if (strcmp(s->namespaces.data[i].nspname, name) == 0)
            return s->namespaces.data[i].oid;
    }
    uint32_t oid = snap_alloc_oid(s);
    NsRow *row = NsArr_push(&s->namespaces);
    row->oid = oid; row->nspname = strdup(name);
    if (s->n_user_ns == s->cap_user_ns) {
        s->cap_user_ns = s->cap_user_ns ? s->cap_user_ns * 2 : ARR_INIT_CAP;
        s->user_ns = (char **)realloc(s->user_ns, s->cap_user_ns * sizeof(char *));
    }
    s->user_ns[s->n_user_ns++] = strdup(name);
    return oid;
}

static int snap_lookup_type_oid(Snapshot *s, const char *schema, const char *name) {
    /* Builtin: schema null or "pg_catalog". */
    if (!schema || strcmp(schema, "pg_catalog") == 0) {
        int b = builtin_oid_lookup(name);
        if (b >= 0) return b;
    }
    /* User type. */
    for (size_t i = 0; i < s->types.len; i++) {
        TypeRow *t = &s->types.data[i];
        if (schema && strcmp(t->schema, schema) == 0 && strcmp(t->typname, name) == 0)
            return (int)t->oid;
        if (!schema && strcmp(t->schema, "public") == 0 && strcmp(t->typname, name) == 0)
            return (int)t->oid;
    }
    return -1;
}

/* ─── Node-walk helpers ─────────────────────────────────────────── */

/* Extract strings from a `repeated Node` field where each Node carries
 * a String payload (qualified-name encoding). Returns count; out[i] must
 * be free()d. */
static size_t string_nodes_to_parts(PgQuery__Node **nodes, size_t n,
                                    char ***out) {
    char **arr = (char **)calloc(n, sizeof(char *));
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        if (nodes[i]->node_case == PG_QUERY__NODE__NODE_STRING) {
            arr[k++] = strdup(nodes[i]->string->sval ? nodes[i]->string->sval : "");
        }
    }
    *out = arr;
    return k;
}

static void free_parts(char **parts, size_t n) {
    for (size_t i = 0; i < n; i++) free(parts[i]);
    free(parts);
}

static int type_name_to_oid(Snapshot *s, PgQuery__TypeName *tn) {
    if (!tn || tn->n_names == 0) return -1;
    char **parts; size_t n = string_nodes_to_parts(tn->names, tn->n_names, &parts);
    int oid = -1;
    if (n == 1) {
        oid = snap_lookup_type_oid(s, NULL, parts[0]);
    } else if (n >= 2) {
        if (strcmp(parts[0], "pg_catalog") == 0) {
            oid = snap_lookup_type_oid(s, NULL, parts[1]);
        } else {
            oid = snap_lookup_type_oid(s, parts[0], parts[1]);
        }
    }
    free_parts(parts, n);
    return oid;
}

/* ─── Statement handlers ────────────────────────────────────────── */

static void handle_create_schema(Snapshot *s, PgQuery__CreateSchemaStmt *st) {
    if (st->schemaname && st->schemaname[0])
        snap_ensure_namespace(s, st->schemaname);
}

static void handle_create_domain(Snapshot *s, PgQuery__CreateDomainStmt *st) {
    char **parts; size_t n = string_nodes_to_parts(st->domainname, st->n_domainname, &parts);
    if (n == 0) { free_parts(parts, n); return; }
    const char *schema = n >= 2 ? parts[n - 2] : "public";
    const char *name   = parts[n - 1];
    snap_ensure_namespace(s, schema);
    int base_oid = type_name_to_oid(s, st->type_name);
    TypeRow *t = TypeArr_push(&s->types);
    t->oid = snap_alloc_oid(s);
    t->schema = strdup(schema);
    t->typname = strdup(name);
    t->typtype = "domain";
    t->typbasetype = base_oid >= 0 ? (uint32_t)base_oid : 0;
    t->typelem = 0; t->typrelid = 0;
    free_parts(parts, n);
}

static void handle_composite_type(Snapshot *s, PgQuery__CompositeTypeStmt *st) {
    if (!st->typevar || !st->typevar->relname) return;
    const char *schema = (st->typevar->schemaname && st->typevar->schemaname[0])
        ? st->typevar->schemaname : "public";
    const char *name = st->typevar->relname;
    uint32_t ns_oid = snap_ensure_namespace(s, schema);
    uint32_t type_oid = snap_alloc_oid(s);
    uint32_t rel_oid  = snap_alloc_oid(s);
    TypeRow *t = TypeArr_push(&s->types);
    t->oid = type_oid; t->schema = strdup(schema); t->typname = strdup(name);
    t->typtype = "composite"; t->typrelid = rel_oid;
    t->typbasetype = 0; t->typelem = 0;
    RelRow *r = RelArr_push(&s->relations);
    r->oid = rel_oid; r->relname = strdup(name);
    r->relnamespace = ns_oid; r->relkind = "compositeType"; r->reltype = type_oid;
    for (size_t i = 0; i < st->n_coldeflist; i++) {
        PgQuery__Node *cn = st->coldeflist[i];
        if (cn->node_case != PG_QUERY__NODE__NODE_COLUMN_DEF) continue;
        PgQuery__ColumnDef *cd = cn->column_def;
        if (!cd->colname) continue;
        int typoid = type_name_to_oid(s, cd->type_name);
        if (typoid < 0) continue;
        AttrRow *a = AttrArr_push(&s->attributes);
        a->attrelid = rel_oid; a->attname = strdup(cd->colname);
        a->atttypid = (uint32_t)typoid; a->attnum = (int)(i + 1); a->attnotnull = 1;
    }
}

static void handle_create_enum(Snapshot *s, PgQuery__CreateEnumStmt *st) {
    char **parts; size_t n = string_nodes_to_parts(st->type_name, st->n_type_name, &parts);
    if (n == 0) { free_parts(parts, n); return; }
    const char *schema = n >= 2 ? parts[n - 2] : "public";
    const char *name   = parts[n - 1];
    snap_ensure_namespace(s, schema);
    uint32_t oid = snap_alloc_oid(s);
    TypeRow *t = TypeArr_push(&s->types);
    t->oid = oid; t->schema = strdup(schema); t->typname = strdup(name);
    t->typtype = "enum";
    t->typbasetype = 0; t->typelem = 0; t->typrelid = 0;
    EnumRow *e = EnumArr_push(&s->enums);
    e->type_oid = oid; e->n_labels = 0;
    e->labels = (char **)calloc(st->n_vals, sizeof(char *));
    for (size_t i = 0; i < st->n_vals; i++) {
        if (st->vals[i]->node_case == PG_QUERY__NODE__NODE_STRING) {
            e->labels[e->n_labels++] = strdup(st->vals[i]->string->sval);
        }
    }
    free_parts(parts, n);
}

static int column_notnull(PgQuery__ColumnDef *cd) {
    for (size_t i = 0; i < cd->n_constraints; i++) {
        PgQuery__Node *cn = cd->constraints[i];
        if (cn->node_case != PG_QUERY__NODE__NODE_CONSTRAINT) continue;
        PgQuery__ConstrType ct = cn->constraint->contype;
        if (ct == PG_QUERY__CONSTR_TYPE__CONSTR_NOTNULL ||
            ct == PG_QUERY__CONSTR_TYPE__CONSTR_PRIMARY)
            return 1;
    }
    return 0;
}

static void handle_create_table(Snapshot *s, PgQuery__CreateStmt *st) {
    if (!st->relation || !st->relation->relname) return;
    const char *schema = (st->relation->schemaname && st->relation->schemaname[0])
        ? st->relation->schemaname : "public";
    const char *name = st->relation->relname;
    uint32_t ns_oid = snap_ensure_namespace(s, schema);
    uint32_t type_oid = snap_alloc_oid(s);
    uint32_t rel_oid = snap_alloc_oid(s);
    TypeRow *t = TypeArr_push(&s->types);
    t->oid = type_oid; t->schema = strdup(schema); t->typname = strdup(name);
    t->typtype = "composite"; t->typrelid = rel_oid;
    t->typbasetype = 0; t->typelem = 0;
    RelRow *r = RelArr_push(&s->relations);
    r->oid = rel_oid; r->relname = strdup(name);
    r->relnamespace = ns_oid; r->relkind = "ordinaryTable"; r->reltype = type_oid;
    int attnum = 0;
    for (size_t i = 0; i < st->n_table_elts; i++) {
        PgQuery__Node *en = st->table_elts[i];
        if (en->node_case != PG_QUERY__NODE__NODE_COLUMN_DEF) continue;
        PgQuery__ColumnDef *cd = en->column_def;
        if (!cd->colname) continue;
        int typoid = type_name_to_oid(s, cd->type_name);
        if (typoid < 0) continue;
        attnum++;
        AttrRow *a = AttrArr_push(&s->attributes);
        a->attrelid = rel_oid; a->attname = strdup(cd->colname);
        a->atttypid = (uint32_t)typoid; a->attnum = attnum;
        a->attnotnull = column_notnull(cd);
    }
}

static const char *arg_mode_name(PgQuery__FunctionParameterMode m) {
    switch (m) {
        case PG_QUERY__FUNCTION_PARAMETER_MODE__FUNC_PARAM_OUT:      return "out";
        case PG_QUERY__FUNCTION_PARAMETER_MODE__FUNC_PARAM_INOUT:    return "inout";
        case PG_QUERY__FUNCTION_PARAMETER_MODE__FUNC_PARAM_VARIADIC: return "variadic";
        case PG_QUERY__FUNCTION_PARAMETER_MODE__FUNC_PARAM_TABLE:    return "tableOut";
        case PG_QUERY__FUNCTION_PARAMETER_MODE__FUNC_PARAM_IN:
        case PG_QUERY__FUNCTION_PARAMETER_MODE__FUNC_PARAM_DEFAULT:
        default:                                                     return "in_";
    }
}

static void handle_create_function(Snapshot *s, PgQuery__CreateFunctionStmt *st) {
    char **parts; size_t n = string_nodes_to_parts(st->funcname, st->n_funcname, &parts);
    if (n == 0) { free_parts(parts, n); return; }
    const char *schema = n >= 2 ? parts[n - 2] : "public";
    const char *name   = parts[n - 1];
    uint32_t ns_oid = snap_ensure_namespace(s, schema);

    /* First pass: collect args/types/names/modes. */
    size_t cap = st->n_parameters;
    uint32_t *argtypes = (uint32_t *)calloc(cap ? cap : 1, sizeof(uint32_t));
    char **argnames    = (char **)calloc(cap ? cap : 1, sizeof(char *));
    const char **modes = (const char **)calloc(cap ? cap : 1, sizeof(const char *));
    size_t na = 0;
    int has_modes = 0;
    for (size_t i = 0; i < st->n_parameters; i++) {
        PgQuery__Node *pn = st->parameters[i];
        if (pn->node_case != PG_QUERY__NODE__NODE_FUNCTION_PARAMETER) continue;
        PgQuery__FunctionParameter *p = pn->function_parameter;
        int t = type_name_to_oid(s, p->arg_type);
        argtypes[na] = t >= 0 ? (uint32_t)t : 2249 /* record sentinel */;
        argnames[na] = strdup(p->name ? p->name : "");
        modes[na]    = arg_mode_name(p->mode);
        if (strcmp(modes[na], "in_") != 0) has_modes = 1;
        na++;
    }
    int rettype = type_name_to_oid(s, st->return_type);
    int retset  = (st->return_type && st->return_type->setof) ? 1 : 0;

    ProcRow *pr = ProcArr_push(&s->procs);
    pr->oid = snap_alloc_oid(s);
    pr->proname = strdup(name);
    pr->pronamespace = ns_oid;
    pr->prorettype = rettype >= 0 ? (uint32_t)rettype : 2278 /* void */;
    pr->proargtypes = argtypes; pr->n_proargtypes = na;
    pr->proargnames = argnames; pr->n_proargnames = na;
    pr->proargmodes = has_modes ? modes : NULL;
    pr->n_proargmodes = has_modes ? na : 0;
    if (!has_modes) free(modes);
    pr->proretset = retset;
    free_parts(parts, n);
}

/* ─── ViewStmt: CREATE VIEW <name> AS SELECT ... ────────────────────
 *
 * View columns are inferred from the SELECT's target list. We
 * extract column NAMES from each ResTarget (either the explicit
 * AS alias or the last component of a ColumnRef expression) and
 * register attributes with `unknown` type (OID 2249 = record
 * sentinel). The emit pipeline turns 2249 into `z.unknown()`,
 * so downstream consumers get the right column structure with
 * loose value types — enough to use the view; insufficient for
 * strict per-column type checking until proper SELECT-target
 * inference lands.
 */
static const char *res_target_column_name(PgQuery__ResTarget *rt) {
    /* Explicit `AS alias` */
    if (rt->name && rt->name[0]) return rt->name;
    /* Bare `tbl.col` or `col` — pull the last identifier */
    if (!rt->val) return NULL;
    if (rt->val->node_case != PG_QUERY__NODE__NODE_COLUMN_REF) return NULL;
    PgQuery__ColumnRef *cr = rt->val->column_ref;
    if (cr->n_fields == 0) return NULL;
    PgQuery__Node *last = cr->fields[cr->n_fields - 1];
    if (last->node_case == PG_QUERY__NODE__NODE_STRING) {
        return last->string->sval;
    }
    return NULL;  /* A_Star or other — skipped */
}

static void handle_view_stmt(Snapshot *s, PgQuery__ViewStmt *st) {
    if (!st->view || !st->view->relname) return;
    const char *schema = (st->view->schemaname && st->view->schemaname[0])
        ? st->view->schemaname : "public";
    const char *name = st->view->relname;
    uint32_t ns_oid = snap_ensure_namespace(s, schema);

    /* If a view by this schema.name already exists (CREATE OR REPLACE
     * VIEW), skip — we keep the first registration. The snapshot
     * fold is order-sensitive but idempotent on repeated declarations. */
    for (size_t i = 0; i < s->types.len; i++) {
        if (strcmp(s->types.data[i].schema, schema) == 0 &&
            strcmp(s->types.data[i].typname, name) == 0) {
            return;
        }
    }

    uint32_t type_oid = snap_alloc_oid(s);
    uint32_t rel_oid  = snap_alloc_oid(s);
    TypeRow *t = TypeArr_push(&s->types);
    t->oid = type_oid; t->schema = strdup(schema); t->typname = strdup(name);
    t->typtype = "composite"; t->typrelid = rel_oid;
    t->typbasetype = 0; t->typelem = 0;
    RelRow *r = RelArr_push(&s->relations);
    r->oid = rel_oid; r->relname = strdup(name);
    r->relnamespace = ns_oid; r->relkind = "view"; r->reltype = type_oid;

    /* The query is wrapped in a Node; expect SelectStmt. */
    if (!st->query || st->query->node_case != PG_QUERY__NODE__NODE_SELECT_STMT)
        return;
    PgQuery__SelectStmt *sel = st->query->select_stmt;
    int attnum = 0;
    for (size_t i = 0; i < sel->n_target_list; i++) {
        PgQuery__Node *tn = sel->target_list[i];
        if (tn->node_case != PG_QUERY__NODE__NODE_RES_TARGET) continue;
        const char *cn = res_target_column_name(tn->res_target);
        if (!cn) continue;
        attnum++;
        AttrRow *a = AttrArr_push(&s->attributes);
        a->attrelid = rel_oid;
        a->attname  = strdup(cn);
        a->atttypid = 2249;  /* unknown — emit pipeline produces z.unknown() */
        a->attnum   = attnum;
        a->attnotnull = 0;   /* views project nullable-by-default */
    }
}

/* ─── AlterTableStmt: ADD/DROP COLUMN, SET/DROP NOT NULL ────────────
 *
 * Mutates the in-progress snapshot. Looks up the target relation by
 * (schema, name), then applies each AlterTableCmd. Unsupported cmd
 * kinds (ADD CONSTRAINT, RENAME, OWNER, etc.) are silently skipped —
 * none affect codegen-relevant column structure.
 */
static int find_relation_by_name(const Snapshot *s,
                                 const char *schema,
                                 const char *name,
                                 uint32_t *out_rel_oid) {
    for (size_t i = 0; i < s->relations.len; i++) {
        const RelRow *r = &s->relations.data[i];
        const char *r_schema = NULL;
        for (size_t j = 0; j < s->namespaces.len; j++) {
            if (s->namespaces.data[j].oid == r->relnamespace) {
                r_schema = s->namespaces.data[j].nspname;
                break;
            }
        }
        if (r_schema && strcmp(r_schema, schema) == 0 &&
            strcmp(r->relname, name) == 0) {
            *out_rel_oid = r->oid;
            return 1;
        }
    }
    return 0;
}

static AttrRow *find_attribute(Snapshot *s, uint32_t rel_oid, const char *name) {
    for (size_t i = 0; i < s->attributes.len; i++) {
        AttrRow *a = &s->attributes.data[i];
        if (a->attrelid == rel_oid && strcmp(a->attname, name) == 0)
            return a;
    }
    return NULL;
}

static int max_attnum_for(Snapshot *s, uint32_t rel_oid) {
    int max = 0;
    for (size_t i = 0; i < s->attributes.len; i++) {
        AttrRow *a = &s->attributes.data[i];
        if (a->attrelid == rel_oid && a->attnum > max) max = a->attnum;
    }
    return max;
}

static void handle_alter_table(Snapshot *s, PgQuery__AlterTableStmt *st) {
    if (!st->relation || !st->relation->relname) return;
    const char *schema = (st->relation->schemaname && st->relation->schemaname[0])
        ? st->relation->schemaname : "public";
    uint32_t rel_oid;
    if (!find_relation_by_name(s, schema, st->relation->relname, &rel_oid))
        return;

    for (size_t i = 0; i < st->n_cmds; i++) {
        PgQuery__Node *cn = st->cmds[i];
        if (cn->node_case != PG_QUERY__NODE__NODE_ALTER_TABLE_CMD) continue;
        PgQuery__AlterTableCmd *cmd = cn->alter_table_cmd;

        switch (cmd->subtype) {
            case PG_QUERY__ALTER_TABLE_TYPE__AT_AddColumn: {
                if (!cmd->def ||
                    cmd->def->node_case != PG_QUERY__NODE__NODE_COLUMN_DEF) break;
                PgQuery__ColumnDef *cd = cmd->def->column_def;
                if (!cd->colname) break;
                int typoid = type_name_to_oid(s, cd->type_name);
                if (typoid < 0) break;
                AttrRow *a = AttrArr_push(&s->attributes);
                a->attrelid = rel_oid;
                a->attname  = strdup(cd->colname);
                a->atttypid = (uint32_t)typoid;
                a->attnum   = max_attnum_for(s, rel_oid) + 1;
                a->attnotnull = column_notnull(cd);
                break;
            }
            case PG_QUERY__ALTER_TABLE_TYPE__AT_DropColumn: {
                if (!cmd->name) break;
                /* Mark the row as removed by zeroing attrelid. The
                 * emit loop filters by attrelid match, so a 0
                 * attrelid never matches the dropped relation. */
                AttrRow *a = find_attribute(s, rel_oid, cmd->name);
                if (a) a->attrelid = 0;
                break;
            }
            case PG_QUERY__ALTER_TABLE_TYPE__AT_SetNotNull: {
                if (!cmd->name) break;
                AttrRow *a = find_attribute(s, rel_oid, cmd->name);
                if (a) a->attnotnull = 1;
                break;
            }
            case PG_QUERY__ALTER_TABLE_TYPE__AT_DropNotNull: {
                if (!cmd->name) break;
                AttrRow *a = find_attribute(s, rel_oid, cmd->name);
                if (a) a->attnotnull = 0;
                break;
            }
            default:
                /* ADD CONSTRAINT / RENAME / OWNER / etc — skipped. */
                break;
        }
    }
}

static int dispatch_stmt(Snapshot *s, PgQuery__Node *node) {
    switch (node->node_case) {
        case PG_QUERY__NODE__NODE_CREATE_SCHEMA_STMT:
            handle_create_schema(s, node->create_schema_stmt); return 1;
        case PG_QUERY__NODE__NODE_CREATE_DOMAIN_STMT:
            handle_create_domain(s, node->create_domain_stmt); return 1;
        case PG_QUERY__NODE__NODE_COMPOSITE_TYPE_STMT:
            handle_composite_type(s, node->composite_type_stmt); return 1;
        case PG_QUERY__NODE__NODE_CREATE_ENUM_STMT:
            handle_create_enum(s, node->create_enum_stmt); return 1;
        case PG_QUERY__NODE__NODE_CREATE_STMT:
            handle_create_table(s, node->create_stmt); return 1;
        case PG_QUERY__NODE__NODE_CREATE_FUNCTION_STMT:
            handle_create_function(s, node->create_function_stmt); return 1;
        case PG_QUERY__NODE__NODE_VIEW_STMT:
            handle_view_stmt(s, node->view_stmt); return 1;
        case PG_QUERY__NODE__NODE_ALTER_TABLE_STMT:
            handle_alter_table(s, node->alter_table_stmt); return 1;
        default:
            return 0;
    }
}

/* ─── File I/O ──────────────────────────────────────────────────── */

static unsigned char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "pgpb_to_snapshot: %s: %s\n", path, strerror(errno)); return NULL; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    unsigned char *buf = (unsigned char *)malloc((size_t)sz);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, (size_t)sz, f); fclose(f);
    *out_len = n; return buf;
}

/* ─── Lean emit ─────────────────────────────────────────────────── */

static void maybe_add(uint32_t oid, uint32_t *seen, size_t *n_seen) {
    if (!builtin_name_for_oid(oid)) return;
    for (size_t k = 0; k < *n_seen; k++) if (seen[k] == oid) return;
    if (*n_seen < 64) seen[(*n_seen)++] = oid;
}

static void emit_referenced_builtins(FILE *o, Snapshot *s, int *first_row) {
    uint32_t seen[64]; size_t n_seen = 0;
    for (size_t i = 0; i < s->types.len; i++)
        maybe_add(s->types.data[i].typbasetype, seen, &n_seen);
    for (size_t i = 0; i < s->attributes.len; i++) {
        if (s->attributes.data[i].attrelid == 0) continue;  /* dropped */
        maybe_add(s->attributes.data[i].atttypid, seen, &n_seen);
    }
    for (size_t i = 0; i < s->procs.len; i++) {
        maybe_add(s->procs.data[i].prorettype, seen, &n_seen);
        for (size_t j = 0; j < s->procs.data[i].n_proargtypes; j++)
            maybe_add(s->procs.data[i].proargtypes[j], seen, &n_seen);
    }
    /* Sort ascending. */
    for (size_t i = 0; i + 1 < n_seen; i++)
        for (size_t j = i + 1; j < n_seen; j++)
            if (seen[j] < seen[i]) { uint32_t t = seen[i]; seen[i] = seen[j]; seen[j] = t; }
    for (size_t i = 0; i < n_seen; i++) {
        uint32_t oid = seen[i];
        const char *nm = builtin_name_for_oid(oid);
        const char *typtype = builtin_is_pseudo(nm) ? ".pseudo" : ".base";
        const char *sep = *first_row ? "    [ " : "    , ";
        fprintf(o, "%s{ oid := " LE "%u" RE ", typname := \"%s\", "
                   "typnamespace := " LE "11" RE ", typtype := %s }\n",
                sep, oid, nm, typtype);
        *first_row = 0;
    }
}

static void emit_lean(FILE *o, Snapshot *s, const char *module_name) {
    fprintf(o, "/- Auto-generated by @rules_postgres//tools:pgpb_to_snapshot.\n"
               "   DO NOT EDIT BY HAND \xe2\x80\x94 regenerate from migration .sql files. -/\n\n");
    fprintf(o, "import Pg.Catalog.Snapshot\nimport Pg.Catalog.Tables\n\n");
    fprintf(o, "namespace %s\n\n", module_name);
    fprintf(o, "open Pg.Catalog\n\n");

    /* Enum labels side-table */
    fprintf(o, "/-- Enum labels by type OID, paired with the snapshot for use\n"
               "    with `catalogFromSnapshotWithEnums`. -/\n");
    fprintf(o, "def enumLabels : List (Oid .type \xc3\x97 List String) :=\n  [\n");
    for (size_t i = 0; i < s->enums.len; i++) {
        EnumRow *e = &s->enums.data[i];
        fprintf(o, "    (" LE "%u" RE ", [", e->type_oid);
        for (size_t k = 0; k < e->n_labels; k++) {
            fprintf(o, "%s\"%s\"", k ? ", " : "", e->labels[k]);
        }
        fprintf(o, "]),\n");
    }
    fprintf(o, "  ]\n\n");

    fprintf(o, "def snapshot : Snapshot where\n");

    /* Namespaces */
    fprintf(o, "  namespaces :=\n");
    fprintf(o, "    [ { oid := " LE "11" RE ",   nspname := \"pg_catalog\" }\n");
    fprintf(o, "    , { oid := " LE "2200" RE ", nspname := \"public\" }\n");
    for (size_t i = 0; i < s->n_user_ns; i++) {
        const char *ns = s->user_ns[i];
        uint32_t oid = 0;
        for (size_t j = 0; j < s->namespaces.len; j++)
            if (strcmp(s->namespaces.data[j].nspname, ns) == 0) {
                oid = s->namespaces.data[j].oid; break;
            }
        fprintf(o, "    , { oid := " LE "%u" RE ", nspname := \"%s\" }\n", oid, ns);
    }
    fprintf(o, "    ]\n");

    /* Types: builtins (sorted) + user types (insertion order) */
    fprintf(o, "  types :=\n");
    int first = 1;
    emit_referenced_builtins(o, s, &first);
    for (size_t i = 0; i < s->types.len; i++) {
        TypeRow *t = &s->types.data[i];
        uint32_t ns_oid = 0;
        for (size_t j = 0; j < s->namespaces.len; j++)
            if (strcmp(s->namespaces.data[j].nspname, t->schema) == 0) {
                ns_oid = s->namespaces.data[j].oid; break;
            }
        const char *sep = first ? "    [ " : "    , ";
        fprintf(o, "%s{ oid := " LE "%u" RE ", typname := \"%s\", "
                   "typnamespace := " LE "%u" RE ", typtype := .%s",
                sep, t->oid, t->typname, ns_oid, t->typtype);
        if (t->typrelid)   fprintf(o, ", typrelid := " LE "%u" RE "", t->typrelid);
        if (t->typbasetype) fprintf(o, ", typbasetype := " LE "%u" RE "", t->typbasetype);
        if (t->typelem)    fprintf(o, ", typelem := " LE "%u" RE "", t->typelem);
        fprintf(o, " }\n");
        first = 0;
    }
    if (first) fprintf(o, "    []\n"); else fprintf(o, "    ]\n");

    /* Relations */
    fprintf(o, "  relations :=\n");
    if (s->relations.len == 0) {
        fprintf(o, "    []\n");
    } else {
        for (size_t i = 0; i < s->relations.len; i++) {
            RelRow *r = &s->relations.data[i];
            const char *sep = i ? "    , " : "    [ ";
            fprintf(o, "%s{ oid := " LE "%u" RE ", relname := \"%s\", "
                       "relnamespace := " LE "%u" RE ", relkind := .%s, "
                       "reltype := " LE "%u" RE " }\n",
                    sep, r->oid, r->relname, r->relnamespace, r->relkind, r->reltype);
        }
        fprintf(o, "    ]\n");
    }

    /* Attributes. Rows with attrelid==0 are the dropped marker
     * from AlterTableStmt's AT_DropColumn — skip them so the
     * emitted snapshot matches post-ALTER reality. */
    fprintf(o, "  attributes :=\n");
    {
        int first = 1;
        for (size_t i = 0; i < s->attributes.len; i++) {
            AttrRow *a = &s->attributes.data[i];
            if (a->attrelid == 0) continue;
            const char *sep = first ? "    [ " : "    , ";
            fprintf(o, "%s{ attrelid := " LE "%u" RE ", attname := \"%s\", "
                       "atttypid := " LE "%u" RE ", attnum := %d, "
                       "attnotnull := %s }\n",
                    sep, a->attrelid, a->attname, a->atttypid, a->attnum,
                    a->attnotnull ? "true" : "false");
            first = 0;
        }
        if (first) fprintf(o, "    []\n");
        else       fprintf(o, "    ]\n");
    }

    /* Procs */
    fprintf(o, "  procs :=\n");
    if (s->procs.len == 0) {
        fprintf(o, "    []\n");
    } else {
        for (size_t i = 0; i < s->procs.len; i++) {
            ProcRow *p = &s->procs.data[i];
            const char *sep = i ? "    , " : "    [ ";
            fprintf(o, "%s{ oid := " LE "%u" RE ", proname := \"%s\", "
                       "pronamespace := " LE "%u" RE ", prokind := .function, "
                       "prosecdef := false, provolatile := .stable, "
                       "prorettype := " LE "%u" RE ", "
                       "proargtypes := [",
                    sep, p->oid, p->proname, p->pronamespace, p->prorettype);
            for (size_t j = 0; j < p->n_proargtypes; j++)
                fprintf(o, "%s" LE "%u" RE "", j ? ", " : "", p->proargtypes[j]);
            fprintf(o, "], proargnames := [");
            for (size_t j = 0; j < p->n_proargnames; j++)
                fprintf(o, "%s\"%s\"", j ? ", " : "", p->proargnames[j]);
            fprintf(o, "]");
            if (p->n_proargmodes) {
                fprintf(o, ", proargmodes := [");
                for (size_t j = 0; j < p->n_proargmodes; j++)
                    fprintf(o, "%s.%s", j ? ", " : "", p->proargmodes[j]);
                fprintf(o, "]");
            }
            if (p->proretset) fprintf(o, ", proretset := true");
            fprintf(o, " }\n");
        }
        fprintf(o, "    ]\n");
    }

    fprintf(o, "  roles := []\n\n");
    fprintf(o, "end %s\n", module_name);
}

/* ─── main ──────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    const char *module = NULL;
    const char *output = NULL;
    const char *format = "lean";
    int argi = 1;
    while (argi < argc) {
        if (strcmp(argv[argi], "--module") == 0 && argi + 1 < argc) {
            module = argv[++argi];
        } else if (strcmp(argv[argi], "--output") == 0 && argi + 1 < argc) {
            output = argv[++argi];
        } else if (strcmp(argv[argi], "--format") == 0 && argi + 1 < argc) {
            format = argv[++argi];
        } else if (argv[argi][0] != '-') {
            break;
        } else {
            fprintf(stderr, "pgpb_to_snapshot: unknown arg %s\n", argv[argi]);
            return 2;
        }
        argi++;
    }
    if (!module || !output || argi >= argc) {
        fprintf(stderr, "usage: pgpb_to_snapshot --module <NAME> --output <FILE> "
                        "[--format lean] <ast1.pgpb> [<ast2.pgpb> ...]\n");
        return 2;
    }
    if (strcmp(format, "lean") != 0) {
        fprintf(stderr, "pgpb_to_snapshot: --format %s not yet implemented\n", format);
        return 2;
    }

    Snapshot snap; snap_init(&snap);
    for (int i = argi; i < argc; i++) {
        size_t n = 0;
        unsigned char *buf = read_file(argv[i], &n);
        if (!buf) return 2;
        PgQuery__ParseResult *pr = pg_query__parse_result__unpack(NULL, n, buf);
        free(buf);
        if (!pr) {
            fprintf(stderr, "pgpb_to_snapshot: failed to unpack %s\n", argv[i]);
            return 2;
        }
        int consumed = 0;
        for (size_t k = 0; k < pr->n_stmts; k++) {
            if (pr->stmts[k]->stmt) consumed += dispatch_stmt(&snap, pr->stmts[k]->stmt);
        }
        fprintf(stderr, "  %s: %zu stmts, %d consumed\n", argv[i], pr->n_stmts, consumed);
        pg_query__parse_result__free_unpacked(pr, NULL);
    }

    FILE *out = fopen(output, "w");
    if (!out) {
        fprintf(stderr, "pgpb_to_snapshot: cannot open %s: %s\n", output, strerror(errno));
        return 2;
    }
    emit_lean(out, &snap, module);
    fclose(out);
    fprintf(stderr, "  wrote %s\n", output);
    return 0;
}
