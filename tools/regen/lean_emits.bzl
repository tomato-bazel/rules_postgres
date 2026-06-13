"""Pg.Ir Lean → Rust/C emit wiring (Bazel-native, no committed artifacts).

For each Pg.Ir cluster, generates `lean_emit` targets that produce the
cluster's Rust crate (`<base>_rs_emit.rs`) and — for clusters with a
real-PG-headers C emit — the C file (`<base>_c_emit.c`). Consumers
(`rust_library`, Gate 3's `c_ast_dump_single`) reference those
generated outputs directly instead of going through committed
`src/lib.rs` / `c_oracle/<base>_emit.c` files.

This replaces the old `Gate 1 — regen idempotence` flow: with Lean as
the live source of truth at build time, there is no committed
artifact for regen to drift against, so the check is tautological.
Gate 2 (cargo behavioral diff against real PG bodies) and Gate 3
(clang AST struct diff against real PG source) remain the
verification surface.

Cross-repo loading note: this module is loaded by `lean/BUILD.bazel`,
which is the entry point cross-repo consumers reach (e.g. Aion's
lean_test targets that list `@rules_postgres//lean:Pg/Ir/...lean`
files in srcs). It MUST NOT load `@rules_rust` — that's gated behind
`dev_dependency = True` in rules_postgres' MODULE.bazel and is
invisible to transitive consumers. Gate 2 + Gate 3 wiring that needs
rules_rust lives in `cluster.bzl`, loaded only by `rust/BUILD.bazel`.
"""

load("@rules_lean//lean:lean.bzl", "lean_emit")

# Standard Pg.Ir prelude — modules every Lean emit imports
# transitively before its cluster-specific files.
PG_IR_PRELUDE = [
    "Pg/Ir/Types.lean",
    "Pg/Ir/Datum.lean",
]

# Older clusters (everything except macaddr/tid/uuid) also import
# Pg/Ir/Cmp.lean + Pg/Ir/Emit/Common.lean before their cluster modules.
PG_IR_OLD_BASE = PG_IR_PRELUDE + [
    "Pg/Ir/Cmp.lean",
    "Pg/Ir/Emit/Common.lean",
]

def _cluster_srcs(spec):
    """Build the ordered Lean srcs list for one cluster's Rust emit."""
    srcs = list(PG_IR_OLD_BASE if spec.lean_prelude == "old" else PG_IR_PRELUDE)
    if spec.extra_lean_srcs:
        srcs = srcs + list(spec.extra_lean_srcs)
    if not spec.lean_no_cluster_common:
        srcs.append("Pg/Ir/Emit/{}Common.lean".format(spec.lean_module))
    srcs.append("Pg/Ir/Emit/{}.lean".format(spec.lean_module))
    return srcs

def wire_all_lean_emits(clusters):
    """Generate `lean_emit` targets for every Pg.Ir cluster.

    Must be called from `lean/BUILD.bazel` — `lean_emit.srcs` must
    live in or under the calling package. For each spec, generates:

      - `<c_base>_rs_emit` — Rust crate body (file `<c_base>_rs_emit.rs`).
        Consumed by `//rust:<crate>` (rust_library.srcs).
      - `<c_base>_c_emit`  — (if `spec.lean_emit_c`) real-PG-headers C
        emit (file `<c_base>_c_emit.c`). Consumed by Gate 3's
        `c_ast_dump_single` for clang AST struct diff vs real PG.

    Args:
      clusters: the list of cluster specs to generate lean_emit targets for.
    """
    for spec in clusters:
        srcs = _cluster_srcs(spec)

        lean_emit(
            name = "{}_rs_emit".format(spec.c_base),
            srcs = srcs,
            entry = "Pg/Ir/Emit/{}.lean".format(spec.lean_module),
            out = "{}_rs_emit.rs".format(spec.c_base),
            visibility = ["//visibility:public"],
        )

        if spec.lean_emit_c:
            c_main = "Pg/Ir/Emit/{}C.lean".format(spec.lean_module)
            lean_emit(
                name = "{}_c_emit".format(spec.c_base),
                srcs = list(srcs) + [c_main],
                entry = c_main,
                out = "{}_c_emit.c".format(spec.c_base),
                visibility = ["//visibility:public"],
            )
