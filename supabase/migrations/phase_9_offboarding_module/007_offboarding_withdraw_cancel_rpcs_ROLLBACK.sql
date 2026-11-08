-- ========================================================================
-- 007_offboarding_withdraw_cancel_rpcs_ROLLBACK.sql  -  removes the withdrawal/cancellation RPCs (data untouched).
-- Roll back 008-009 first.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regprocedure('offboarding.withdraw_resignation(uuid,text,character varying)') IS NULL THEN
        RAISE EXCEPTION '007 ROLLBACK PRE-FLIGHT: 007 does not appear to be applied'; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname = 'complete_offboarding') THEN
        RAISE EXCEPTION '007 ROLLBACK PRE-FLIGHT: later Offboarding functions (008-009) still exist - roll them back first'; END IF;
END;
$$;

DROP FUNCTION "offboarding"."cancel_termination"(uuid, text, varchar);
DROP FUNCTION "offboarding"."withdraw_resignation"(uuid, text, varchar);
DROP FUNCTION "offboarding"."_close_case"(uuid, uuid, text, text, varchar, boolean);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname IN ('withdraw_resignation', 'cancel_termination', '_close_case')) THEN
        RAISE EXCEPTION '007 ROLLBACK POST-CHECK: 007 functions remain'; END IF;
    IF to_regprocedure('offboarding.record_clearance(uuid,character varying,text,character varying)') IS NULL THEN
        RAISE EXCEPTION '007 ROLLBACK POST-CHECK: the post-006 function set was damaged'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 007_offboarding_withdraw_cancel_rpcs_ROLLBACK.sql
-- ========================================================================
