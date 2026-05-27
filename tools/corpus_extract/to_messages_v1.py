#!/usr/bin/env python3
"""
Convert Pg.Ir corpus training pairs → rules_lora's `messages_v1`
SFT schema.

Reads `train_c_to_lean.jsonl` (raw {input, output} pairs) and
emits a JSONL where each line is:

    {"messages": [{"role": "system", "content": "<system prompt>"},
                  {"role": "user",   "content": "<C source + meta>"},
                  {"role": "assistant", "content": "<Lean spec>"}]}

The system prompt encodes the Pg.Ir task contract; the user message
includes the cluster shape tag as a conditioning signal so a fine-
tuned model learns the shape → spec mapping.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


SYSTEM_PROMPT = """You are a Pg.Ir specification author. Pg.Ir is a Lean-source-of-truth codegen pipeline for Postgres V1 fmgr function bodies.

Given a Postgres C source file containing one or more V1 fmgr function bodies, you produce three Lean modules:

1. `<Cluster>Common.lean` — the family table (inductive body shapes + a `families : List Family` definition enumerating all cluster members).
2. `<Cluster>.lean` (or `<Cluster>Rust.lean`) — Rust-emit driver. Takes the families table and renders Rust V1 fmgr function bodies.
3. `<Cluster>C.lean` — C-emit driver. Same families, but renders real-Postgres-style C (with `#include "postgres.h"` etc.) for AST grounding against the real source.

Three correctness gates the spec must satisfy:
1. Lean → Rust regen is idempotent.
2. The Rust translation passes a behavioral diff-test against the vendored C oracle (per-call Datum equality).
3. The Lean-emitted C is structurally equivalent (clang AST diff) to real Postgres source.

Common failure modes to avoid:
- The C oracle's `PG_RETURN_*` macros must include the `return` keyword (`return (Datum)(uint32_t)(x)`, NOT `((Datum)(x))`).
- The Lean C emit (`<Cluster>C.lean`) MUST use real Postgres headers (`#include "postgres.h"`, plus module-specific headers like `utils/uuid.h`, `varatt.h`, `<limits.h>`). It MUST NOT define standalone typedefs.
- When the real Postgres function delegates to a `static inline` helper, the Lean emit must also delegate (not inline the body).

Output the three Lean modules separated by `-- ===== <Module>.lean =====` markers."""


USER_PROMPT_TEMPLATE = """Cluster: {cluster}
Shape: {shape}
Functions ({n}): {fns}

Real Postgres source files involved: {sources}
pg_fcinfo helpers needed: {fcinfo_helpers}
Error kinds raised: {errcodes}

Postgres C source (vendored standalone form — the body is byte-identical to real PG):

```c
{c_source}
```

Write the Pg.Ir Lean spec (three modules) for this cluster."""


def to_messages_v1(pair: dict) -> dict:
    meta = pair.get("metadata", {})
    fns = meta.get("function_names", [])
    fns_str = ", ".join(fns) if len(fns) <= 10 else \
        ", ".join(fns[:10]) + f", ... ({len(fns) - 10} more)"
    user_content = USER_PROMPT_TEMPLATE.format(
        cluster=pair["cluster"],
        shape=meta.get("cluster_shape", "?"),
        n=meta.get("n_functions", 0),
        fns=fns_str,
        sources=", ".join(meta.get("real_pg_source_files", []) or ["(unknown)"]),
        fcinfo_helpers=", ".join(meta.get("pg_fcinfo_helpers_used", []) or ["(none)"]),
        errcodes=", ".join(meta.get("errcode_used", []) or ["(none)"]),
        c_source=pair["input"],
    )
    return {
        "messages": [
            {"role": "system",    "content": SYSTEM_PROMPT},
            {"role": "user",      "content": user_content},
            {"role": "assistant", "content": pair["output"]},
        ],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp",
                    default="/Volumes/Workspace/rules_postgres/tools/corpus_extract/train_c_to_lean.jsonl")
    ap.add_argument("--out",
                    default="/Volumes/Workspace/rules_postgres/tools/corpus_extract/sft_messages_v1.jsonl")
    args = ap.parse_args()

    inp = Path(args.inp)
    out = Path(args.out)

    pairs = [json.loads(line) for line in inp.read_text().splitlines() if line.strip()]
    print(f"loaded {len(pairs)} c_to_lean pairs")

    with out.open("w") as f:
        for p in pairs:
            f.write(json.dumps(to_messages_v1(p)) + "\n")

    print(f"wrote {out}")
    sz = out.stat().st_size
    print(f"  examples: {len(pairs)}")
    print(f"  size    : {sz:,} bytes ({sz / 1024:.1f} KiB)")

    # Quick stats
    samples = [json.loads(line) for line in out.read_text().splitlines()]
    user_lens = [len(s["messages"][1]["content"]) for s in samples]
    asst_lens = [len(s["messages"][2]["content"]) for s in samples]
    print(f"  user avg/max chars: {sum(user_lens) // len(user_lens):,} / {max(user_lens):,}")
    print(f"  asst avg/max chars: {sum(asst_lens) // len(asst_lens):,} / {max(asst_lens):,}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
