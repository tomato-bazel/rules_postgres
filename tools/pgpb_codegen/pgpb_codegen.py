#!/usr/bin/env python3
"""pgpb_codegen — proto → Lean inductive generator.

Reads libpg_query's `pg_query.proto` (as a protoc-emitted
`FileDescriptorSet`) and generates Lean source files matching the
proto's message and enum shape, ready to drop under
`@rules_postgres//lean:Pg/Query/Generated/`.

See `narrative/proto-to-lean-design-poc.md` in the consumer's repo
for the design rationale and the appendix POC showing target output.

Output (Phase 1):
  Generated.lean  — one file with everything inside one giant
                    `mutual ... end` block (the whole proto's
                    message universe is one SCC through `Node`).

Phase 2 will split into Primitives / Enums / Node / Expr / Stmt
sub-files once the single-file path is gated. Splitting requires
careful handling of `mutual` boundaries — Node references every
stmt and every expr.

Usage:

    # 1) emit the descriptor via protoc (run once or in a Bazel
    #    genrule; protoc is not bundled here):
    protoc --descriptor_set_out=/tmp/pgquery.desc \\
        --proto_path=<libpg_query>/protobuf \\
        <libpg_query>/protobuf/pg_query.proto

    # 2) generate Lean:
    python3 pgpb_codegen.py \\
        --descriptor /tmp/pgquery.desc \\
        --output lean/Pg/Query/Generated.lean

Skeleton Phase 1: ~600 LOC, no external deps beyond
`google.protobuf` runtime. Phase 2 wraps as a hermetic `py_binary`
under `rules_python` + `py_pip_install`.
"""

import argparse
import sys
from typing import Optional

try:
    from google.protobuf import descriptor_pb2
except ImportError:
    sys.stderr.write(
        "pgpb_codegen: google.protobuf not installed.\n"
        "Run: python3 -m pip install protobuf\n"
    )
    sys.exit(2)


# ─── Reserved-word / shadowing tables ──────────────────────────────

# Lean keywords that collide with common proto field names. Names
# matching these get a trailing underscore.
LEAN_KEYWORDS = frozenset({
    "do", "where", "match", "let", "in", "default", "end",
    "if", "then", "else", "with", "mutual", "fun", "by",
    "open", "import", "structure", "inductive", "namespace",
    "def", "theorem", "example", "lemma", "instance", "class",
    "deriving", "extends", "from", "into", "for", "while",
    "return", "have", "show", "sorry", "this", "Type", "Prop",
    "Sort", "true", "false", "abbrev", "axiom", "section",
    "variable", "universe", "private", "protected", "noncomputable",
    "public", "local", "partial", "unsafe", "forall", "exists",
    "syntax", "macro", "elab", "term", "tactic",
})

# Proto type names that shadow Lean's stdlib. Inside `namespace
# Pg.Query`, references to `String` / `Float` / etc. would resolve
# to `Pg.Query.String` (the generated structure) instead of the
# real stdlib. We emit `_root_.String` etc. in field types to
# disambiguate.
SHADOWED_TYPES = frozenset({"String", "Boolean", "Float", "Integer", "List", "Bool"})


# ─── Proto scalar → Lean type map ──────────────────────────────────

# Format: proto_field_type_enum → (lean_type, lean_default).
# All references are `_root_.`-qualified because inside `namespace
# Pg.Query`, proto messages named `Float` / `Boolean` / `List` /
# `Integer` shadow the stdlib types. Numerical types like `Int32`
# happen to not collide today, but `_root_.`-qualifying defensively
# costs nothing.
T = descriptor_pb2.FieldDescriptorProto
SCALAR_TYPES = {
    T.TYPE_DOUBLE:   ("_root_.Float",     "0.0"),
    # proto's `float` is 32-bit; Lean 4 only ships Float (64-bit).
    # Widen — none of pg_query's `float` fields need bit-exact
    # round-trip. Flagged in the design doc §9.5.
    T.TYPE_FLOAT:    ("_root_.Float",     "0.0"),
    T.TYPE_INT64:    ("_root_.Int64",     "0"),
    T.TYPE_UINT64:   ("_root_.UInt64",    "0"),
    T.TYPE_INT32:    ("_root_.Int32",     "0"),
    T.TYPE_FIXED64:  ("_root_.UInt64",    "0"),
    T.TYPE_FIXED32:  ("_root_.UInt32",    "0"),
    T.TYPE_BOOL:     ("_root_.Bool",      "false"),
    T.TYPE_STRING:   ("_root_.String",    '""'),
    T.TYPE_BYTES:    ("_root_.ByteArray", "_root_.ByteArray.empty"),
    T.TYPE_UINT32:   ("_root_.UInt32",    "0"),
    T.TYPE_SFIXED32: ("_root_.Int32",     "0"),
    T.TYPE_SFIXED64: ("_root_.Int64",     "0"),
    T.TYPE_SINT32:   ("_root_.Int32",     "0"),
    T.TYPE_SINT64:   ("_root_.Int64",     "0"),
}


# ─── Identifier munging ────────────────────────────────────────────

def snake_to_camel(s: str) -> str:
    """`foo_bar_baz` → `fooBarBaz`. First-letter lowercase."""
    parts = s.split("_")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])


def snake_to_pascal(s: str) -> str:
    """`foo_bar_baz` → `FooBarBaz`. First-letter uppercase."""
    parts = s.split("_")
    return "".join(p.capitalize() for p in parts)


def lean_field_name(proto_name: str) -> str:
    """Munge a proto field name → Lean field name (camelCase + kw escape)."""
    name = snake_to_camel(proto_name)
    if name in LEAN_KEYWORDS:
        return name + "_"
    return name


def lean_type_name(proto_name: str) -> str:
    """Munge a proto message/enum type name → Lean type name.

    `A_Expr`           → `AExpr`         (drop intra-name underscore)
    `A_Expr_Kind`      → `AExprKind`     (idem, repeated)
    `SQLValueFunction` → unchanged
    `pg_query.CreateStmt` → `CreateStmt` (strip package)

    Rule: drop fully-qualified prefix, then remove every `_`. Proto
    type names in pg_query.proto are uniformly PascalCase otherwise,
    so removing all underscores is sound and produces clean idents.
    """
    if "." in proto_name:
        proto_name = proto_name.rsplit(".", 1)[-1]
    return proto_name.replace("_", "")


def longest_common_prefix(strings: list[str]) -> str:
    """Longest common string prefix."""
    if not strings:
        return ""
    s = min(strings)
    e = max(strings)
    for i, c in enumerate(s):
        if i >= len(e) or c != e[i]:
            return s[:i]
    return s


def strip_enum_prefix(values: list[str]) -> tuple[list[str], str]:
    """Strip the longest common underscore-aligned prefix from enum values.

    `['FUNC_PARAM_IN', 'FUNC_PARAM_OUT']` → `(['IN', 'OUT'], 'FUNC_PARAM_')`
    `['CONSTR_NOTNULL', 'CONSTR_NULL']`   → `(['NOTNULL', 'NULL'], 'CONSTR_')`
    """
    if len(values) < 2:
        return values, ""
    p = longest_common_prefix(values)
    # Snap to the last underscore so we keep variant names whole.
    last_us = p.rfind("_")
    if last_us < 0:
        return values, ""
    real_prefix = p[:last_us + 1]
    return [v[len(real_prefix):] for v in values], real_prefix


def enum_variant_name(stripped: str) -> str:
    """Stripped enum value (UPPER_SNAKE) → Lean variant (camelCase + kw escape)."""
    name = snake_to_camel(stripped.lower())
    if name in LEAN_KEYWORDS:
        return name + "_"
    return name


# ─── Field-type rendering ──────────────────────────────────────────

def field_type_repr(field: descriptor_pb2.FieldDescriptorProto,
                    msg_names: set[str],
                    enum_defaults: dict[str, str],
                    stubs: Optional[dict[str, tuple[str, str]]] = None
                    ) -> tuple[str, str]:
    """Return (lean_type, lean_default) for a single field.

    Handles:
      * scalars                 → from SCALAR_TYPES
      * enum                    → `<EnumName>`, default `.<defaultVariant>`
      * message singular        → `_root_.Option <MsgName>`, default `none`
      * repeated scalar/message → `_root_.List <T>`, default `[]`

    `enum_defaults` maps enum type names → the default variant
    (lower-camel). Pre-computed once per descriptor walk so we can
    resolve cross-references regardless of definition order.
    """
    is_repeated = (field.label == T.LABEL_REPEATED)

    # Resolve the field's element type first.
    # We use `_root_.List` and `_root_.Option` consistently because
    # `Pg.Query.List` is a generated structure (the proto's `message
    # List { ... }`) that would shadow the stdlib `List` inside the
    # `namespace Pg.Query` block. Same reasoning for any other
    # shadowed type.
    if field.type == T.TYPE_MESSAGE:
        msg_name = lean_type_name(field.type_name)
        # Stub substitution: if this type has been stubbed (e.g.
        # `Node → _root_.ByteArray` to break the proto's universal
        # SCC), use the replacement (lean_type, lean_default).
        if stubs and msg_name in stubs:
            elt_t, elt_default = stubs[msg_name]
            if is_repeated:
                return (f"_root_.List {elt_t}", "[]")
            else:
                # Stubbed singular submessage: just the stub type
                # directly (no Option wrap — the stub already
                # encodes presence).
                return (elt_t, elt_default)
        if is_repeated:
            return (f"_root_.List {msg_name}", "[]")
        else:
            return (f"_root_.Option {msg_name}", "none")
    elif field.type == T.TYPE_ENUM:
        enum_name = lean_type_name(field.type_name)
        if is_repeated:
            return (f"_root_.List {enum_name}", "[]")
        default_variant = enum_defaults.get(enum_name, "undefined")
        return (enum_name, f".{default_variant}")
    elif field.type in SCALAR_TYPES:
        lean_t, default = SCALAR_TYPES[field.type]
        if is_repeated:
            return (f"_root_.List {lean_t}", "[]")
        return (lean_t, default)
    else:
        return ("Unit", "()")


# ─── Lean emission ─────────────────────────────────────────────────

def emit_enum(out: list[str], enum: descriptor_pb2.EnumDescriptorProto) -> None:
    """Emit `inductive <Name>` for one enum descriptor.

    pg_query.proto convention: value 0 is `<ENUM_NAME>_UNDEFINED` —
    uses the enum-type prefix, NOT the shared variant prefix.
    Skip value 0 when computing the common prefix, then always
    emit it as the `.undefined` variant.
    """
    name = lean_type_name(enum.name)
    raw_values = [v.name for v in enum.value]

    # Separate the UNDEFINED sentinel from the real variants for
    # prefix detection. If only the sentinel exists, no stripping.
    has_undefined = (len(raw_values) > 0 and raw_values[0].endswith("_UNDEFINED"))
    real_values = raw_values[1:] if has_undefined else raw_values
    stripped_real, _ = strip_enum_prefix(real_values)

    out.append(f"inductive {name} where")
    for raw, val in zip(raw_values, enum.value):
        if has_undefined and raw == raw_values[0]:
            variant = "undefined"
        else:
            idx = (raw_values.index(raw) - (1 if has_undefined else 0))
            variant = enum_variant_name(stripped_real[idx])
        out.append(f"  | {variant:<18}  -- {val.number} ({raw})")
    out.append("deriving DecidableEq, Repr, Inhabited")
    out.append("")


def collect_message_oneofs(msg: descriptor_pb2.DescriptorProto):
    """Group fields by oneof index. Returns (regular_fields, oneofs)."""
    regulars = []
    oneofs: dict[int, list] = {}
    for f in msg.field:
        if f.HasField("oneof_index"):
            oneofs.setdefault(f.oneof_index, []).append(f)
        else:
            regulars.append(f)
    return regulars, oneofs


def emit_message_structure(out: list[str],
                           msg: descriptor_pb2.DescriptorProto,
                           msg_names: set[str],
                           enum_defaults: dict[str, str],
                           stubs: Optional[dict[str, tuple[str, str]]] = None
                           ) -> None:
    """Emit a `structure` for a message with no oneofs (or for the
    non-oneof part of a mixed message — Phase 2 will handle mixed)."""
    name = lean_type_name(msg.name)
    regulars, oneofs = collect_message_oneofs(msg)

    if oneofs and not regulars:
        # Pure-oneof: emit as inductive. Used by Node.
        out.append(f"inductive {name} where")
        # Iterate oneofs in declaration order
        for oi in sorted(oneofs.keys()):
            for f in oneofs[oi]:
                variant = lean_field_name(f.name)
                # Singular submessage → ctor takes a single payload
                if f.type == T.TYPE_MESSAGE:
                    payload = lean_type_name(f.type_name)
                    out.append(f"  | {variant:<28} : {payload} → {name}")
                elif f.type == T.TYPE_ENUM:
                    payload = lean_type_name(f.type_name)
                    out.append(f"  | {variant:<28} : {payload} → {name}")
                elif f.type in SCALAR_TYPES:
                    payload, _ = SCALAR_TYPES[f.type]
                    out.append(f"  | {variant:<28} : {payload} → {name}")
                else:
                    out.append(f"  | {variant:<28} : Unit → {name}")
        out.append("-- deriving Inhabited (deferred — expensive in mutual blocks)")
        out.append("")
        return

    # Mixed oneof + scalars is rare in pg_query.proto; the only
    # message that has both is `A_Const` (oneof `val` + `bool isnull`
    # + `int32 location`). Phase 1 handles this by emitting a flat
    # structure where the oneof becomes an `Option <oneofName>Choice`
    # field with an inner inductive. For Phase 1, emit as if
    # everything is regular and skip the oneof choice — we'll add
    # mixed handling in a follow-up.

    out.append(f"structure {name} where")
    # Emit regular fields
    for f in regulars:
        fname = lean_field_name(f.name)
        ftype, default = field_type_repr(f, msg_names, enum_defaults, stubs)
        out.append(f"  {fname:<18} : {ftype:<28} := {default}")
    # Emit oneof fields as Option <variant> for each (loose Phase 1
    # encoding; design doc §9 leaves the precise oneof structure as
    # a Phase 2 refinement when we have a full Lean kernel typechecking
    # the generated output).
    for oi in sorted(oneofs.keys()):
        for f in oneofs[oi]:
            fname = lean_field_name(f.name)
            ftype, default = field_type_repr(f, msg_names, enum_defaults, stubs)
            # Wrap oneof scalar fields in Option to model
            # explicit-presence.
            if f.type in SCALAR_TYPES:
                ftype = f"Option {ftype.replace(' ', '_')}" if " " in ftype else f"Option {ftype}"
                default = "none"
            out.append(f"  {fname:<18} : {ftype:<28} := {default}")
    out.append("-- deriving Inhabited (deferred — expensive in mutual blocks)")
    out.append("")


# ─── Topological clustering ────────────────────────────────────────

def message_dep_names(msg: descriptor_pb2.DescriptorProto) -> set[str]:
    """Return the set of OTHER message type names this message refers to."""
    deps = set()
    for f in msg.field:
        if f.type == T.TYPE_MESSAGE:
            deps.add(lean_type_name(f.type_name))
    return deps


def topo_sort_messages(messages: list[descriptor_pb2.DescriptorProto]
                       ) -> list[descriptor_pb2.DescriptorProto]:
    """Topologically sort messages so cleaner messages come before
    messages that reference them. For the FULL proto with `Node` as
    the universal hub, everything ends up in one SCC and we emit
    them in a single `mutual` block regardless — so this is a hint
    for readability, not a correctness requirement."""
    by_name = {lean_type_name(m.name): m for m in messages}
    visited: set[str] = set()
    out: list[descriptor_pb2.DescriptorProto] = []

    def visit(msg_name: str) -> None:
        if msg_name in visited or msg_name not in by_name:
            return
        visited.add(msg_name)
        for dep in message_dep_names(by_name[msg_name]):
            visit(dep)
        out.append(by_name[msg_name])

    for m in messages:
        visit(lean_type_name(m.name))
    return out


# ─── Reachability filter ───────────────────────────────────────────

def reachable_types(roots: list[str],
                    all_messages: list,
                    all_enums: list,
                    stubs: Optional[dict[str, tuple[str, str]]] = None
                    ) -> tuple[set[str], set[str]]:
    """Compute the transitive closure of types reachable from `roots`.

    Returns (reachable_message_names, reachable_enum_names).

    A message is "reachable" if it's in roots or referenced by any
    reachable message's fields (as a message or enum type). The
    closure traverses through `Node`'s oneof variants — the full
    proto's SCC — so passing `{ParseResult, Node}` as roots
    effectively means "everything", whereas `{CreateSchemaStmt}`
    selects just one stmt + its building blocks.
    """
    msg_by_name = {lean_type_name(m.name): m for m in all_messages}
    enum_by_name = {lean_type_name(e.name): e for e in all_enums}

    reachable_msgs: set[str] = set()
    reachable_enums: set[str] = set()
    queue = list(roots)

    while queue:
        name = queue.pop()
        if name in reachable_msgs or name not in msg_by_name:
            continue
        reachable_msgs.add(name)
        msg = msg_by_name[name]
        for f in msg.field:
            if f.type == T.TYPE_MESSAGE:
                ref = lean_type_name(f.type_name)
                # Stubbed types are terminal — the field becomes the
                # stub's Lean type (e.g. ByteArray); we don't follow
                # the stub's transitive references.
                if stubs and ref in stubs:
                    continue
                queue.append(ref)
            elif f.type == T.TYPE_ENUM:
                ename = lean_type_name(f.type_name)
                if ename in enum_by_name:
                    reachable_enums.add(ename)

    return reachable_msgs, reachable_enums


# ─── Phase 1 entry: emit one big Generated.lean ────────────────────

LEAN_FILE_HEADER = """\
-- AUTO-GENERATED by @rules_postgres//tools:pgpb_codegen.
-- Source: pg_query.proto @ libpg_query {version}.
-- Re-run: bazel run @rules_postgres//tools/pgpb_codegen:regenerate
-- DO NOT EDIT BY HAND.

namespace Pg.Query
"""


def emit_lean(file_set: descriptor_pb2.FileDescriptorSet,
              version: str,
              roots: Optional[list[str]] = None,
              stubs: Optional[dict[str, tuple[str, str]]] = None) -> str:
    out: list[str] = []
    out.append(LEAN_FILE_HEADER.format(version=version))

    # Gather all messages + enums across all files (pg_query.proto
    # is a single file but the descriptor format generalizes).
    all_messages: list[descriptor_pb2.DescriptorProto] = []
    all_enums: list[descriptor_pb2.EnumDescriptorProto] = []
    for f in file_set.file:
        all_messages.extend(f.message_type)
        all_enums.extend(f.enum_type)

    # Filter to the transitive closure if roots are specified.
    if roots:
        rmsgs, renums = reachable_types(roots, all_messages, all_enums, stubs)
        all_messages = [m for m in all_messages if lean_type_name(m.name) in rmsgs]
        all_enums = [e for e in all_enums if lean_type_name(e.name) in renums]
        sys.stderr.write(
            f"  pgpb_codegen: filter to {len(roots)} roots → "
            f"{len(all_messages)} messages, {len(all_enums)} enums reachable"
            f"{' (with ' + str(len(stubs)) + ' stub(s))' if stubs else ''}\n"
        )

    msg_names: set[str] = {lean_type_name(m.name) for m in all_messages}

    # Pre-compute each enum's default variant name. Used by
    # `field_type_repr` to emit `.<variant>` defaults that refer to
    # a constructor that actually exists (some enums lack the
    # `*_UNDEFINED` 0-value sentinel — Token, KeywordKind, etc.).
    enum_defaults: dict[str, str] = {}
    for e in all_enums:
        name = lean_type_name(e.name)
        raw0 = e.value[0].name if e.value else ""
        if raw0.endswith("_UNDEFINED"):
            enum_defaults[name] = "undefined"
        else:
            raw_values = [v.name for v in e.value]
            stripped, _ = strip_enum_prefix(raw_values)
            enum_defaults[name] = enum_variant_name(stripped[0]) if stripped else "undefined"

    # ── Enums first (no mutual; enums never reference messages) ──
    if all_enums:
        out.append("")
        out.append("/-! ## Enums -/")
        out.append("")
        for e in all_enums:
            emit_enum(out, e)

    # ── Messages in one giant mutual block ──
    sorted_messages = topo_sort_messages(all_messages)
    if sorted_messages:
        out.append("/-! ## Messages -/")
        out.append("")
        out.append("mutual")
        out.append("")
        for m in sorted_messages:
            emit_message_structure(out, m, msg_names, enum_defaults, stubs)
        out.append("end  -- mutual")
        out.append("")

    out.append("end Pg.Query")
    return "\n".join(out)


# ─── CLI ───────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="pgpb_codegen")
    ap.add_argument("--descriptor", required=True,
                    help="path to protoc-emitted FileDescriptorSet (.desc)")
    ap.add_argument("--output", required=True,
                    help="path to write Generated.lean")
    ap.add_argument("--version", default="unknown",
                    help="libpg_query release tag, embedded in the header")
    ap.add_argument("--roots", default=None,
                    help="comma-separated message names to scope the closure "
                         "(e.g. 'ParseResult,CreateSchemaStmt'). Omit to emit "
                         "the full proto surface.")
    ap.add_argument("--stub", action="append", default=[],
                    help="message stub: 'Name=LeanType:default'. Every "
                         "reference to <Name> becomes <LeanType>, and "
                         "reachability stops at it. Used to break the proto's "
                         "universal SCC — e.g. "
                         "'--stub Node=_root_.ByteArray:_root_.ByteArray.empty' "
                         "makes Node an opaque payload so stmts compile as "
                         "plain structures. Repeat for multiple stubs.")
    args = ap.parse_args(argv[1:])

    roots = args.roots.split(",") if args.roots else None
    stubs: dict[str, tuple[str, str]] = {}
    for spec in args.stub:
        # Format: "Name=LeanType:default" — split on '=' then ':'.
        try:
            name, rest = spec.split("=", 1)
            lean_type, default = rest.rsplit(":", 1)
            stubs[name.strip()] = (lean_type.strip(), default.strip())
        except ValueError:
            sys.stderr.write(f"  pgpb_codegen: bad --stub spec: {spec!r}\n")
            sys.stderr.write(f"    expected 'Name=LeanType:default'\n")
            return 2

    with open(args.descriptor, "rb") as f:
        data = f.read()
    file_set = descriptor_pb2.FileDescriptorSet()
    file_set.ParseFromString(data)

    n_msgs = sum(len(fd.message_type) for fd in file_set.file)
    n_enums = sum(len(fd.enum_type) for fd in file_set.file)
    sys.stderr.write(
        f"  pgpb_codegen: {n_msgs} messages, {n_enums} enums "
        f"across {len(file_set.file)} files\n"
    )

    src = emit_lean(file_set, args.version, roots=roots,
                    stubs=stubs if stubs else None)
    with open(args.output, "w") as f:
        f.write(src + "\n")
    sys.stderr.write(f"  wrote {args.output} ({src.count(chr(10))} lines)\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
