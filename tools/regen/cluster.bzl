"""Bazel-native Pg.Ir cluster gate wiring.

Generates per-cluster `lean_emit` + `diff_test` pairs that together
implement Gate 1 (regen idempotence) without shelling out to host
`lean`. Each cluster gets:

  - <name>_rs_emit       lean_emit producing the Rust emit to stdout
  - gate1_<name>         diff_test asserting the committed src/lib.rs
                         matches the lean_emit output
  - <name>_c_emit        (clusters with a C oracle) lean_emit for the
                         real-PG-headers form
  - gate1_<name>_c       (clusters with a C oracle) diff_test for the
                         committed c_oracle/<cluster>_emit.c

Important: this macro MUST be invoked from `lean/BUILD.bazel`. The
underlying `lean_emit` rule strips the calling package prefix from
each src's short_path, so the srcs must live in (or under) the same
package as the rule. The lean/ tree is where they live.
"""

load("@bazel_skylib//rules:diff_test.bzl", "diff_test")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_lang//c:rules.bzl", "c_ast_dump_single", "c_ast_struct_diff_test_suite")
load("@rules_lean//lean:lean.bzl", "lean_emit")
load("@rules_rust//rust:defs.bzl", "rust_library", "rust_test")
load(":clusters.bzl", "cluster_for_package")

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

def gate1_cluster(
        name,
        rust_entry,
        rust_target,
        srcs,
        c_entry = None,
        c_target = None,
        c_extra_srcs = None):
    """Wire Gate 1 (regen idempotence) for one Pg.Ir cluster.

    Args:
      name: stem for generated targets (e.g., `int_arith`).
      rust_entry: package-relative path of the Rust-emitting Lean main
        (e.g., `Pg/Ir/Emit/IntArith.lean`).
      rust_target: Bazel label of the committed Rust emit
        (e.g., `//rust/pg_int4_arith:lib_rs`).
      srcs: ordered list of Lean source paths (relative to `lean/`)
        compiled by the Rust-emitting lean_emit. Order matters —
        lean_emit compiles them sequentially. Must include the entry.
      c_entry: optional package-relative path of the C-emitting Lean
        main (e.g., `Pg/Ir/Emit/UuidC.lean`). Only set for clusters
        that also emit a real-PG-headers C file.
      c_target: optional Bazel label of the committed C emit
        (e.g., `//rust/pg_uuid:uuid_emit_c`). Required when c_entry is set.
      c_extra_srcs: optional additional Lean srcs needed by the C
        emit beyond `srcs` (typically just `[<Cluster>C.lean]`).
    """
    rust_emit = name + "_rs_emit"

    lean_emit(
        name = rust_emit,
        srcs = srcs,
        entry = rust_entry,
        out = rust_emit + ".rs",
    )

    diff_test(
        name = "gate1_" + name,
        file1 = ":" + rust_emit,
        file2 = rust_target,
    )

    if c_entry:
        if not c_target:
            fail("c_target is required when c_entry is set")
        c_emit = name + "_c_emit"
        c_srcs = list(srcs) + (list(c_extra_srcs) if c_extra_srcs else [])

        lean_emit(
            name = c_emit,
            srcs = c_srcs,
            entry = c_entry,
            out = c_emit + ".c",
        )

        diff_test(
            name = "gate1_" + name + "_c",
            file1 = ":" + c_emit,
            file2 = c_target,
        )

# ─── Gate 3 — clang AST structural diff (Bazel-native) ────────────
#
# Per-cluster macro that wires up:
#   - c_ast_dump_single(<name>_lean_ast)   on the Lean-emit C (right)
#   - c_ast_dump_single(<name>_pg_ast)     on the real PG source (left)
#   - c_ast_struct_diff_test_suite(gate3_<name>)  per function in
#     `fn_names`. Test name pattern: `gate3_<name>_<fn_name>`.
#
# Both AST dumps depend on `@postgres_src//:pg_headers` and
# `@libpg_query//:pg_generated_headers` so postgres.h, utils/uuid.h,
# fmgrprotos.h, errcodes.h, etc. resolve identically on both sides.

def gate3_cluster(name, pg_source, lean_emit_c, fn_names):
    """Wire Gate 3 (clang AST structural diff) for one Pg.Ir cluster.

    Args:
      name: stem for generated targets (e.g., `uuid`).
      pg_source: Bazel label of the real Postgres source file
        (e.g., `@postgres_src//src/backend/utils/adt:uuid.c`).
      lean_emit_c: Bazel label of the Lean-emit real-PG-headers C
        file (e.g., `:uuid_emit_c`).
      fn_names: list of C function names whose AST subtrees the
        per-test suite structurally compares.
    """
    # libpg_query first — its `pg_config.h` defines INT64_MODIFIER and
    # other build-time-generated symbols, which postgres_src's overlay
    # pg_config.h does not. Search order matters for clang's `-I` chain.
    pg_deps = [
        "@libpg_query//:pg_generated_headers",
        "@postgres_src//:pg_headers",
    ]

    c_ast_dump_single(
        name = name + "_pg_ast",
        src = pg_source,
        deps = pg_deps,
    )

    c_ast_dump_single(
        name = name + "_lean_ast",
        src = lean_emit_c,
        deps = pg_deps,
    )

    c_ast_struct_diff_test_suite(
        name = "gate3_" + name,
        left = ":" + name + "_pg_ast",
        right = ":" + name + "_lean_ast",
        fn_names = fn_names,
    )

# ─── pg_ir_cluster — single per-crate BUILD entry point ───────────
#
# Auto-detects which cluster the calling BUILD.bazel belongs to via
# `native.package_name()`, looks up its config in CLUSTERS, and
# generates all the Gate 2 (cc_library + rust_library + rust_test) +
# Gate 3 (clang AST struct diff suite) targets the crate needs.
#
# Per-crate BUILD.bazel collapses to:
#
#   load("//tools/regen:cluster.bzl", "pg_ir_cluster")
#   pg_ir_cluster()
#
# All cluster-specific variation (c_oracle filename base, palloc/libc
# deps, has-a-C-emit, function lists for Gate 3) flows from the entry
# in tools/regen/clusters.bzl.

def pg_ir_cluster():
    """Wire Gate 2 + Gate 3 for the cluster owning the current package."""
    spec = cluster_for_package(native.package_name())
    crate = spec.crate
    base = spec.c_base

    # ── c_oracle cc_library: renamed PG body + setjmp wrappers. ──
    cc_deps = ["//rust/pg_fcinfo:ereport_hdr"]
    if spec.uses_palloc:
        cc_deps.append("//rust/pg_palloc:palloc_hdr")

    cc_library(
        name = "c_oracle",
        srcs = [
            "c_oracle/renamed_{}.c".format(base),
            "c_oracle/wrappers.c",
        ],
        textual_hdrs = ["c_oracle/{}.c".format(base)],
        deps = cc_deps,
    )

    # ── rust_library: Lean-emitted Rust impl. ──
    rust_deps = ["//rust/pg_fcinfo"]
    if spec.uses_palloc:
        rust_deps.append("//rust/pg_palloc")
    if spec.uses_libc:
        rust_deps.append("@crates//:libc")

    rust_library(
        name = crate,
        srcs = ["src/lib.rs"],
        edition = "2021",
        deps = rust_deps,
    )

    # ── rust_test: behavioral diff harness. ──
    if spec.diff_test:
        test_deps = [
            ":c_oracle",
            ":" + crate,
            "//rust/pg_fcinfo",
            "@crates//:proptest",
        ]
        if spec.diff_test_uses_palloc:
            test_deps.append("//rust/pg_palloc")

        rust_test(
            name = spec.diff_test,
            srcs = ["tests/{}.rs".format(spec.diff_test)],
            edition = "2021",
            deps = test_deps,
        )

    # ── Filegroups for Gate 1 diff_test consumption. ──
    native.filegroup(
        name = "lib_rs",
        srcs = ["src/lib.rs"],
    )
    if spec.lean_emit_c:
        native.filegroup(
            name = "{}_emit_c".format(base),
            srcs = ["c_oracle/{}_emit.c".format(base)],
        )

    # ── Gate 3 wiring when the cluster has a C emit + a PG source. ──
    if spec.lean_emit_c and spec.pg_source and spec.gate3_fn_names:
        gate3_cluster(
            name = base,
            pg_source = spec.pg_source,
            lean_emit_c = ":{}_emit_c".format(base),
            fn_names = spec.gate3_fn_names,
        )

# ─── Iteration helpers consumed by lean/BUILD.bazel + tools/regen ──

def wire_all_gate1(clusters):
    """Generate gate1_cluster() per cluster from a centralized list.

    Must be called from `lean/BUILD.bazel` (lean_emit's srcs need to
    live in or under the calling package). Reads the prelude variant
    + cluster_common toggle + emit-c flags from each spec.
    """
    for spec in clusters:
        srcs = list(PG_IR_OLD_BASE if spec.lean_prelude == "old" else PG_IR_PRELUDE)
        if spec.gate1_extra_lean_srcs:
            srcs = srcs + list(spec.gate1_extra_lean_srcs)
        if not spec.lean_no_cluster_common:
            srcs.append("Pg/Ir/Emit/{}Common.lean".format(spec.lean_module))
        srcs.append("Pg/Ir/Emit/{}.lean".format(spec.lean_module))

        # Cluster name for gate1 targets — match the per-crate base
        # (so gate1_int_div pairs with diff_int_div, gate1_int_arith
        # with diff_int4_arith from pg_int4_arith, etc.).
        gate_name = spec.c_base

        rust_target = "//rust/{}:lib_rs".format(spec.crate)

        if spec.lean_emit_c:
            gate1_cluster(
                name = gate_name,
                rust_entry = "Pg/Ir/Emit/{}.lean".format(spec.lean_module),
                rust_target = rust_target,
                srcs = srcs,
                c_entry = "Pg/Ir/Emit/{}C.lean".format(spec.lean_module),
                c_target = "//rust/{}:{}_emit_c".format(spec.crate, spec.c_base),
                c_extra_srcs = ["Pg/Ir/Emit/{}C.lean".format(spec.lean_module)],
            )
        else:
            gate1_cluster(
                name = gate_name,
                rust_entry = "Pg/Ir/Emit/{}.lean".format(spec.lean_module),
                rust_target = rust_target,
                srcs = srcs,
            )

def gate1_test_labels(clusters):
    """Return the list of `//lean:gate1_<name>{,_c}` labels for `:gate1_all`."""
    labels = []
    for spec in clusters:
        labels.append("//lean:gate1_{}".format(spec.c_base))
        if spec.lean_emit_c:
            labels.append("//lean:gate1_{}_c".format(spec.c_base))
    return sorted(labels)

def gate2_test_labels(clusters):
    """Return the list of `//rust/<crate>:<diff_test>` labels for `:gate2_all`,
    plus the pg_fcinfo round_trip test (always part of Gate 2)."""
    labels = ["//rust/pg_fcinfo:round_trip"]
    for spec in clusters:
        if spec.diff_test:
            labels.append("//rust/{}:{}".format(spec.crate, spec.diff_test))
    return sorted(labels)

def gate3_test_labels(clusters):
    """Return the list of `//rust/<crate>:gate3_<base>` labels for `:gate3_all`."""
    labels = []
    for spec in clusters:
        if spec.lean_emit_c and spec.pg_source and spec.gate3_fn_names:
            labels.append("//rust/{}:gate3_{}".format(spec.crate, spec.c_base))
    return sorted(labels)
