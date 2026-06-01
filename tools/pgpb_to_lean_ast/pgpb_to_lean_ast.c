/*
 * pgpb_to_lean_ast — emit Lean source values of Pg.Query.ParseResult
 * from a .pgpb byte payload.
 *
 * The trust-chain leg per the design doc §7 (b):
 *
 *   .sql ─sql_to_protobuf─► .pgpb ─pgpb_to_lean_ast─► .lean
 *                                                       │ leanc
 *                                                       ▼
 *                                       Pg.Query.ParseResult value
 *
 * The emitted .lean imports `Pg.Query.Generated` (Phase 2's stubbed
 * DDL slice) and defines a single `def parseResult : ParseResult`
 * matching the byte payload. Lean kernel-checks that the value
 * inhabits the generated type — if pgpb_to_lean_ast's output is
 * malformed (mis-encoded ByteArray literal, wrong field name, etc.)
 * the build breaks at this point.
 *
 * For each top-level Node payload, we re-pack the Node back to its
 * marshalled bytes via protobuf-c's `pg_query__node__pack`. The
 * stubbed Pg.Query.RawStmt has `stmt : ByteArray`, so the payload
 * is just the opaque bytes — consumers decode further on demand
 * (e.g. via a future pure-Lean proto-3 decoder, or by re-running
 * pgpb_to_lean_ast on a sub-payload with a different stub set).
 *
 * Exit codes:
 *   0  — emitted successfully
 *   1  — argv error
 *   2  — input read / unpack failure
 *
 * ~80% structure reuse from pgpb_to_snapshot.c (slurp, unpack,
 * top-level loop). The difference is the emit shape: opaque
 * ByteArray literals for each Node rather than walking each
 * stmt's typed fields.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pg_query.pb-c.h"

/* ─── File I/O ──────────────────────────────────────────────────── */

static unsigned char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "pgpb_to_lean_ast: %s: %s\n", path, strerror(errno));
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    unsigned char *buf = (unsigned char *)malloc((size_t)sz);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    *out_len = n;
    return buf;
}

/* ─── Lean ByteArray-literal emitter ────────────────────────────── */

/* Emit a Lean `_root_.ByteArray` literal from raw bytes.
 *
 * Format: `(⟨#[0xAB, 0xCD, ...]⟩ : ByteArray)` — wraps a
 * `UInt8` array via the `ByteArray.mk` anonymous-constructor
 * notation. For empty buffers, emit `ByteArray.empty` so the
 * generated value matches the generated structure's default.
 */
static void emit_bytearray_literal(FILE *o,
                                   const unsigned char *bytes,
                                   size_t len) {
    if (len == 0) {
        fputs("_root_.ByteArray.empty", o);
        return;
    }
    fputs("(\xe2\x9f\xa8#[", o);
    for (size_t i = 0; i < len; i++) {
        if (i) fputs(", ", o);
        fprintf(o, "0x%02X", bytes[i]);
    }
    fputs("]\xe2\x9f\xa9 : _root_.ByteArray)", o);
}

/* ─── Typed dispatch helpers ────────────────────────────────────── */

/* Extract the string `sval` field from a Node whose payload is a
 * String message. Returns NULL for non-String payloads. */
static const char *node_string(PgQuery__Node *n) {
    if (!n || n->node_case != PG_QUERY__NODE__NODE_STRING) return NULL;
    return n->string->sval;
}

/* Emit a Lean string literal with backslash-escaped quotes. */
static void emit_string_literal(FILE *o, const char *s) {
    fputc('"', o);
    for (const char *p = s; *p; p++) {
        if (*p == '"' || *p == '\\') fputc('\\', o);
        fputc(*p, o);
    }
    fputc('"', o);
}

/* Emit a `Pg.Query.Top.QualifiedName` value from a proto qualified-name
 * Node list (e.g. `["ids", "key_type"]`). */
static void emit_qualified_name(FILE *o,
                                PgQuery__Node **names, size_t n_names) {
    fputs("{ schema := ", o);
    if (n_names >= 2) {
        const char *schema = node_string(names[n_names - 2]);
        if (schema) {
            fputs("some ", o);
            emit_string_literal(o, schema);
        } else {
            fputs("none", o);
        }
    } else {
        fputs("none", o);
    }
    fputs(", name := ", o);
    const char *name = n_names >= 1 ? node_string(names[n_names - 1]) : NULL;
    emit_string_literal(o, name ? name : "");
    fputs(" }", o);
}

/* Typed emission for a top-level Node. Returns 1 if recognized
 * (emitted a `.<variant>` form), 0 if the caller should fall back
 * to `.other ⟨#[bytes]⟩`. */
static int emit_typed_top(FILE *o, PgQuery__Node *node) {
    if (!node) return 0;
    switch (node->node_case) {
        case PG_QUERY__NODE__NODE_CREATE_SCHEMA_STMT: {
            PgQuery__CreateSchemaStmt *st = node->create_schema_stmt;
            fputs(".createSchemaStmt { schemaname := ", o);
            emit_string_literal(o, st->schemaname ? st->schemaname : "");
            fprintf(o, ", ifNotExists := %s }",
                    st->if_not_exists ? "true" : "false");
            return 1;
        }
        case PG_QUERY__NODE__NODE_CREATE_ENUM_STMT: {
            PgQuery__CreateEnumStmt *st = node->create_enum_stmt;
            fputs(".createEnumStmt { qualName := ", o);
            emit_qualified_name(o, st->type_name, st->n_type_name);
            fputs(", labels := [", o);
            int first = 1;
            for (size_t i = 0; i < st->n_vals; i++) {
                const char *v = node_string(st->vals[i]);
                if (!v) continue;
                if (!first) fputs(", ", o);
                emit_string_literal(o, v);
                first = 0;
            }
            fputs("] }", o);
            return 1;
        }
        default:
            return 0;
    }
}

/* ─── ParseResult emission ──────────────────────────────────────── */

/* Emit a Node payload as an opaque ByteArray (the default mode). */
static void emit_node_as_bytes(FILE *o, PgQuery__Node *n) {
    if (!n) {
        fputs("_root_.ByteArray.empty", o);
        return;
    }
    size_t need = pg_query__node__get_packed_size(n);
    unsigned char *buf = (unsigned char *)malloc(need);
    if (!buf) {
        fputs("_root_.ByteArray.empty /- ENOMEM during pack -/", o);
        return;
    }
    size_t got = pg_query__node__pack(n, buf);
    emit_bytearray_literal(o, buf, got);
    free(buf);
}

static void emit_raw_stmt(FILE *o, const PgQuery__RawStmt *rs, int typed) {
    /* In default mode, emit `Pg.Query.RawStmt` with `stmt : ByteArray`.
     * In --typed mode, emit `Pg.Query.Top.TopRawStmt` with `stmt : TopStmt`. */
    fputs("    { stmt := ", o);
    if (typed) {
        if (!rs->stmt || !emit_typed_top(o, rs->stmt)) {
            /* Unrecognized stmt kind — wrap the bytes in .other. */
            fputs(".other ", o);
            emit_node_as_bytes(o, rs->stmt);
        }
    } else {
        emit_node_as_bytes(o, rs->stmt);
    }
    fprintf(o, ",\n      stmtLocation := %d,\n      stmtLen := %d }",
            rs->stmt_location, rs->stmt_len);
}

static void emit_parse_result(FILE *o, const PgQuery__ParseResult *pr,
                              const char *module_name,
                              int typed) {
    fprintf(o, "/- Auto-generated by @rules_postgres//tools:pgpb_to_lean_ast.\n"
               "   DO NOT EDIT BY HAND \xe2\x80\x94 regenerate from a .pgpb input. -/\n\n");
    if (typed) {
        fprintf(o, "import Pg.Query.Top\n\n");
        fprintf(o, "namespace %s\n\n", module_name);
        fprintf(o, "open Pg.Query.Top\n\n");
        fprintf(o, "/-- `TopParseResult` decoded from the input .pgpb bytes.\n"
                   "    The kernel typechecks each TopStmt variant against\n"
                   "    `Pg.Query.Top`; the catalog fold (`Pg.Catalog.Fold`)\n"
                   "    consumes this value to produce a `Pg.Catalog.Snapshot`. -/\n");
        fprintf(o, "def parseResult : TopParseResult where\n");
    } else {
        fprintf(o, "import Pg.Query.Generated\n\n");
        fprintf(o, "namespace %s\n\n", module_name);
        fprintf(o, "open Pg.Query\n\n");
        fprintf(o, "/-- `ParseResult` decoded from the input .pgpb bytes.\n"
                   "    The Lean kernel typechecks this value against the\n"
                   "    structure generated by `pgpb_codegen` \xe2\x80\x94 a malformed\n"
                   "    decoder output breaks the build at module load. -/\n");
        fprintf(o, "def parseResult : ParseResult where\n");
    }
    fprintf(o, "  version := %d\n", pr->version);

    if (pr->n_stmts == 0) {
        fprintf(o, "  stmts   := []\n");
    } else {
        fprintf(o, "  stmts   :=\n  [\n");
        for (size_t i = 0; i < pr->n_stmts; i++) {
            emit_raw_stmt(o, pr->stmts[i], typed);
            if (i + 1 < pr->n_stmts) fputs(",\n", o);
            else fputs("\n", o);
        }
        fprintf(o, "  ]\n");
    }
    fprintf(o, "\n");
    fprintf(o, "end %s\n", module_name);
}

/* ─── main ──────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    const char *module = NULL;
    const char *output = NULL;
    const char *input = NULL;
    int typed = 0;
    int argi = 1;
    while (argi < argc) {
        if (strcmp(argv[argi], "--module") == 0 && argi + 1 < argc) {
            module = argv[++argi];
        } else if (strcmp(argv[argi], "--output") == 0 && argi + 1 < argc) {
            output = argv[++argi];
        } else if (strcmp(argv[argi], "--typed") == 0) {
            typed = 1;
        } else if (argv[argi][0] != '-') {
            input = argv[argi];
        } else {
            fprintf(stderr, "pgpb_to_lean_ast: unknown arg %s\n", argv[argi]);
            return 1;
        }
        argi++;
    }
    if (!module || !output || !input) {
        fprintf(stderr, "usage: pgpb_to_lean_ast --module <NAME> "
                        "--output <FILE> [--typed] <input.pgpb>\n");
        return 1;
    }

    size_t n = 0;
    unsigned char *buf = read_file(input, &n);
    if (!buf) return 2;

    PgQuery__ParseResult *pr = pg_query__parse_result__unpack(NULL, n, buf);
    free(buf);
    if (!pr) {
        fprintf(stderr, "pgpb_to_lean_ast: failed to unpack %s\n", input);
        return 2;
    }

    FILE *out = fopen(output, "w");
    if (!out) {
        fprintf(stderr, "pgpb_to_lean_ast: cannot open %s: %s\n",
                output, strerror(errno));
        pg_query__parse_result__free_unpacked(pr, NULL);
        return 2;
    }

    emit_parse_result(out, pr, module, typed);
    fclose(out);
    fprintf(stderr, "  %s: %zu stmts \xe2\x86\x92 %s\n",
            input, pr->n_stmts, output);
    pg_query__parse_result__free_unpacked(pr, NULL);
    return 0;
}
