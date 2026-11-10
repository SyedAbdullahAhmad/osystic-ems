-- ========================================================================
-- 009_offboarding_read_projections_ROLLBACK.sql  -  removes the read projections (data untouched)
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regprocedure('offboarding.get_case(uuid)') IS NULL THEN RAISE EXCEPTION '009 ROLLBACK PRE-FLIGHT: 009 does not appear to be applied'; END IF;
END;
$$;

DROP FUNCTION "offboarding"."get_completion_readiness"(uuid);
DROP FUNCTION "offboarding"."list_cases"(text, text, date, date, text, boolean, integer, integer);
DROP FUNCTION "offboarding"."get_case_identities"(uuid[]);
DROP FUNCTION "offboarding"."get_case_history"(uuid);
DROP FUNCTION "offboarding"."get_case_tasks"(uuid);
DROP FUNCTION "offboarding"."get_case"(uuid);
DROP FUNCTION "offboarding"."_case_access"(uuid, uuid);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname IN ('list_cases', 'get_case', 'get_case_tasks', 'get_case_history', 'get_case_identities', 'get_completion_readiness', '_case_access')) THEN
        RAISE EXCEPTION '009 ROLLBACK POST-CHECK: 009 functions remain'; END IF;
    IF to_regprocedure('offboarding.complete_offboarding(uuid,character varying)') IS NULL THEN
        RAISE EXCEPTION '009 ROLLBACK POST-CHECK: the post-008 function set was damaged'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 009_offboarding_read_projections_ROLLBACK.sql
-- ========================================================================
