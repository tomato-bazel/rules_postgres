"""Gate 2 + Gate 3 cluster wiring (rules_rust + rules_lang).

Lives separately from `gate1.bzl` because this module loads
`@rules_rust` and `@rules_lang`, both of which rules_postgres
declares as `dev_dependency = True`. Loading is gated behind
`rust/pg_<crate>/BUILD.bazel` files (themselves dev-only), so
cross-repo consumers that only reach into `//lean:...` (via
`gate1.bzl`) never trigger this module's loads.

Public surface:

  - `pg_ir_cluster()` — single per-crate BUILD entry point that
    generates the cc_library(c_oracle) + rust_library + rust_test +
    filegroups + optional Gate 3 wiring for the cluster owning the
    calling package (looked up by `native.package_name()`).
  - `gate3_cluster(name, pg_source, lean_emit_c, fn_names)` — direct
    Gate 3 wiring for ad-hoc usage outside the standard cluster
    layout. Invoked transitively by `pg_ir_cluster()` when the spec
    has `lean_emit_c = True`.
  - `gate2_test_labels(clusters)` / `gate3_test_labels(clusters)` —
    iteration helpers used by `tools/regen/BUILD.bazel` to populate
    the `gate2_all` / `gate3_all` test_suite `tests` lists.

Gate 1 (regen idempotence) lives in `gate1.bzl` — split out to keep
`lean/BUILD.bazel` loadable by cross-repo consumers without pulling
in rules_rust.
"""

load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_lang//c:rules.bzl", "c_ast_dump_single", "c_ast_struct_diff_test_suite")
load("@rules_rust//rust:defs.bzl", "rust_library", "rust_test")

def gate3_cluster(name, pg_source, lean_emit_c, fn_names):
    """Wire Gate 3 (clang AST structural diff) for one Pg.Ir cluster.

    Args:
      name: stem for generated targets (e.g., `uuid`).
      pg_source: Bazel label of the real Postgres source file
        (e.g., `@postgres_src//:src/backend/utils/adt/uuid.c`).
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
#   package(default_visibility = ["//visibility:public"])
#   pg_ir_cluster()
#
# All cluster-specific variation (c_oracle filename base, palloc/libc
# deps, has-a-C-emit, function lists for Gate 3) flows from the entry
# in `tools/regen/clusters.bzl`.

def pg_ir_clusters(clusters):
    """Wire Gate 2 + Gate 3 for ALL Pg.Ir clusters from a centralized list.

    Called once from `rust/BUILD.bazel`. Every per-cluster target is
    generated under `//rust:...` with the crate name as prefix — no
    per-crate `rust/pg_<crate>/BUILD.bazel` needed. The cluster source
    files (`c_oracle/*.c`, `src/lib.rs`, `tests/diff_*.rs`) live in
    their subdirectories under rust/ as plain files, addressed by
    relative path from `//rust`.

    Naming scheme (all targets in `//rust`):
      - <crate>                          = rust_library
      - <crate>_c_oracle                 = cc_library wrapping c_oracle/*.c
      - <diff_test>                      = rust_test (name from spec)
      - <crate>_lib_rs                   = filegroup over src/lib.rs
      - <base>_emit_c                    = filegroup over c_oracle/<base>_emit.c
      - gate3_<base>_<fn>                = c_ast_struct_diff_test per fn

    Args:
      clusters: list of cluster struct entries from CLUSTERS in
        tools/regen/clusters.bzl.
    """
    for spec in clusters:
        _wire_cluster(spec)

def _wire_cluster(spec):
    crate = spec.crate
    base = spec.c_base
    sub = crate + "/"  # subdir prefix for file paths

    # ── c_oracle cc_library. ──
    cc_deps = ["//rust/pg_fcinfo:ereport_hdr"]
    if spec.uses_palloc:
        cc_deps.append("//rust/pg_palloc:palloc_hdr")

    cc_library(
        name = crate + "_c_oracle",
        srcs = [
            sub + "c_oracle/renamed_{}.c".format(base),
            sub + "c_oracle/wrappers.c",
        ],
        textual_hdrs = [sub + "c_oracle/{}.c".format(base)],
        deps = cc_deps,
    )

    # ── rust_library. ──
    rust_deps = ["//rust/pg_fcinfo"]
    if spec.uses_palloc:
        rust_deps.append("//rust/pg_palloc")
    if spec.uses_libc:
        rust_deps.append("@crates//:libc")

    rust_library(
        name = crate,
        crate_name = crate,
        srcs = [sub + "src/lib.rs"],
        edition = "2021",
        deps = rust_deps,
    )

    # ── rust_test (Gate 2 behavioral). ──
    if spec.diff_test:
        test_deps = [
            ":" + crate + "_c_oracle",
            ":" + crate,
            "//rust/pg_fcinfo",
            "@crates//:proptest",
        ]
        if spec.diff_test_uses_palloc:
            test_deps.append("//rust/pg_palloc")

        rust_test(
            name = spec.diff_test,
            srcs = [sub + "tests/{}.rs".format(spec.diff_test)],
            edition = "2021",
            deps = test_deps,
        )

    # ── Filegroups for Gate 1 diff_test consumption. ──
    native.filegroup(
        name = crate + "_lib_rs",
        srcs = [sub + "src/lib.rs"],
    )
    if spec.lean_emit_c:
        native.filegroup(
            name = "{}_emit_c".format(base),
            srcs = [sub + "c_oracle/{}_emit.c".format(base)],
        )

    # ── Gate 3 wiring. ──
    if spec.lean_emit_c and spec.pg_source and spec.gate3_fn_names:
        gate3_cluster(
            name = base,
            pg_source = spec.pg_source,
            lean_emit_c = ":{}_emit_c".format(base),
            fn_names = spec.gate3_fn_names,
        )

def gate2_test_labels(clusters):
    """Return `//rust:<diff_test>` labels for `:gate2_all`, plus pg_fcinfo's
    round_trip test (the foundation crate stays in its own package)."""
    labels = ["//rust/pg_fcinfo:round_trip"]
    for spec in clusters:
        if spec.diff_test:
            labels.append("//rust:{}".format(spec.diff_test))
    return sorted(labels)

def gate3_test_labels(clusters):
    """Return `//rust:gate3_<base>` labels for `:gate3_all`."""
    labels = []
    for spec in clusters:
        if spec.lean_emit_c and spec.pg_source and spec.gate3_fn_names:
            labels.append("//rust:gate3_{}".format(spec.c_base))
    return sorted(labels)
