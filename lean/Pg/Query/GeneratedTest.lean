/-
Pg.Query.GeneratedTest — hand-crafted `Pg.Query.ParseResult` value
that exercises the Phase 2 stubbed-DDL Generated.lean encoding.

If this typechecks, then any output of
`@rules_postgres//tools:pgpb_to_lean_ast` (which produces values of
the exact same shape from a `.pgpb` byte payload) also typechecks.
This is the kernel side of the trust chain:

  .sql → .pgpb → .lean
                  │
                  └─ Lean kernel checks against `Pg.Query.Generated`

A malformed pgpb_to_lean_ast output breaks `lake build` of any
consumer that imports the decoded value — so the decoder's
correctness is gated by the same trust profile as the rest of the
proto→Lean chain.

Three test values:
  * empty   — `ParseResult` with no stmts (version-only)
  * single  — one RawStmt with a small ByteArray payload
  * mixed   — multiple RawStmts with varying sizes
-/
import Pg.Query.Generated

namespace Pg.Query.GeneratedTest

open Pg.Query

/-- Empty parse: `SELECT;` produces no stmts. -/
def empty : ParseResult where
  version := 170007
  stmts   := []

/-- Single-stmt parse with a small opaque Node payload. The bytes
    here are illustrative — pgpb_to_lean_ast emits the actual
    re-packed protobuf for each stmt. -/
def single : ParseResult where
  version := 170007
  stmts   :=
    [ { stmt := (⟨#[0xE2, 0x08, 0x05, 0x0A, 0x03, 0x69, 0x64, 0x73]⟩ : _root_.ByteArray)
      , stmtLocation := 0
      , stmtLen      := 17 } ]

/-- Multi-stmt parse. Exercises the List structure of stmts. -/
def mixed : ParseResult where
  version := 170007
  stmts   :=
    [ { stmt := (⟨#[0x01, 0x02]⟩ : _root_.ByteArray), stmtLocation := 0,  stmtLen := 5 }
    , { stmt := (⟨#[0x03]⟩       : _root_.ByteArray), stmtLocation := 6,  stmtLen := 3 }
    , { stmt := _root_.ByteArray.empty,               stmtLocation := 10, stmtLen := 0 } ]

/-- Sanity: the version field round-trips. -/
example : single.version = 170007 := rfl

/-- Sanity: stmt-count via List.length. -/
example : mixed.stmts.length = 3 := rfl

end Pg.Query.GeneratedTest
