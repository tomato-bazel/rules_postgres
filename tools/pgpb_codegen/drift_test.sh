#!/bin/sh
# pgpb_codegen drift gate — fail if the committed Generated.lean
# differs from a fresh regenerate of pg_query.proto.
#
# Args: $1 = regenerated file, $2 = committed file.
set -e
REGEN="$1"
COMMITTED="$2"
if diff -q "$REGEN" "$COMMITTED" > /dev/null; then
    echo "pgpb_codegen drift: clean."
    exit 0
fi
echo "pgpb_codegen drift detected:" >&2
diff -u "$COMMITTED" "$REGEN" | head -40 >&2
echo "" >&2
echo "To fix:" >&2
echo "  bazel build @rules_postgres//tools/pgpb_codegen:pg_query_lean_regen" >&2
echo "  cp bazel-bin/tools/pgpb_codegen/Generated.regen.lean \\" >&2
echo "     lean/Pg/Query/Generated.lean" >&2
exit 1
