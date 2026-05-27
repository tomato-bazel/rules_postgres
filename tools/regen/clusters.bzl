"""Single source of truth for Pg.Ir cluster metadata.

Every consumer that needs to iterate over the clusters — gate
test_suites, Gate 1 wiring in `lean/BUILD.bazel`, per-crate Gate 2
wiring in `rust/pg_<cluster>/BUILD.bazel`, Gate 3 wiring for clusters
with a C emit — reads `CLUSTERS` from this file rather than carrying
its own list.

Each entry is a struct describing one cluster. Field semantics:

  - `crate` (str): name of the crate under `rust/`, e.g. `pg_int4_arith`.
  - `c_base` (str): stem for the c_oracle files; `c_oracle/renamed_<base>.c`,
    `c_oracle/<base>.c` (textual header), and `tests/diff_<base>.rs`
    (override `diff_test` if the convention is broken).
  - `lean_module` (str): `Pg.Ir.Emit.<lean_module>` — the cluster's
    Rust-emitting Lean main and its `<lean_module>Common` companion.
  - `diff_test` (str | None): name of the Bazel `rust_test`, defaults
    to `diff_<c_base>`. `None` if no Gate 2 harness exists for this
    cluster (e.g. pg_timestamp_arith).
  - `lean_emit_c` (bool): whether the cluster has a `<lean_module>C`
    real-PG-headers Lean emit + a Gate 1 diff_test on the C output
    + an `<c_base>_emit.c` filegroup the Gate 3 wiring consumes.
  - `pg_source` (str | None): label of the real Postgres .c source
    this cluster's Gate 3 structurally diffs against. Set iff
    `lean_emit_c = True` and the Lean spec has been factored to emit
    real-PG-headers form. `None` for older clusters.
  - `gate3_fn_names` (list[str]): C function names whose AST subtrees
    Gate 3 compares per-cluster. Empty for non-Gate-3 clusters.
  - `gate1_extra_lean_srcs` (list[str]): additional Lean source paths
    (relative to `lean/`) for the Rust emit's `lean_emit` srcs list
    beyond the standard prelude. Used when cluster Common files
    import sibling cluster modules.
  - `lean_prelude` (str): `"old"` for the standard Pg.Ir.Cmp +
    Pg.Ir.Emit.Common prelude (every cluster except the three with
    a C-emit). `"minimal"` for the lighter prelude used by macaddr/
    tid/uuid (Types + Datum only — no Cmp, no Emit/Common).
  - `lean_no_cluster_common` (bool): True for the one cluster
    (`pg_int4_cmp`) that has no `<Cluster>Common` module — its
    Rust emit pulls from `Pg/Ir/Emit/Common.lean` directly.
  - `uses_palloc` (bool): rust_library depends on `//rust/pg_palloc`
    AND c_oracle depends on `//rust/pg_palloc:palloc_hdr` (header
    sharing across the Rust/C boundary).
  - `diff_test_uses_palloc` (bool): the diff_test's tests/diff_*.rs
    file imports `pg_palloc::MemoryContext` etc. (a superset of
    uses_palloc; some clusters only need the Rust-side dep).
  - `uses_libc` (bool): rust_library depends on `@crates//:libc`
    (used by macaddr/tid/uuid for `libc::memcmp`).
"""

CLUSTERS = [
    # ── Standard clusters: PG_IR_OLD_BASE prelude, Rust-only emit ─────
    struct(
        crate = "pg_int4_arith",
        c_base = "int4_arith",
        lean_module = "IntArith",
        diff_test = "diff_int4_arith",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_int4_bitwise",
        c_base = "int4_bitwise",
        lean_module = "IntBitwise",
        diff_test = "diff_int4_bitwise",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_int_casts",
        c_base = "int_casts",
        lean_module = "IntCasts",
        diff_test = "diff_int_casts",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_int4_cmp",
        c_base = "int4_cmp",
        lean_module = "IntCmp",
        diff_test = "diff_int4_cmp",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        # IntCmp.lean imports Pg/Ir/Emit/Common directly — no IntCmpCommon.
        lean_no_cluster_common = True,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_int4_div",
        # NB: crate name says int4_div but c_oracle files use int_div.
        c_base = "int_div",
        lean_module = "IntDiv",
        diff_test = "diff_int_div",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_int4_hash",
        c_base = "int4_hash",
        lean_module = "IntHash",
        diff_test = "diff_int4_hash",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_int4_unary",
        c_base = "int4_unary",
        lean_module = "IntUnary",
        diff_test = "diff_int4_unary",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_float_arith",
        c_base = "float_arith",
        lean_module = "FloatArith",
        diff_test = "diff_float_arith",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_float_to_int",
        c_base = "float_to_int",
        lean_module = "FloatToInt",
        diff_test = "diff_float_to_int",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_float_unary",
        c_base = "float_unary",
        lean_module = "FloatUnary",
        diff_test = "diff_float_unary",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_cash_arith",
        c_base = "cash_arith",
        lean_module = "CashArith",
        diff_test = "diff_cash_arith",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_date_arith",
        c_base = "date_arith",
        lean_module = "DateArith",
        diff_test = "diff_date_arith",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_timestamp_arith",
        c_base = "timestamp_arith",
        lean_module = "TimestampArith",
        # NB: no tests/diff_timestamp_arith.rs upstream — Gate 2 gap.
        diff_test = None,
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = True,
        diff_test_uses_palloc = False,
        uses_libc = False,
    ),
    struct(
        crate = "pg_interval",
        c_base = "interval",
        lean_module = "Interval",
        diff_test = "diff_interval",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = True,
        diff_test_uses_palloc = True,
        uses_libc = False,
    ),
    struct(
        crate = "pg_bytea",
        c_base = "bytea",
        lean_module = "Bytea",
        diff_test = "diff_bytea",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = True,
        diff_test_uses_palloc = True,
        uses_libc = False,
    ),
    struct(
        crate = "pg_text",
        c_base = "text",
        lean_module = "Text",
        diff_test = "diff_text",
        lean_emit_c = False,
        pg_source = None,
        gate3_fn_names = [],
        gate1_extra_lean_srcs = [],
        lean_prelude = "old",
        lean_no_cluster_common = False,
        uses_palloc = True,
        diff_test_uses_palloc = True,
        uses_libc = False,
    ),

    # ── Clusters with minimal prelude + real-PG-headers C emit ────────
    struct(
        crate = "pg_macaddr",
        c_base = "macaddr",
        lean_module = "Macaddr",
        diff_test = "diff_macaddr",
        lean_emit_c = True,
        pg_source = "@postgres_src//:src/backend/utils/adt/mac.c",
        gate3_fn_names = [
            "macaddr_eq",
            "macaddr_ne",
            "macaddr_lt",
            "macaddr_le",
            "macaddr_gt",
            "macaddr_ge",
            "macaddr_cmp",
            "hashmacaddr",
            "hashmacaddrextended",
        ],
        gate1_extra_lean_srcs = [],
        lean_prelude = "minimal",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = True,
    ),
    struct(
        crate = "pg_tid",
        c_base = "tid",
        lean_module = "Tid",
        diff_test = "diff_tid",
        lean_emit_c = True,
        pg_source = "@postgres_src//:src/backend/utils/adt/tid.c",
        gate3_fn_names = [
            "tideq",
            "tidne",
            "tidlt",
            "tidle",
            "tidgt",
            "tidge",
            "bttidcmp",
            "tidlarger",
            "tidsmaller",
            "hashtid",
            "hashtidextended",
        ],
        gate1_extra_lean_srcs = [],
        lean_prelude = "minimal",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = True,
    ),
    struct(
        crate = "pg_uuid",
        c_base = "uuid",
        lean_module = "Uuid",
        diff_test = "diff_uuid",
        lean_emit_c = True,
        pg_source = "@postgres_src//:src/backend/utils/adt/uuid.c",
        gate3_fn_names = [
            "uuid_eq",
            "uuid_ne",
            "uuid_lt",
            "uuid_le",
            "uuid_gt",
            "uuid_ge",
            "uuid_cmp",
            "uuid_hash",
            "uuid_hash_extended",
        ],
        gate1_extra_lean_srcs = [],
        lean_prelude = "minimal",
        lean_no_cluster_common = False,
        uses_palloc = False,
        diff_test_uses_palloc = False,
        uses_libc = True,
    ),
]

# Lookup by crate name.
CLUSTERS_BY_CRATE = {c.crate: c for c in CLUSTERS}

def cluster_for_package(pkg):
    """Return the cluster struct for the package at `pkg` (e.g. `rust/pg_uuid`).

    Used by `pg_ir_cluster()` to auto-detect which cluster a per-crate
    BUILD.bazel belongs to via `native.package_name()`.
    """
    if not pkg.startswith("rust/"):
        fail("expected package under rust/, got %s" % pkg)
    crate = pkg[len("rust/"):]
    if crate not in CLUSTERS_BY_CRATE:
        fail("no cluster registered for crate %s in tools/regen/clusters.bzl" % crate)
    return CLUSTERS_BY_CRATE[crate]
