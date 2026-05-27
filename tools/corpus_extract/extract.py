#!/usr/bin/env python3
"""
Pg.Ir corpus extraction.

Walks `rules_postgres/rust/pg_*` clusters and emits a JSONL corpus
file. One record per cluster.

The cluster is the natural authoring unit for Pg.Ir — the Family
table in `<Cluster>Common.lean` enumerates all members at once.

See `README.md` for the record schema.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, field
from pathlib import Path

# ─── Mapping: crate dir → cluster shape + Lean module prefix ─────────
#
# Some crates are pure infrastructure (pg_fcinfo, pg_palloc, pgfnames,
# pg_finfo_v1, sha2, libpq_buf) — skip those. The Pg.Ir-emitted
# crates are listed here with their Lean module triplet.
#
# Format: crate_dir → (cluster_short, [Lean module file basenames],
# regen_script_basename, grounding_script_basename, cluster_shape).
PGIR_CLUSTERS: dict[str, dict] = {
    "pg_int4_cmp":      dict(short="int_cmp",        lean=["Common", "IntCmp", "IntCmpC"],
                              regen="regen-int-cmp.sh", grounding="check-int-cmp-grounding.sh",
                              shape="cmp"),
    "pg_int4_hash":     dict(short="int_hash",       lean=["IntHashCommon", "IntHash", "IntHashC"],
                              regen="regen-int-hash.sh", grounding="check-int-hash-grounding.sh",
                              shape="hash"),
    "pg_int4_arith":    dict(short="int_arith",      lean=["IntArithCommon", "IntArith", "IntArithC"],
                              regen="regen-int-arith.sh", grounding="check-int-arith-grounding.sh",
                              shape="arith-overflow-ereport"),
    "pg_interval":      dict(short="interval",       lean=["IntervalCommon", "Interval", "IntervalC"],
                              regen="regen-interval.sh", grounding="check-interval-grounding.sh",
                              shape="palloc-fixed-with-ereport"),
    "pg_int4_unary":    dict(short="int_unary",      lean=["IntUnaryCommon", "IntUnary", "IntUnaryC"],
                              regen="regen-int-unary.sh", grounding="check-int-unary-grounding.sh",
                              shape="unary-overflow-ereport"),
    "pg_int4_bitwise":  dict(short="int_bitwise",    lean=["IntBitwiseCommon", "IntBitwise", "IntBitwiseC"],
                              regen="regen-int-bitwise.sh", grounding="check-int-bitwise-grounding.sh",
                              shape="bitwise-pure"),
    "pg_bytea":         dict(short="bytea",          lean=["ByteaCommon", "Bytea", "ByteaC"],
                              regen="regen-bytea.sh", grounding="check-bytea-grounding.sh",
                              shape="palloc-varlena"),
    "pg_float_unary":   dict(short="float_unary",    lean=["FloatUnaryCommon", "FloatUnary", "FloatUnaryC"],
                              regen="regen-float-unary.sh", grounding="check-float-unary-grounding.sh",
                              shape="unary-float-no-error"),
    "pg_text":          dict(short="text",           lean=["TextCommon", "Text", "TextC"],
                              regen="regen-text.sh", grounding="check-text-grounding.sh",
                              shape="palloc-varlena"),
    "pg_int4_div":      dict(short="int_div",        lean=["IntDivCommon", "IntDiv", "IntDivC"],
                              regen="regen-int-div.sh", grounding="check-int-div-grounding.sh",
                              shape="arith-divbyzero-ereport"),
    "pg_float_arith":   dict(short="float_arith",    lean=["FloatArithCommon", "FloatArith", "FloatArithC"],
                              regen="regen-float-arith.sh", grounding="check-float-arith-grounding.sh",
                              shape="arith-checkfloatval-ereport"),
    "pg_cash_arith":    dict(short="cash_arith",     lean=["CashArithCommon", "CashArith", "CashArithC"],
                              regen="regen-cash-arith.sh", grounding="check-cash-arith-grounding.sh",
                              shape="arith-int64-helper-delegated"),
    "pg_date_arith":    dict(short="date_arith",     lean=["DateArithCommon", "DateArith", "DateArithC"],
                              regen="regen-date-arith.sh", grounding="check-date-arith-grounding.sh",
                              shape="arith-sentinel-ereport"),
    "pg_uuid":          dict(short="uuid",           lean=["UuidCommon", "Uuid", "UuidC"],
                              regen="regen-uuid.sh", grounding="check-uuid-grounding.sh",
                              shape="cmp-hash-fixed16"),
    "pg_macaddr":       dict(short="macaddr",        lean=["MacaddrCommon", "Macaddr", "MacaddrC"],
                              regen="regen-macaddr.sh", grounding="check-macaddr-grounding.sh",
                              shape="cmp-hash-fixed6"),
    "pg_int_casts":     dict(short="int_casts",      lean=["IntCastsCommon", "IntCasts", "IntCastsC"],
                              regen="regen-int-casts.sh", grounding="check-int-casts-grounding.sh",
                              shape="cast-int-with-overflow"),
    "pg_float_to_int":  dict(short="float_to_int",   lean=["FloatToIntCommon", "FloatToInt", "FloatToIntC"],
                              regen="regen-float-to-int.sh", grounding="check-float-to-int-grounding.sh",
                              shape="cast-float-to-int"),
}

# Crates that exist in rules_postgres/rust/ but are pure infrastructure
# or deferred — skip in corpus extraction.
SKIP_CRATES = {
    "pg_fcinfo",      # Datum codec + ereport infra
    "pg_palloc",      # MemoryContext + palloc
    "pgfnames",       # spike from earlier era
    "pg_finfo_v1",    # bulk-lifted stubs
    "sha2",           # hand-translation demo
    "libpq_buf",      # hand-translation demo
    "pg_timestamp_arith",  # deferred — needs datetime.c helpers
    "pg_tid",              # deferred — TID's packed struct layout (BlockIdData
                           # + OffsetNumber) hashes differently than the raw
                           # 6-byte sequence macaddr uses; needs a separate
                           # hash_bytes_tid that respects the struct layout
                           # or a pre-hash byte normalization step. Comparison
                           # ops work (2 tests pass); hashing fails (5 tests).
}


@dataclass
class ClusterRecord:
    cluster: str
    cluster_short: str
    cluster_shape: str
    lean_modules: dict = field(default_factory=dict)
    rust_translation: str = ""
    c_oracle: str = ""
    c_oracle_renamed: str = ""
    c_oracle_wrappers: str = ""
    regen_script: str = ""
    grounding_script: str = ""
    function_names: list = field(default_factory=list)
    n_functions: int = 0
    pg_fcinfo_helpers_used: list = field(default_factory=list)
    pg_palloc_helpers_used: list = field(default_factory=list)
    errcode_used: list = field(default_factory=list)
    real_pg_source_files: list = field(default_factory=list)
    notes: list = field(default_factory=list)


def read_or_empty(p: Path) -> str:
    try:
        return p.read_text()
    except FileNotFoundError:
        return ""


def grep_lines(text: str, pattern: str) -> list[str]:
    rx = re.compile(pattern)
    return [m.group(0) if isinstance(m, re.Match) else m
            for m in rx.findall(text)]


def grep_capture(text: str, pattern: str) -> list[str]:
    """Like grep_lines but returns capture group 1."""
    rx = re.compile(pattern)
    return rx.findall(text)


def extract_cluster(repo: Path, crate: str, meta: dict) -> ClusterRecord:
    crate_dir = repo / "rust" / crate
    lean_dir = repo / "lean" / "Pg" / "Ir" / "Emit"
    regen_dir = repo / "tools" / "regen"

    rec = ClusterRecord(
        cluster=crate,
        cluster_short=meta["short"],
        cluster_shape=meta["shape"],
    )

    # Lean modules: try the three names; some clusters only have 2.
    for mod in meta["lean"]:
        path = lean_dir / f"{mod}.lean"
        content = read_or_empty(path)
        if content:
            rec.lean_modules[mod] = content
        else:
            rec.notes.append(f"missing lean module: {mod}.lean")

    # Rust translation
    rec.rust_translation = read_or_empty(crate_dir / "src" / "lib.rs")

    # C oracle. Try several plausible names.
    for fname in [f"{meta['short']}.c", f"{crate[3:]}.c", "oracle.c"]:
        path = crate_dir / "c_oracle" / fname
        if path.exists():
            rec.c_oracle = read_or_empty(path)
            break
    if not rec.c_oracle:
        # Last-ditch: pick the largest non-renamed/non-wrappers .c
        oracle_dir = crate_dir / "c_oracle"
        if oracle_dir.exists():
            cands = [p for p in oracle_dir.glob("*.c")
                     if "renamed" not in p.name and "wrappers" not in p.name]
            if cands:
                cands.sort(key=lambda p: p.stat().st_size, reverse=True)
                rec.c_oracle = read_or_empty(cands[0])
                rec.notes.append(f"oracle source via fallback: {cands[0].name}")

    # Renamed wrapper + wrappers.c
    oracle_dir = crate_dir / "c_oracle"
    if oracle_dir.exists():
        for p in oracle_dir.glob("renamed_*.c"):
            rec.c_oracle_renamed = read_or_empty(p)
            break
        for p in oracle_dir.glob("wrappers.c"):
            rec.c_oracle_wrappers = read_or_empty(p)
            break

    # Regen / grounding scripts
    rec.regen_script = read_or_empty(regen_dir / meta["regen"])
    rec.grounding_script = read_or_empty(regen_dir / meta["grounding"])

    # Function names from Rust translation
    rec.function_names = grep_capture(
        rec.rust_translation,
        r'pub unsafe extern "C" fn (\w+)\(',
    )
    rec.n_functions = len(rec.function_names)

    # Imported pg_fcinfo helpers
    fcinfo_use = re.search(
        r"use pg_fcinfo::\{([^}]+)\}",
        rec.rust_translation,
        re.DOTALL,
    )
    if fcinfo_use:
        rec.pg_fcinfo_helpers_used = [
            h.strip() for h in fcinfo_use.group(1).split(",") if h.strip()
        ]

    palloc_use = re.search(
        r"use pg_palloc::\{?([^;}]+)\}?",
        rec.rust_translation,
    )
    if palloc_use:
        rec.pg_palloc_helpers_used = [
            h.strip() for h in palloc_use.group(1).split(",") if h.strip()
        ]

    # ereport kinds used
    rec.errcode_used = sorted(set(grep_capture(
        rec.rust_translation,
        r"pg_ereport_(\w+)\(",
    )))

    # Real-PG source files (parse from oracle's vendoring comment)
    rec.real_pg_source_files = sorted(set(grep_capture(
        rec.c_oracle,
        r"src/backend/[\w/]+\.c",
    )))

    return rec


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract Pg.Ir corpus.")
    ap.add_argument("--repo", default="/Volumes/Workspace/rules_postgres",
                    help="rules_postgres repo root")
    ap.add_argument("--out", default="/Volumes/Workspace/rules_postgres/tools/corpus_extract/corpus.jsonl",
                    help="output JSONL path")
    args = ap.parse_args()

    repo = Path(args.repo)
    out = Path(args.out)

    rust_dir = repo / "rust"
    found_crates = sorted(p.name for p in rust_dir.iterdir() if p.is_dir())

    expected = set(PGIR_CLUSTERS.keys())
    unknown = set(found_crates) - expected - SKIP_CRATES
    if unknown:
        print(f"warn: unknown crates not in PGIR_CLUSTERS or SKIP: {sorted(unknown)}")

    records = []
    for crate, meta in PGIR_CLUSTERS.items():
        if crate not in found_crates:
            print(f"warn: crate not found on disk: {crate}")
            continue
        rec = extract_cluster(repo, crate, meta)
        records.append(rec)

    # Emit JSONL
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w") as f:
        for rec in records:
            d = {
                "cluster": rec.cluster,
                "cluster_short": rec.cluster_short,
                "cluster_shape": rec.cluster_shape,
                "lean_modules": rec.lean_modules,
                "rust_translation": rec.rust_translation,
                "c_oracle": rec.c_oracle,
                "c_oracle_renamed": rec.c_oracle_renamed,
                "c_oracle_wrappers": rec.c_oracle_wrappers,
                "regen_script": rec.regen_script,
                "grounding_script": rec.grounding_script,
                "function_names": rec.function_names,
                "n_functions": rec.n_functions,
                "pg_fcinfo_helpers_used": rec.pg_fcinfo_helpers_used,
                "pg_palloc_helpers_used": rec.pg_palloc_helpers_used,
                "errcode_used": rec.errcode_used,
                "real_pg_source_files": rec.real_pg_source_files,
                "notes": rec.notes,
            }
            f.write(json.dumps(d) + "\n")

    total_fns = sum(r.n_functions for r in records)
    total_bytes = out.stat().st_size
    print(f"corpus written: {out}")
    print(f"  clusters     : {len(records)}")
    print(f"  total fns    : {total_fns}")
    print(f"  total bytes  : {total_bytes:,} ({total_bytes / 1024:.1f} KiB)")
    print(f"  avg per fn   : {total_bytes // max(1, total_fns):,} bytes")
    print()
    print("cluster summary:")
    for r in records:
        print(f"  {r.cluster_short:18s}  {r.n_functions:3d} fns  shape={r.cluster_shape}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
