-- ========================================================================
-- 006_confirm_employee_hire_ROLLBACK.sql
-- Reverses 006 only: the RPC, the consistency-guard trigger and its
-- function. Does NOT touch any hr.employees/core.people rows already
-- created by confirm_employee_hire() before rollback - those are real
-- hire records (data), not part of this migration's own objects, and
-- are explicitly out of scope for an ownership-safe rollback (same
-- principle as 003's rollback note on onboarding_records).
--
-- Run in the canonical order (per the checklist): after 007's
-- rollback, before 004/005/003/002/001's.
-- ========================================================================

DROP TRIGGER IF EXISTS "trg_onboarding_records_enforce_hired_consistency" ON "onboarding"."onboarding_records";
DROP FUNCTION IF EXISTS "onboarding"."_enforce_hired_consistency"();

REVOKE ALL ON FUNCTION "onboarding"."confirm_employee_hire"(uuid, varchar, date) FROM "authenticated";
DROP FUNCTION IF EXISTS "onboarding"."confirm_employee_hire"(uuid, varchar, date);

-- ========================================================================
-- END 006_confirm_employee_hire_ROLLBACK.sql
-- ========================================================================
