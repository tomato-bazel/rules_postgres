#!/usr/bin/env python3
"""Stream A author: render a hardened prompt for spawning a Haiku agent
that authors a new Pg.Ir cluster end-to-end.

Reads:
  - tools/stream_a/PROMPT_TEMPLATE.md  (the hardened prompt skeleton)
  - tools/stream_a/pilots/<name>.toml  (per-pilot config — see _template.toml)

Substitutes the template's `<<placeholder>>` markers from the pilot
config and writes the composed prompt to stdout.

Usage:
  tools/stream_a/author.py --pilot int_div > /tmp/int_div_prompt.txt

To kick off an actual agent (manually):
  tools/stream_a/author.py --pilot int_div \\
    | claude  # or whatever agent CLI you use

History: previous Stream A pilots ran the prompt template by hand-
substituting <<...>> markers in a session-local copy. Checking in
both the template and the per-pilot configs makes the authoring run
reproducible — a different agent (or the same agent at a different
time) re-rendering the same pilot config gets the same prompt.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore[no-redef]


HERE = pathlib.Path(__file__).resolve().parent
TEMPLATE_PATH = HERE / "PROMPT_TEMPLATE.md"
PILOTS_DIR = HERE / "pilots"


def _render(template: str, mapping: dict[str, str]) -> str:
    """Replace every `<<key>>` in `template` with `mapping[key]`.

    Keys are matched case-insensitively against the surrounding whitespace-
    stripped placeholder text. Unmapped placeholders are kept as-is and
    counted; a non-empty count is reported on stderr.
    """
    unmapped = []

    def normalize(s: str) -> str:
        # Collapse any whitespace (incl. newlines inside multi-line
        # placeholder text) to a single space, lowercase.
        return re.sub(r"\s+", " ", s).strip().lower()

    # Re-key the mapping with the same normalization so callers don't
    # have to.
    norm_mapping = {normalize(k): v for k, v in mapping.items()}

    def sub(match: re.Match[str]) -> str:
        raw = normalize(match.group(1))
        if raw in norm_mapping:
            return norm_mapping[raw]
        unmapped.append(raw)
        return match.group(0)

    out = re.sub(r"<<([^>]+)>>", sub, template, flags=re.DOTALL)
    if unmapped:
        unique = sorted(set(unmapped))
        sys.stderr.write(
            "stream_a/author.py: {} placeholder(s) left unmapped:\n".format(len(unique)),
        )
        for u in unique:
            sys.stderr.write("  - <<{}>>\n".format(u))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--pilot",
        required=True,
        help="Pilot name (matches tools/stream_a/pilots/<name>.toml).",
    )
    args = parser.parse_args()

    pilot_path = PILOTS_DIR / "{}.toml".format(args.pilot)
    if not pilot_path.exists():
        sys.stderr.write("no pilot config at {}\n".format(pilot_path))
        return 2

    with pilot_path.open("rb") as f:
        cfg = tomllib.load(f)

    template = TEMPLATE_PATH.read_text()

    # Pilot config keys are placeholder names (case-insensitive). Values
    # may be plain strings or lists; lists are rendered as `- item\n`
    # bullets for natural drop-in to the template.
    mapping: dict[str, str] = {}
    for key, val in cfg.items():
        if isinstance(val, list):
            mapping[key.lower()] = "\n".join("- {}".format(item) for item in val)
        else:
            mapping[key.lower()] = str(val)

    sys.stdout.write(_render(template, mapping))
    return 0


if __name__ == "__main__":
    sys.exit(main())
