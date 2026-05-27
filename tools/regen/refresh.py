#!/usr/bin/env python3
"""Refresh the committed Pg.Ir cluster emit artifacts from the Lean
source of truth — Bazel-native equivalent of the legacy
`tools/regen/regen-<cluster>.sh` scripts.

For each cluster spec in `tools/regen/clusters.bzl::CLUSTERS`:
  1. `bazel build //lean:<base>_rs_emit` — runs lean_emit, captures
     Lean main stdout into bazel-bin/lean/<base>_rs_emit.rs
  2. Copy that artifact to `rust/<crate>/src/lib.rs`
  3. (If the spec has `lean_emit_c = True`) repeat for the C emit:
     `bazel build //lean:<base>_c_emit` → `rust/<crate>/c_oracle/<base>_emit.c`

After running, `bazel test //:gates` should be a no-op pass — the
committed files now match the Lean source.

Usage:
  tools/regen/refresh.py            # refresh ALL clusters
  tools/regen/refresh.py int_arith  # refresh one cluster by c_base
  tools/regen/refresh.py --list     # list clusters

Replaces the per-cluster `tools/regen/regen-<cluster>.sh` scripts.
Old scripts shelled out to host `lean`; this one drives Bazel-native
`lean_emit` targets, so the Lean toolchain comes from rules_lean's
lake_workspace (zero host-side install required).
"""

from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CLUSTERS_BZL = REPO_ROOT / "tools" / "regen" / "clusters.bzl"


def _parse_clusters() -> list[dict]:
    """Pull cluster metadata from `clusters.bzl` via regex.

    Avoids invoking Starlark / Bazel just to enumerate clusters. Each
    parsed entry has `crate`, `c_base`, and `lean_emit_c`.
    """
    text = CLUSTERS_BZL.read_text()
    blocks = re.findall(r"struct\(([^)]*)\)", text, re.DOTALL)
    out: list[dict] = []
    for block in blocks:
        def get(key: str) -> str | None:
            m = re.search(rf'{key}\s*=\s*"([^"]+)"', block)
            return m.group(1) if m else None

        crate = get("crate")
        c_base = get("c_base")
        if not crate or not c_base:
            continue
        lean_emit_c = bool(re.search(r"lean_emit_c\s*=\s*True", block))
        out.append({"crate": crate, "c_base": c_base, "lean_emit_c": lean_emit_c})
    return out


def _bazel_build(target: str) -> pathlib.Path:
    """Build a Bazel target and return the first output file path."""
    print(f"  bazel build {target}", file=sys.stderr)
    subprocess.run(
        ["bazel", "build", target],
        cwd=str(REPO_ROOT),
        check=True,
    )
    cquery = subprocess.run(
        ["bazel", "cquery", "--output=files", target],
        cwd=str(REPO_ROOT),
        check=True,
        capture_output=True,
        text=True,
    )
    paths = [p for p in cquery.stdout.strip().splitlines() if p]
    if not paths:
        raise RuntimeError(f"no output file for {target}")
    return REPO_ROOT / paths[0]


def refresh_cluster(spec: dict) -> None:
    crate = spec["crate"]
    base = spec["c_base"]
    print(f"== {crate} ==", file=sys.stderr)

    rs_artifact = _bazel_build(f"//lean:{base}_rs_emit")
    rs_dest = REPO_ROOT / "rust" / crate / "src" / "lib.rs"
    shutil.copyfile(rs_artifact, rs_dest)
    print(f"  wrote {rs_dest.relative_to(REPO_ROOT)}", file=sys.stderr)

    if spec["lean_emit_c"]:
        c_artifact = _bazel_build(f"//lean:{base}_c_emit")
        c_dest = REPO_ROOT / "rust" / crate / "c_oracle" / f"{base}_emit.c"
        shutil.copyfile(c_artifact, c_dest)
        print(f"  wrote {c_dest.relative_to(REPO_ROOT)}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "cluster",
        nargs="?",
        help="cluster c_base to refresh (e.g. `int_arith`). Omit to refresh all.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="list cluster c_base names and exit.",
    )
    args = parser.parse_args()

    clusters = _parse_clusters()
    if args.list:
        for c in clusters:
            tag = " [+C emit]" if c["lean_emit_c"] else ""
            print(f"{c['c_base']:24} {c['crate']}{tag}")
        return 0

    if args.cluster:
        matches = [c for c in clusters if c["c_base"] == args.cluster]
        if not matches:
            print(f"no cluster with c_base={args.cluster}", file=sys.stderr)
            return 2
        refresh_cluster(matches[0])
    else:
        for spec in clusters:
            refresh_cluster(spec)

    print("done. Run `bazel test //:gates` to verify.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
