#!/usr/bin/env bash
# check-all.sh — Gate 1: regen idempotence.
#
# Runs every per-cluster regen script with `--check` and reports any
# committed Rust/C emit that has drifted relative to its Lean source.
# Exits non-zero if any cluster is stale.
#
# Local invocation:
#   tools/regen/check-all.sh
#
# Bazel invocation (opt-in, requires `lean` on PATH):
#   bazel test //tools/regen:gate1_regen_idempotence
#
# Requirements:
#   - `lean` binary on PATH (the underlying regen scripts shell out to
#     it). On dev machines this comes from the Lean toolchain rules_lean
#     materializes under bazel-cache; sourcing
#     `tools/lake/.lake/toolchain/bin` or running `bazel build
#     @rules_postgres_lake//:lean_toolchain_def` first usually suffices.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
scripts=( "$SCRIPT_DIR"/regen-*.sh )
shopt -u nullglob

if [ ${#scripts[@]} -eq 0 ]; then
  echo "ERROR: no regen-*.sh scripts found under $SCRIPT_DIR" >&2
  exit 2
fi

stale=()
missing_lean=0
for s in "${scripts[@]}"; do
  name="$(basename "$s")"
  printf '== %-40s ' "$name"
  if out=$("$s" --check 2>&1); then
    echo "ok"
  else
    rc=$?
    echo "STALE (rc=$rc)"
    echo "$out" | sed 's/^/    /'
    stale+=( "$name" )
    if echo "$out" | grep -q "lean: command not found"; then
      missing_lean=1
    fi
  fi
done

echo
if [ ${#stale[@]} -eq 0 ]; then
  echo "Gate 1: regen idempotence — all ${#scripts[@]} clusters fresh."
  exit 0
fi

echo "Gate 1: regen idempotence — ${#stale[@]}/${#scripts[@]} cluster(s) stale:"
for s in "${stale[@]}"; do echo "  - $s"; done
if [ "$missing_lean" -eq 1 ]; then
  echo
  echo "NOTE: at least one failure mentions 'lean: command not found'."
  echo "      Source the Lean toolchain PATH before re-running, e.g.:"
  echo "        bazel build @rules_postgres_lake//:lean_toolchain_def"
  echo "        export PATH=\$(find ~/Library/Caches/bazel -name 'lean' -path '*/bin/lean' | head -1 | xargs dirname):\$PATH"
fi
exit 1
