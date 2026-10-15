-- ========================================================================
-- 008_onboarding_candidate_identity_projection_ROLLBACK.sql
-- Pure function drop: 008 creates no table, no data and no grant on any
-- other object, so this fully restores the pre-008 state. Canonical order:
-- 008 (this file) -> 007 -> 006 -> 004 -> 005 -> 003 -> 002 -> 001.
-- ========================================================================
REVOKE ALL ON FUNCTION "onboarding"."get_candidate_identities"(uuid[]) FROM "authenticated";
DROP FUNCTION IF EXISTS "onboarding"."get_candidate_identities"(uuid[]);
-- ========================================================================
-- END 008_onboarding_candidate_identity_projection_ROLLBACK.sql
-- ========================================================================
