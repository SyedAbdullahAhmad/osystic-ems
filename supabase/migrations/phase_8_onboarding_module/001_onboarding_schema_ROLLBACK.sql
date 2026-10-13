-- ========================================================================
-- 001_onboarding_schema_ROLLBACK.sql
-- Reverses 001_onboarding_schema.sql only. Ownership-safe: everything
-- here is onboarding-owned (its own schema, types, tables, functions,
-- triggers). Nothing outside the onboarding schema is touched or
-- deleted - core.people/core.departments/workflow.approval_requests
-- rows referenced by FK are left exactly as they are.
--
-- Run in this order relative to the other rollback files (the
-- canonical order, per the checklist): 007, 006, 004, 005, 003, 002,
-- THEN this one last - 001 is the foundation every later file depends
-- on, so it must be the last thing dropped.
-- ========================================================================

DROP TRIGGER IF EXISTS "trg_onboarding_records_status_transition" ON "onboarding"."onboarding_records";
DROP FUNCTION IF EXISTS "onboarding"."_enforce_status_transition"();

DROP TABLE IF EXISTS "onboarding"."request_idempotency";

DROP INDEX IF EXISTS "onboarding"."idx_onboarding_records_department";
DROP INDEX IF EXISTS "onboarding"."idx_onboarding_records_status";
DROP INDEX IF EXISTS "onboarding"."idx_onboarding_records_person";
DROP INDEX IF EXISTS "onboarding"."idx_onboarding_records_workflow_request_unique";
DROP INDEX IF EXISTS "onboarding"."idx_onboarding_records_one_open_per_person";

DROP TABLE IF EXISTS "onboarding"."onboarding_records";

DROP TYPE IF EXISTS "onboarding"."onboarding_status";

-- Only drop the schema itself if nothing else was left behind in it -
-- IF EXISTS plus the lack of CASCADE means this is a no-op (and raises
-- a clear "schema not empty" error, not a silent partial drop) if any
-- other object still lives in "onboarding" that this rollback set
-- doesn't know about - a deliberate safety stop, not an oversight.
DROP SCHEMA IF EXISTS "onboarding";

-- ========================================================================
-- END 001_onboarding_schema_ROLLBACK.sql
-- ========================================================================
