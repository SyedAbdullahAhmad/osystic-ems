-- ========================================================================
-- 006_offboarding_clearance_rpcs_ROLLBACK.sql  -  removes the clearance RPCs (data untouched).
-- Roll back 007-009 first.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regprocedure('offboarding.record_clearance(uuid,character varying,text,character varying)') IS NULL THEN
        RAISE EXCEPTION '006 ROLLBACK PRE-FLIGHT: 006 does not appear to be applied'; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname IN ('withdraw_resignation', 'cancel_termination', 'complete_offboarding')) THEN
        RAISE EXCEPTION '006 ROLLBACK PRE-FLIGHT: later Offboarding functions (007-009) still exist - roll them back first'; END IF;
END;
$$;

DROP FUNCTION "offboarding"."waive_clearance"(uuid, varchar, text, varchar);
DROP FUNCTION "offboarding"."record_clearance"(uuid, varchar, text, varchar);
DROP FUNCTION "offboarding"."_clearance_action"(uuid, uuid, text, text, text, varchar);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname IN ('record_clearance', 'waive_clearance', '_clearance_action')) THEN
        RAISE EXCEPTION '006 ROLLBACK POST-CHECK: 006 functions remain'; END IF;
    IF to_regprocedure('offboarding.start_resignation(character varying,date,character varying,text)') IS NULL THEN
        RAISE EXCEPTION '006 ROLLBACK POST-CHECK: the post-005 function set was damaged'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 006_offboarding_clearance_rpcs_ROLLBACK.sql
-- ========================================================================
