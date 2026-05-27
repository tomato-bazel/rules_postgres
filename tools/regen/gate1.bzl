"""Gate 1 (regen idempotence) Bazel-native wiring.

Thin layer over rules_lean's `lean_regen_test` macro that knows how
to iterate the Pg.Ir cluster registry (`tools/regen/clusters.bzl`)
and generate one regen_test per (cluster, Rust emit) + one per
(cluster, C emit) for clusters that emit both.

Lives in its own .bzl file because `lean/BUILD.bazel` loads this
module, and `lean/BUILD.bazel` is the cross-repo entry point that
transitive consumers (e.g. Aion's lean_test targets) reach when they
list `@rules_postgres//lean:Pg/Ir/...lean` files in `srcs`. Loading
must NOT pull in `@rules_rust` (gated `dev_dependency = True` in
rules_postgres' MODULE.bazel — invisible to transitive consumers).
The Gate 2 + Gate 3 wiring that does depend on rules_rust lives in
`cluster.bzl` and is only loaded by `rust/pg_<crate>/BUILD.bazel`
files — themselves dev-only.

Generates per-cluster targets (one regen_test per emit) plus a
helper that derives the test_suite labels:

  - <name>_rs_emit       (lean_emit by lean_regen_test) Rust emit
  - gate1_<name>         (diff_test by lean_regen_test) Rust diff
  - <name>_c_emit        (clusters with a C oracle) C emit
  - gate1_<name>_c       (clusters with a C oracle) C diff
"""

load("@rules_lean//lean:lean.bzl", "lean_regen_test")

# Standard Pg.Ir prelude — the modules every Lean emit imports
# transitively before its cluster-specific files. Matches the
# `lean -o Pg/Ir/Types.olean ...; lean -o Pg/Ir/Datum.olean ...` pairs
# at the top of every regen-*.sh.
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
    if spec.gate1_extra_lean_srcs:
        srcs = srcs + list(spec.gate1_extra_lean_srcs)
    if not spec.lean_no_cluster_common:
        srcs.append("Pg/Ir/Emit/{}Common.lean".format(spec.lean_module))
    srcs.append("Pg/Ir/Emit/{}.lean".format(spec.lean_module))
    return srcs

def wire_all_gate1(clusters):
    """Generate one or two lean_regen_test()s per cluster.

    Must be called from `lean/BUILD.bazel` (lean_emit's srcs need to
    live in or under the calling package). For each spec, generates:

      - `gate1_<c_base>`       — diffs the Rust emit against the
                                 committed src/lib.rs.
      - `gate1_<c_base>_c`     — (if `spec.lean_emit_c`) diffs the
                                 PG-headers C emit against the
                                 committed `<c_base>_emit.c`.
    """
    for spec in clusters:
        srcs = _cluster_srcs(spec)
        # All cluster-side filegroups now live at //rust:<crate>_lib_rs
        # and //rust:<base>_emit_c (the per-crate BUILD.bazel files were
        # collapsed into //rust/BUILD.bazel via pg_ir_clusters()).
        rust_target = "//rust:{}_lib_rs".format(spec.crate)

        # Rust emit gate. Output filename ends in `.rs` so anyone
        # eyeballing bazel-bin/ sees the format.
        lean_regen_test(
            name = "gate1_{}".format(spec.c_base),
            srcs = srcs,
            entry = "Pg/Ir/Emit/{}.lean".format(spec.lean_module),
            expected = rust_target,
            out = "{}_rs_emit.rs".format(spec.c_base),
        )

        if spec.lean_emit_c:
            c_main = "Pg/Ir/Emit/{}C.lean".format(spec.lean_module)
            c_srcs = list(srcs) + [c_main]
            c_target = "//rust:{}_emit_c".format(spec.c_base)

            lean_regen_test(
                name = "gate1_{}_c".format(spec.c_base),
                srcs = c_srcs,
                entry = c_main,
                expected = c_target,
                out = "{}_c_emit.c".format(spec.c_base),
            )

def gate1_test_labels(clusters):
    """Return the list of `//lean:gate1_<name>{,_c}` labels for `:gate1_all`."""
    labels = []
    for spec in clusters:
        labels.append("//lean:gate1_{}".format(spec.c_base))
        if spec.lean_emit_c:
            labels.append("//lean:gate1_{}_c".format(spec.c_base))
    return sorted(labels)
