-- ========================================================================
-- 007_withdraw_onboarding_request_ROLLBACK.sql
-- Reverses 007 only: drops the withdrawal RPC. Does not touch any
-- onboarding_records already set to WITHDRAWN, nor the workflow
-- requests already cancelled through it - those are data/history, not
-- this migration's own objects.
--
-- Run FIRST in the canonical order (per the checklist): before
-- 006/004/005/003/002/001's rollbacks.
-- ========================================================================

REVOKE ALL ON FUNCTION "onboarding"."withdraw_onboarding_request"(uuid, text) FROM "authenticated";
DROP FUNCTION IF EXISTS "onboarding"."withdraw_onboarding_request"(uuid, text);

-- ========================================================================
-- END 007_withdraw_onboarding_request_ROLLBACK.sql
-- ========================================================================
