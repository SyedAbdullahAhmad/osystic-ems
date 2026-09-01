-- ===========================================================
-- PHASE 1 - STEP 2
-- PostgreSQL Extensions
-- ===========================================================

-- UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Case-insensitive text
CREATE EXTENSION IF NOT EXISTS "citext";

-- Advanced indexing
CREATE EXTENSION IF NOT EXISTS "btree_gist";

-- Optional: cryptographic functions
CREATE EXTENSION IF NOT EXISTS "pg_trgm";