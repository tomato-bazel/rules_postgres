-- Smoke fixture for the proto → Lean trust chain.
--
-- Covers four DDL stmt kinds the Phase 2 Generated.lean models:
--   CREATE SCHEMA, CREATE DOMAIN, CREATE TYPE (composite),
--   CREATE TABLE.
--
-- The end-to-end gate:
--   1. sql_to_protobuf parses this into a .pgpb byte payload.
--   2. pgpb_to_lean_ast decodes the bytes into Lean source.
--   3. lean_test imports Pg.Query.Generated + the decoder output
--      and verifies the value typechecks against the generated
--      ParseResult / RawStmt structures.
-- If any link breaks, the test fails.
CREATE SCHEMA test_smoke;

CREATE DOMAIN test_smoke.identifier AS TEXT
    CHECK (VALUE ~ '^[a-z][a-z0-9_]*$');

CREATE TYPE test_smoke.point AS (x INTEGER, y INTEGER);

CREATE TABLE test_smoke.locations (
    id BIGINT PRIMARY KEY,
    name test_smoke.identifier NOT NULL,
    position test_smoke.point NOT NULL
);
