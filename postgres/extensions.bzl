"""Module extension for rules_postgres.

Exposes two tag classes:

  pg.query(version = ...)  — fetches libpg_query and builds it as a
                             `cc_library`. Creates @libpg_query.

  pg.source(version = ...) — fetches the full PostgreSQL source tarball
                             and lays a minimal BUILD overlay on top
                             (filegroups for source dirs + a probe
                             `pg_common_string` cc_library). Creates
                             @postgres_src.

The two paths are independent. Most consumers want only `pg.query` for
SQL parse-validation gates; `pg.source` is for advanced tooling that
needs the full PG codebase under Bazel.

Default usage:

    pg = use_extension("@rules_postgres//postgres:extensions.bzl", "pg")
    pg.query(version = "17-6.2.2")
    use_repo(pg, "libpg_query")

With full PG source as well:

    pg.source(version = "17.6")
    use_repo(pg, "libpg_query", "postgres_src")

For generating compile_commands.json (consumable by rules_lang's
c_ast_dump_from_compdb), see `pg_meson_configure` in
`postgres/meson.bzl`. That rule runs a hermetic `meson setup` as a
Bazel build action using rules_foreign_cc's meson + ninja toolchains.
"""

load(
    "@rules_github//github:repositories.bzl",
    "github_source_repository",
)
load(
    "//postgres/private:known_versions.bzl",
    "LIBPG_QUERY_VERSIONS",
    "POSTGRES_SOURCE_URL_TEMPLATE",
    "POSTGRES_SOURCE_VERSIONS",
)

# ---------------------------------------------------------------------------
# @libpg_query BUILD overlay. Splits the build into four modular
# cc_library targets so consumers can pull pieces independently.
# ---------------------------------------------------------------------------
_LIBPG_QUERY_BUILD = """
load("@rules_cc//cc:defs.bzl", "cc_library")

package(default_visibility = ["//visibility:public"])

# Vendored protobuf-c runtime. libpg_query bundles a copy under
# vendor/protobuf-c/. Exposed standalone so other tools can use
# protobuf-c without pulling in the full parser.
cc_library(
    name = "protobuf_c_runtime",
    srcs = ["vendor/protobuf-c/protobuf-c.c"],
    hdrs = ["vendor/protobuf-c/protobuf-c.h"],
    includes = ["vendor"],
    copts = [
        "-Wno-unused-function",
        "-Wno-unused-but-set-variable",
        "-fno-strict-aliasing",
    ],
)

# Vendored xxhash — the hash function libpg_query uses internally
# for parse-tree fingerprinting (pg_query_fingerprint).
cc_library(
    name = "xxhash",
    srcs = ["vendor/xxhash/xxhash.c"],
    hdrs = ["vendor/xxhash/xxhash.h"],
    includes = ["vendor"],
    copts = [
        "-Wno-unused-function",
        "-fno-strict-aliasing",
    ],
)

# Pre-generated protobuf-c bindings for pg_query.proto. Shipped in the
# release tarball; used as-is rather than re-running protoc-c.
cc_library(
    name = "pg_query_pb_c",
    srcs = ["protobuf/pg_query.pb-c.c"],
    hdrs = ["protobuf/pg_query.pb-c.h"],
    includes = ["protobuf"],
    deps = [":protobuf_c_runtime"],
    copts = ["-Wno-unused-function"],
)

# The parser library proper.
cc_library(
    name = "libpg_query",
    srcs = glob([
        "src/*.c",
        "src/postgres/*.c",
    ]),
    hdrs = [
        "pg_query.h",
        "postgres_deparse.h",
    ],
    textual_hdrs = glob(
        [
            "src/*.h",
            "src/include/**/*.c",
            "src/include/**/*.h",
            "src/postgres/include/**/*.h",
            "src/postgres/include/**/*.c",
        ],
        allow_empty = True,
    ),
    includes = [
        ".",
        "src/include",
        "src/postgres/include",
    ],
    deps = [
        ":protobuf_c_runtime",
        ":xxhash",
        ":pg_query_pb_c",
    ],
    copts = [
        "-Wno-unused-function",
        "-Wno-unused-value",
        "-Wno-unused-variable",
        "-Wno-unused-but-set-variable",
        "-Wno-implicit-fallthrough",
        "-Wno-deprecated-declarations",
        "-fno-strict-aliasing",
        "-fwrapv",
    ],
)

# Raw protobuf schema, exposed for downstream codegen (other-language
# bindings, type-checked AST readers, etc.).
exports_files(["protobuf/pg_query.proto"])

filegroup(
    name = "pg_query_proto_file",
    srcs = ["protobuf/pg_query.proto"],
)

# cc_library bundling libpg_query's vendored PG headers — specifically
# the generated fmgrprotos.h + errcodes.h that the real PG source tree
# doesn't carry (they're produced by PG's own build). Consumers needing
# clang -ast-dump on PG-header-using TUs pair this with
# @postgres_src//:pg_headers.
cc_library(
    name = "pg_generated_headers",
    hdrs = glob(["src/postgres/include/**/*.h"], allow_empty = True),
    includes = ["src/postgres/include"],
)
"""

# ---------------------------------------------------------------------------
# @postgres_src BUILD overlay. Exposes filegroups for source-tree
# inspection + a probe cc_library compiling one small chunk of PG.
# Real callers extend this BUILD with their own cc_library targets.
# ---------------------------------------------------------------------------
_POSTGRES_SRC_BUILD = """
load("@rules_cc//cc:defs.bzl", "cc_library")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "all_source",
    srcs = glob(["**"]),
)

# Expose meson.build at the source root so build rules (e.g.
# pg_meson_configure) can use it as a marker label to discover the
# source tree's sandbox path.
exports_files(["meson.build"])

filegroup(
    name = "common_sources",
    srcs = glob(["src/common/*.c"], allow_empty = True),
)

filegroup(
    name = "include_headers",
    srcs = glob(["src/include/**/*.h"], allow_empty = True),
)

# cc_library bundling the public PG header tree. Consumers that need
# `#include "postgres.h"` etc. resolved by clang (e.g. rules_lang's
# c_ast_dump_single via the `deps` attr) depend on this.
cc_library(
    name = "pg_headers",
    hdrs = glob(["src/include/**/*.h"], allow_empty = True),
    includes = ["src/include"],
)

# Expose specific backend .c sources that the Pg.Ir cluster gates
# structurally diff against (clang -ast-dump=json target). One
# exports_files block per directory so consumers reference them via
# `@postgres_src//src/backend/utils/adt:uuid.c` style labels.
exports_files(
    glob([
        "src/backend/utils/adt/*.c",
        "src/backend/access/hash/*.c",
        "src/backend/utils/hash/*.c",
        # System-catalog .dat seed files — consumed by rules_postgres'
        # Pg.Catalog.Dat round-trip gate (lean/Pg/Catalog/Dat.lean).
        # Pinning catalog truth to @postgres_src means a PG version
        # bump propagates as a single MODULE.bazel change instead of
        # a manual re-vendor.
        "src/include/catalog/*.dat",
    ], allow_empty = True),
)

# Every C source + header that meson's compile_commands.json might
# reference. Consumers depending on @postgres_src//:compile_commands.json
# typically want this as their srcs alongside (so the AST-dump action
# sees every #include target).
filegroup(
    name = "all_c_sources",
    srcs = glob(
        [
            "src/**/*.c",
            "src/**/*.h",
            "contrib/**/*.c",
            "contrib/**/*.h",
        ],
        allow_empty = True,
    ),
)

# Probe: compile one file from src/common/ as a feasibility test for
# the Bazel-driven PG build. Defines FRONTEND=1 to select the frontend
# include path (no backend-only palloc etc.).
cc_library(
    name = "pg_common_string",
    srcs = ["src/common/string.c"],
    hdrs = glob(["src/include/**/*.h"], allow_empty = True),
    includes = ["src/include"],
    defines = ["FRONTEND=1"],
    copts = [
        "-Wno-unused-function",
        "-Wno-unused-but-set-variable",
        "-Wno-deprecated-declarations",
        "-fno-strict-aliasing",
        "-fwrapv",
    ],
)
"""

def _fetch_libpg_query(version):
    """Fetch the libpg_query archive tag and overlay our own BUILD.

    Uses @rules_github//github:repositories.bzl%github_source_repository to pull
    the pganalyze/libpg_query tag, then lays our own BUILD overlay on it.
    """
    github_source_repository(
        name = "libpg_query",
        repo = "pganalyze/libpg_query",
        version = version,
        # libpg_query tags don't use a `v` prefix — the tag IS `17-6.2.2`.
        tag_format = "{version}",
        sha256 = LIBPG_QUERY_VERSIONS.get(version, ""),
        allow_unverified = True,
        build_file_content = _LIBPG_QUERY_BUILD,
    )

def _postgres_src_impl(rctx):
    version = rctx.attr.version
    sha256 = POSTGRES_SOURCE_VERSIONS.get(version, "")
    if not sha256:
        # buildifier: disable=print
        print(("rules_postgres: WARNING — no pinned sha256 for PostgreSQL " +
               "@%s; downloading unverified. Add an entry to " +
               "known_versions.bzl for hermetic builds.") % version)
    url = POSTGRES_SOURCE_URL_TEMPLATE.format(version = version)
    rctx.download_and_extract(
        url = url,
        sha256 = sha256 or "",
        stripPrefix = "postgresql-" + version,
    )

    # Layer the hand-written overlay headers into src/include/, replacing
    # what configure would have generated. The overlay assumes the
    # FRONTEND=1 build path (no backend palloc etc.) and a modern
    # darwin_aarch64 / linux_x86_64 host.
    #
    # Opt-out via `lay_overlay = False` in the pg.source extension tag:
    # consumers running `meson_configure` (via pg_meson_configure) MUST
    # opt out — the overlay shadows meson's correctly-generated pg_config.h
    # via clang's same-directory-first #include "..." search rule, which
    # in turn breaks deep backend TUs that depend on macros only meson's
    # generated headers define (e.g. INT64_MODIFIER).
    if rctx.attr.lay_overlay:
        for fname in ["pg_config.h", "pg_config_ext.h", "pg_config_os.h"]:
            rctx.symlink(
                Label("@rules_postgres//postgres/private:overlay/" + fname),
                "src/include/" + fname,
            )

    rctx.file("BUILD.bazel", _POSTGRES_SRC_BUILD)

_postgres_src_repository = repository_rule(
    implementation = _postgres_src_impl,
    attrs = {
        "version": attr.string(
            mandatory = True,
            doc = "PostgreSQL release version (e.g. \"17.6\").",
        ),
        "lay_overlay": attr.bool(
            default = True,
            doc = "Symlink hand-written pg_config{,_ext,_os}.h overlay " +
                  "headers into src/include/. Required by the legacy " +
                  "`pg_common_string` cc_library probe. Set False for " +
                  "consumers using pg_meson_configure — the overlay " +
                  "shadows meson's correctly-generated pg_config.h via " +
                  "clang's same-dir-first #include rule, breaking backend " +
                  "TU AST extraction.",
        ),
    },
    doc = "Fetch the PostgreSQL source tarball + lay a minimal BUILD overlay on top.",
)

def _pg_extension_impl(mctx):
    # Reduce tags across the dep graph. Root module wins; otherwise the
    # last-seen value takes precedence.
    query_version = None
    source_version = None
    source_lay_overlay = True
    for mod in mctx.modules:
        for tag in mod.tags.query:
            query_version = tag.version
        for tag in mod.tags.source:
            source_version = tag.version
            source_lay_overlay = tag.lay_overlay

    if query_version:
        _fetch_libpg_query(query_version)
    if source_version:
        _postgres_src_repository(
            name = "postgres_src",
            version = source_version,
            lay_overlay = source_lay_overlay,
        )

_query_tag = tag_class(
    attrs = {
        "version": attr.string(
            mandatory = True,
            doc = "libpg_query release tag (e.g. \"17-6.2.2\").",
        ),
    },
    doc = "Pull libpg_query as @libpg_query.",
)

_source_tag = tag_class(
    attrs = {
        "version": attr.string(
            mandatory = True,
            doc = "PostgreSQL release version (e.g. \"17.6\").",
        ),
        "lay_overlay": attr.bool(
            default = True,
            doc = "If True (default), symlink hand-written pg_config.h " +
                  "overlay headers into src/include/. Set False when " +
                  "using pg_meson_configure for AST extraction — see " +
                  "the lay_overlay attr on _postgres_src_repository for " +
                  "the shadowing-via-same-dir-#include explanation.",
        ),
    },
    doc = "Pull the PostgreSQL source tarball as @postgres_src.",
)

pg = module_extension(
    implementation = _pg_extension_impl,
    tag_classes = {
        "query": _query_tag,
        "source": _source_tag,
    },
    doc = "Module extension fetching libpg_query and/or the full PostgreSQL source tree.",
)
