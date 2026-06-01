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

CREATE OR REPLACE FUNCTION test_smoke.distance(
    p_a test_smoke.point,
    p_b test_smoke.point
) RETURNS DOUBLE PRECISION
LANGUAGE SQL
AS $$
    SELECT sqrt(power(p_a.x - p_b.x, 2) + power(p_a.y - p_b.y, 2))::double precision;
$$;

ALTER TABLE test_smoke.locations ADD COLUMN created_at TIMESTAMPTZ NOT NULL;
ALTER TABLE test_smoke.locations ALTER COLUMN name DROP NOT NULL;

-- Phase 4: exercise three target-expr shapes — qualified ColumnRef,
-- bare ColumnRef, and a non-ColumnRef expression that the fold
-- collapses to z.unknown (OID 2249 = record).
CREATE OR REPLACE VIEW test_smoke.location_summary AS
SELECT
    l.id,                                    -- qualified ColumnRef → bigint
    name,                                    -- bare ColumnRef     → identifier (domain over text)
    EXTRACT(epoch FROM created_at) AS epoch  -- function call      → unknown (2249)
FROM test_smoke.locations l;
