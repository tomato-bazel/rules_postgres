#!/usr/bin/env python3
"""
Build (input, output) training pairs from the Pg.Ir corpus.

Reads `corpus.jsonl` (produced by `extract.py`) and emits multiple
training views for different fine-tuning objectives.

## Objectives

Each cluster in `corpus.jsonl` contributes one or more pairs:

1. **c-source → lean-spec (PRIMARY)** — the main objective: given
   real PG source code, produce the Pg.Ir Lean spec (Common +
   Emit + EmitC). Input is the C oracle (which is byte-identical
   to the real PG body, minus the standalone preamble); output is
   the concatenated Lean files.

2. **lean → rust** — secondary: given a Lean spec, produce the
   Rust translation. Validates the renderFn / renderBody logic.

3. **lean → c-emit** — secondary: given a Lean spec, produce the
   real-PG-style C for AST grounding.

## Output format

Three JSONL files, one per objective:
  `train_c_to_lean.jsonl`
  `train_lean_to_rust.jsonl`
  `train_lean_to_c.jsonl`

Each line has:
  {
    "cluster": "<name>",
    "input": "<full text>",
    "output": "<full text>",
    "metadata": {...optional fields...}
  }

For prompt-style fine-tuning you'd wrap each side with a system
prompt + delimiters; this script emits the raw pairs to keep the
data format-agnostic. Wrap downstream.

## Run

```sh
python3 tools/corpus_extract/training_pairs.py \
    --corpus tools/corpus_extract/corpus.jsonl \
    --out-dir tools/corpus_extract/
```
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def emit_c_to_lean(rec: dict) -> dict | None:
    """Primary objective: C source → Lean spec."""
    c_oracle = rec.get("c_oracle", "")
    lean_modules = rec.get("lean_modules", {})
    if not c_oracle or not lean_modules:
        return None

    # Concatenate the Lean modules in canonical order: Common first,
    # then the Rust emit, then the C emit. Use markers so the model
    # learns the structure.
    parts = []
    for name in sorted(lean_modules.keys()):
        parts.append(f"-- ===== {name}.lean =====\n{lean_modules[name]}")
    lean_output = "\n\n".join(parts)

    return {
        "cluster": rec["cluster_short"],
        "input": c_oracle,
        "output": lean_output,
        "metadata": {
            "cluster_shape": rec.get("cluster_shape"),
            "n_functions": rec.get("n_functions"),
            "function_names": rec.get("function_names"),
            "pg_fcinfo_helpers_used": rec.get("pg_fcinfo_helpers_used"),
            "errcode_used": rec.get("errcode_used"),
            "real_pg_source_files": rec.get("real_pg_source_files"),
        },
    }


def emit_lean_to_rust(rec: dict) -> dict | None:
    """Secondary objective: Lean spec → Rust translation."""
    lean_modules = rec.get("lean_modules", {})
    rust = rec.get("rust_translation", "")
    if not lean_modules or not rust:
        return None

    # Input: just Common + Emit (the Rust-relevant Lean). Skip EmitC
    # for this objective.
    relevant = {k: v for k, v in lean_modules.items() if not k.endswith("C")}
    parts = []
    for name in sorted(relevant.keys()):
        parts.append(f"-- ===== {name}.lean =====\n{relevant[name]}")
    lean_input = "\n\n".join(parts)

    return {
        "cluster": rec["cluster_short"],
        "input": lean_input,
        "output": rust,
        "metadata": {
            "cluster_shape": rec.get("cluster_shape"),
            "n_functions": rec.get("n_functions"),
        },
    }


def emit_lean_to_c(rec: dict) -> dict | None:
    """Secondary objective: Lean spec → real-PG-style C emit."""
    lean_modules = rec.get("lean_modules", {})
    # The C emit lives in `<Cluster>C.lean`; the OUTPUT of that emit
    # is the real-PG-style C, which lives in the c_oracle as the
    # byte-identical body. So input = Common + EmitC; output = c_oracle.
    c_oracle = rec.get("c_oracle", "")
    if not lean_modules or not c_oracle:
        return None

    relevant = {k: v for k, v in lean_modules.items()
                if not k.endswith("CommonC") and "Emit" not in k or k.endswith("C")}
    # Refine: include the *Common.lean and the *C.lean (the EmitC).
    refined = {}
    for k, v in lean_modules.items():
        if "Common" in k and not k.endswith("C"):
            refined[k] = v
        elif k.endswith("C"):
            refined[k] = v
    parts = []
    for name in sorted(refined.keys()):
        parts.append(f"-- ===== {name}.lean =====\n{refined[name]}")
    lean_input = "\n\n".join(parts) if parts else ""
    if not lean_input:
        return None

    return {
        "cluster": rec["cluster_short"],
        "input": lean_input,
        "output": c_oracle,
        "metadata": {
            "cluster_shape": rec.get("cluster_shape"),
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="/Volumes/Workspace/rules_postgres/tools/corpus_extract/corpus.jsonl")
    ap.add_argument("--out-dir", default="/Volumes/Workspace/rules_postgres/tools/corpus_extract/")
    args = ap.parse_args()

    corpus = Path(args.corpus)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    records = [json.loads(line) for line in corpus.read_text().splitlines() if line.strip()]
    print(f"loaded {len(records)} cluster records")

    objectives = [
        ("c_to_lean",      emit_c_to_lean),
        ("lean_to_rust",   emit_lean_to_rust),
        ("lean_to_c",      emit_lean_to_c),
    ]

    for name, emit_fn in objectives:
        out_path = out_dir / f"train_{name}.jsonl"
        pairs = []
        for rec in records:
            pair = emit_fn(rec)
            if pair is not None:
                pairs.append(pair)
        with out_path.open("w") as f:
            for p in pairs:
                f.write(json.dumps(p) + "\n")
        total_in = sum(len(p["input"]) for p in pairs)
        total_out = sum(len(p["output"]) for p in pairs)
        avg_in = total_in // max(1, len(pairs))
        avg_out = total_out // max(1, len(pairs))
        print(f"  {name:14s}  {len(pairs):3d} pairs  avg_in={avg_in:5,}  avg_out={avg_out:6,}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
