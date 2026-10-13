-- ========================================================================
-- 003_onboarding_create_and_submit_request_ROLLBACK.sql
-- Reverses 003 only. Does not touch core.people/onboarding_records ROWS
-- (data), only the functions/triggers/grants this file created. Any
-- rows already created by this RPC before rollback are left exactly as
-- they are - rollback removes the mechanism, not the history.
--
-- Run in the canonical order (per the checklist): after
-- 007/006/004/005's rollbacks, before 002's.
-- ========================================================================

DROP TRIGGER IF EXISTS "trg_onboarding_on_workflow_status_change" ON "workflow"."status_history";
DROP FUNCTION IF EXISTS "onboarding"."_on_workflow_status_change"();

REVOKE ALL ON FUNCTION "onboarding"."create_and_submit_onboarding_request"(varchar, varchar, varchar, varchar, uuid, date) FROM "authenticated";
DROP FUNCTION IF EXISTS "onboarding"."create_and_submit_onboarding_request"(varchar, varchar, varchar, varchar, uuid, date);

-- ========================================================================
-- END 003_onboarding_create_and_submit_request_ROLLBACK.sql
-- ========================================================================
