-- ========================================================================
-- 008_offboarding_complete_ROLLBACK.sql  -  removes the completion function and its helpers (data untouched).
-- NOTE: completed cases, terminated employees/contracts and outbox events already written are business records and are NOT reverted.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regprocedure('offboarding.complete_offboarding(uuid,character varying)') IS NULL THEN
        RAISE EXCEPTION '008 ROLLBACK PRE-FLIGHT: 008 does not appear to be applied'; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname LIKE 'list\_%' ) THEN
        RAISE EXCEPTION '008 ROLLBACK PRE-FLIGHT: 009 read projections still exist - roll them back first'; END IF;
END;
$$;

DROP FUNCTION "offboarding"."complete_offboarding"(uuid, varchar);
DROP FUNCTION "offboarding"."_completion_blockers"(uuid);
DROP FUNCTION "offboarding"."_business_date"();

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname IN ('complete_offboarding', '_completion_blockers', '_business_date')) THEN
        RAISE EXCEPTION '008 ROLLBACK POST-CHECK: 008 functions remain'; END IF;
    IF to_regprocedure('offboarding.withdraw_resignation(uuid,text,character varying)') IS NULL THEN
        RAISE EXCEPTION '008 ROLLBACK POST-CHECK: the post-007 function set was damaged'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 008_offboarding_complete_ROLLBACK.sql
-- ========================================================================
