#!/usr/bin/env bash
# ⛔ NO `sorry` IN //lean.
#
# `sorry` WARNS; `lean` EXITS 0. So a `lean_test` over a file containing one is
# GREEN, and the theorem it stands under is not proved. The only thing that
# turns that warning into a failure is `set_option warningAsError true` at the
# top of the file — and exactly ONE of the 114 files in this tree sets it.
#
# ⚠ THIS GATE IS DELIBERATELY NARROW, and what it does NOT check is the reason
# it is written here rather than ported from a sibling repo:
#
#   `native_decide` — 106 uses, all in the AST emit tests, all of the shape
#   "this emitter produces exactly this SQL string". Concrete evaluations, not
#   theorems over all inputs. Gating them would fail every one on day one.
#
#   `axiom` — 13, all in `Pg/Spec.lean`, all axiomatizing POSTGRES'S OWN
#   GUARANTEES: primary keys are unique, foreign keys refer, RLS has no
#   backdoor. Those cannot be proved here; assuming them explicitly, in one
#   named file, is what makes everything downstream honest. A gate that flagged
#   them would be pressure to hide them.
#
#   `admit` — the two hits in this tree are the ENGLISH WORD in a comment
#   ("would wrongly admit 32768.0"). A word-boundary grep for tactics finds
#   prose, which is how a gate earns a reputation for crying wolf.
#
# So: `sorry` only, which is at zero today and stays there.
set -euo pipefail

# Under `bazel test` the cwd is the runfiles root and BUILD_WORKSPACE_DIRECTORY
# is NOT set — it exists only under `bazel run`. The first version of this file
# referenced it, and `set -u` is the only reason that surfaced as a failure
# rather than a `cd` that quietly did not happen.
cd lean

scan() {
  # One perl per file. ⛔ NOT `xargs -I{}`: `-I` substitutes the replacement
  # string EVERYWHERE in the command, including inside `s{/-.*?-/}{}gs`, so the
  # braces of the regex became the filename and perl died on every file. With
  # stderr dropped and `|| true` on the end — which is how the first version of
  # this was written — that reported a clean tree while matching nothing at all.
  local f
  for f in "$@"; do
    perl -0777 -ne '
      s{/-.*?-/}{ "\n" x ($& =~ tr/\n//) }gse;   # keep line count when stripping
      s{--[^\n]*}{}g;
      while (/\bsorry\b/g) {
        my $line = 1 + substr($_, 0, pos($_)) =~ tr/\n//;
        print "$ARGV:$line\n";
      }
    ' "$f"
  done
}

# ⭐ THE GATE PROVES ITS MATCHER WORKS BEFORE IT TRUSTS A CLEAN RESULT.
#
# This is the check that would have caught the bug above, and the file-count
# assertion below is not: the count came from a separate `find` that was working
# fine while the matcher was crashing. An empty result means "nothing found" OR
# "nothing looked" — and only a known-positive tells you which.
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
printf 'theorem a : 1 = 1 := by sorry\n' > "$probe/pos.lean"
printf -- '-- sorry, subtle\n/- and sorry here -/\ntheorem b : 1 = 1 := rfl\n' > "$probe/neg.lean"

if [ "$(scan "$probe/pos.lean" | wc -l | tr -d ' ')" != "1" ]; then
  echo "FAIL: this gate cannot detect a \`sorry\` it planted itself."
  echo "      The matcher is broken; a clean result below would mean nothing."
  exit 1
fi
if [ -n "$(scan "$probe/neg.lean")" ]; then
  echo "FAIL: this gate flags the word \`sorry\` in a comment. It will cry wolf"
  echo "      until somebody disables it."
  exit 1
fi

# And that it is pointed at the tree at all.
#
# ⚠ NOT `mapfile` — that is bash 4, and macOS ships bash 3.2, so the first
# version exited 127 on darwin. This repo's CI runs a linux+macos matrix; a
# bash-4 builtin would have been green on one leg and dead on the other.
set -- $(find . -name '*.lean' | sort)
if [ "$#" -lt 100 ]; then
  echo "FAIL: found only $# Lean files — not looking at the tree (cwd: $PWD)"
  exit 1
fi
n=$#

hits=$(scan "$@")
if [ -n "$hits" ]; then
  echo "FAIL: \`sorry\` in //lean — these theorems are not proved, and lean_test"
  echo "      passed anyway because sorry warns rather than errors:"
  echo "$hits"
  exit 1
fi

echo "ok: matcher self-checked; no \`sorry\` in $n Lean files"
