"""Gate 2 + Gate 3 cluster wiring (rules_rust + rules_lang).

Lives separately from `lean_emits.bzl` because this module loads
`@rules_rust` and `@rules_lang`, both of which rules_postgres
declares as `dev_dependency = True`. Loading is gated behind
`rust/BUILD.bazel` (itself dev-only), so cross-repo consumers that
only reach into `//lean:...` (via `lean_emits.bzl`) never trigger
this module's loads.

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

Lean → Rust/C emits (the build-time source of truth) live in
`lean_emits.bzl` — split out to keep `lean/BUILD.bazel` loadable by
cross-repo consumers without pulling in rules_rust.
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_lang//rules/c:rules.bzl", "c_ast_dump_single", "c_ast_struct_diff_test_suite")
load("@rules_rust//rust:defs.bzl", "rust_library", "rust_test")

# ─── Oracle shim codegen ──────────────────────────────────────────
#
# Generates the per-cluster `oracle_shim_<base>.c` file that combines
# what used to be the hand-written `renamed_<base>.c` (`#define <fn>
# <fn>_orig` preprocessor renames + `#include "<base>.c"`) and the
# hand-written `wrappers_<base>.c` (FFI `c_<fn>` re-exports calling
# the renamed body) into a single auto-generated translation unit.
#
# Drives off three new cluster-spec fields:
#   oracle_fn_names      — public fmgr fns the wrapper re-exports
#                          and that the vendored body publishes.
#   oracle_extra_renames — internal static helpers (e.g.,
#                          `uuid_internal_cmp`) that the body calls
#                          via the renamed names; renamed for
#                          consistency, NOT wrapped.
#   oracle_uses_ereport  — True if any wrapped fn calls ereport(),
#                          so the wrapper must setjmp() to catch the
#                          longjmp from the c_oracle_ereport.h shim.
#
# Per-cluster spec sets these; one write_file generates the .c. The
# vendored `<base>.c` stays hand-written (function bodies are
# byte-identical to real PG and aren't generatable).

_SHIM_PREAMBLE_BASE = [
    "/* AUTO-GENERATED — see oracle_fn_names in tools/regen/clusters.bzl. */",
    "/* Combines the old renamed_<base>.c + wrappers_<base>.c into one TU. */",
    "",
    "#include <stdint.h>",
    "#include <stdbool.h>",
]

_SHIM_PREAMBLE_TYPES = [
    "",
    "typedef uintptr_t Datum;",
    "typedef struct FunctionCallInfoBaseData FunctionCallInfoBaseData;",
]

_SHIM_EREPORT_TLS = [
    "",
    "/* TLS state used by c_oracle_ereport.h's ereport()/errcode() macros. */",
    "__thread jmp_buf fmgr_oracle_jmp;",
    "__thread uint32_t fmgr_oracle_last_errcode;",
]

# NB: no `extern Datum name##_orig(...)` decl in WRAP. The body
# `<base>.c` is `#include`-d earlier in the same TU, so the _orig
# names are already declared at this point. Adding an extern with a
# fixed signature would conflict with bodies that use a different
# parameter convention (e.g., `void *fcinfo_ptr`).
_WRAP_MACRO_PURE = [
    "",
    "#define WRAP(name) \\",
    "    Datum c_##name(FunctionCallInfoBaseData *fcinfo) { return name##_orig(fcinfo); }",
]

_WRAP_MACRO_EREPORT = [
    "",
    "#define WRAP(name) \\",
    "    Datum c_##name(FunctionCallInfoBaseData *fcinfo) { \\",
    "        if (setjmp(fmgr_oracle_jmp) != 0) return (Datum) 0; \\",
    "        return name##_orig(fcinfo); \\",
    "    }",
]

def _gen_oracle_shim(base, fn_names, extra_renames, uses_ereport):
    """Emit oracle_shim_<base>.c via write_file. Returns the target label."""
    rename_all = fn_names + extra_renames
    lines = list(_SHIM_PREAMBLE_BASE)
    if uses_ereport:
        lines.append("#include <setjmp.h>")
    lines += list(_SHIM_PREAMBLE_TYPES)
    if uses_ereport:
        lines += list(_SHIM_EREPORT_TLS)

    # Rename preprocessor defines + #include of the vendored body.
    lines.append("")
    lines += ["#define {fn} {fn}_orig".format(fn = fn) for fn in rename_all]
    lines += [
        "",
        "#include \"{}.c\"".format(base),
        "",
    ]
    lines += ["#undef {fn}".format(fn = fn) for fn in rename_all]

    # Wrappers: re-export the _orig symbols under c_<name>.
    lines += list(_WRAP_MACRO_EREPORT if uses_ereport else _WRAP_MACRO_PURE)
    lines.append("")
    lines += ["WRAP({})".format(fn) for fn in fn_names]
    lines += ["", "#undef WRAP", ""]

    target_name = base + "_shim_c"
    write_file(
        name = target_name,
        out = "c_oracle/{}_shim.c".format(base),
        content = lines,
        newline = "unix",
    )
    return ":" + target_name

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
    generated under `//rust:...` with the crate name as prefix. The
    hand-written source files live flat under `rust/c_oracle/` and
    `rust/tests/`; the Lean-emitted crate body comes from
    `//lean:<base>_rs_emit` at build time.

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

    # ── c_oracle cc_library. ──
    # Hand-written oracle code lives flat under `rust/c_oracle/` —
    # per-cluster subdirectories were collapsed once Lean became the
    # source of truth for the Rust + emit C files. What's left is a
    # uniform 3-file pattern keyed by `<base>`: the vendored real-PG
    # body (textual_hdr, `#include`-d by the renamed file), the
    # renaming wrapper (orig_<fn> shim), and the FFI wrappers
    # (c_<fn> WRAP() expansions).
    cc_deps = ["//rust/pg_fcinfo:ereport_hdr"]
    if spec.uses_palloc:
        cc_deps.append("//rust/pg_palloc:palloc_hdr")

    # Per-cluster oracle shim. If the cluster spec defines
    # `oracle_fn_names`, we generate the renamed+wrappers shim from
    # those at build time (via write_file). Otherwise fall back to
    # the legacy pair of hand-written `renamed_<base>.c` +
    # `wrappers_<base>.c` files in `rust/c_oracle/`.
    fn_names = getattr(spec, "oracle_fn_names", [])
    if fn_names:
        shim = _gen_oracle_shim(
            base = base,
            fn_names = fn_names,
            extra_renames = getattr(spec, "oracle_extra_renames", []),
            uses_ereport = getattr(spec, "oracle_uses_ereport", False),
        )
        cc_srcs = [shim]
    else:
        cc_srcs = [
            "c_oracle/renamed_{}.c".format(base),
            "c_oracle/wrappers_{}.c".format(base),
        ]

    cc_library(
        name = crate + "_c_oracle",
        srcs = cc_srcs,
        textual_hdrs = ["c_oracle/{}.c".format(base)],
        # `c_oracle/` on the include path so the generated shim can
        # `#include "<base>.c"` and find the vendored body. The legacy
        # (non-generated) renamed_<base>.c worked without this because
        # it sat in the same dir as <base>.c; the generated shim lives
        # in bazel-out.
        includes = ["c_oracle"],
        deps = cc_deps,
    )

    # ── rust_library. The crate body is the Lean emit, produced at
    # build time by `//lean:<base>_rs_emit` — no committed `src/lib.rs`.
    rust_deps = ["//rust/pg_fcinfo"]
    if spec.uses_palloc:
        rust_deps.append("//rust/pg_palloc")
    if spec.uses_libc:
        rust_deps.append("@crates//:libc")

    rs_emit = "//lean:{}_rs_emit".format(base)
    rust_library(
        name = crate,
        crate_name = crate,
        srcs = [rs_emit],
        crate_root = rs_emit,
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
            srcs = ["tests/{}.rs".format(spec.diff_test)],
            edition = "2021",
            deps = test_deps,
        )

    # ── Gate 3 wiring. The Lean C emit is consumed directly from
    # `//lean:<base>_c_emit` — no committed `c_oracle/<base>_emit.c`.
    if spec.lean_emit_c and spec.pg_source and spec.gate3_fn_names:
        gate3_cluster(
            name = base,
            pg_source = spec.pg_source,
            lean_emit_c = "//lean:{}_c_emit".format(base),
            fn_names = spec.gate3_fn_names,
        )

def gate2_test_labels(clusters):
    """Collect the rust diff-test labels backing `:gate2_all`.

    Args:
      clusters: the list of cluster specs to collect diff_test labels from.

    Returns:
      Sorted `//rust:<diff_test>` labels plus pg_fcinfo's round_trip test
      (the foundation crate stays in its own package).
    """
    labels = ["//rust/pg_fcinfo:round_trip"]
    for spec in clusters:
        if spec.diff_test:
            labels.append("//rust:{}".format(spec.diff_test))
    return sorted(labels)

def gate3_test_labels(clusters):
    """Collect the `//rust:gate3_<base>` labels backing `:gate3_all`.

    Args:
      clusters: the list of cluster specs to collect gate3 labels from.

    Returns:
      Sorted `//rust:gate3_<base>` labels.
    """
    labels = []
    for spec in clusters:
        if spec.lean_emit_c and spec.pg_source and spec.gate3_fn_names:
            labels.append("//rust:gate3_{}".format(spec.c_base))
    return sorted(labels)
