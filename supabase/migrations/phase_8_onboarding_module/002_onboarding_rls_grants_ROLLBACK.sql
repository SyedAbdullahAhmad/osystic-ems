-- ========================================================================
-- 002_onboarding_rls_grants_ROLLBACK.sql  (v3)
-- Reverses 002 only. Does not touch core.*, workflow.*, or any other
-- schema's grants/policies.
-- Run in the canonical order (per the checklist): after
-- 007/006/004/005's rollbacks and 003's rollback, before 001's.
-- ========================================================================

DROP POLICY IF EXISTS "onboarding_records_select" ON "onboarding"."onboarding_records";

DROP TRIGGER IF EXISTS "trg_onboarding_records_updated_by" ON "onboarding"."onboarding_records";
DROP TRIGGER IF EXISTS "trg_onboarding_records_created_by" ON "onboarding"."onboarding_records";

DROP FUNCTION IF EXISTS "onboarding"."_force_updated_by"();
DROP FUNCTION IF EXISTS "onboarding"."_force_created_by"();

ALTER TABLE "onboarding"."onboarding_records" DISABLE ROW LEVEL SECURITY;
ALTER TABLE "onboarding"."request_idempotency" DISABLE ROW LEVEL SECURITY;

REVOKE SELECT ON "onboarding"."onboarding_records" FROM "authenticated";
-- request_idempotency: no grant exists to revoke (item 4, round 3) -
-- nothing to do here.
REVOKE USAGE ON SCHEMA "onboarding" FROM "authenticated";

-- ========================================================================
-- END 002_onboarding_rls_grants_ROLLBACK.sql
-- ========================================================================
