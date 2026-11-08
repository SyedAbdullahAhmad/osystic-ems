-- ========================================================================
-- 001_offboarding_schema_ROLLBACK.sql
-- Removes the whole offboarding schema. REFUSES to run if any Offboarding data exists
-- (a rollback must never silently destroy business records).
-- ROLLBACK ORDER (Track A): 009 -> 008 -> 007 -> 006 -> 005 -> 004 (workflow definitions seed) -> 003 -> 002 -> 001.
-- Every later Offboarding function, trigger and the workflow seed must already be rolled back; the
-- pre-flight refuses if any non-internal Offboarding function still exists.
-- ========================================================================
BEGIN;

DO $$
DECLARE v_t text; v_n bigint;
BEGIN
    IF to_regnamespace('offboarding') IS NULL THEN RAISE EXCEPTION '001 ROLLBACK PRE-FLIGHT: schema offboarding does not exist'; END IF;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'offboarding' AND p.proname NOT LIKE E'\\_%') > 0 THEN
        RAISE EXCEPTION '001 ROLLBACK PRE-FLIGHT: public Offboarding functions still exist - roll back 005-009 first'; END IF;
    -- 004 must already be rolled back: prove it independently instead of trusting the order note
    IF EXISTS (SELECT 1 FROM workflow.workflow_definitions WHERE module = 'offboarding') THEN
        RAISE EXCEPTION '001 ROLLBACK PRE-FLIGHT: offboarding workflow definitions still exist - roll back 004 first'; END IF;
    IF EXISTS (SELECT 1 FROM workflow.workflow_versions v JOIN workflow.workflow_definitions d ON d.id = v.workflow_definition_id WHERE d.module = 'offboarding')
       OR EXISTS (SELECT 1 FROM workflow.workflow_step_assignees WHERE permission_code = 'OFFBOARDING_MANAGE')
       OR EXISTS (SELECT 1 FROM workflow.approval_requests r JOIN workflow.workflow_definitions d ON d.id = r.workflow_definition_id WHERE d.module = 'offboarding') THEN
        RAISE EXCEPTION '001 ROLLBACK PRE-FLIGHT: offboarding workflow versions, step assignees or approval requests remain'; END IF;
    IF EXISTS (SELECT 1 FROM workflow._seed_provenance WHERE seeded_by_migration LIKE '004\_offboarding%') THEN
        RAISE EXCEPTION '001 ROLLBACK PRE-FLIGHT: 004 seed provenance rows remain'; END IF;
    FOREACH v_t IN ARRAY ARRAY['cases','clearance_tasks','request_idempotency','case_history','outbox_events','outbox_delivery'] LOOP
        IF to_regclass('offboarding.' || v_t) IS NULL THEN RAISE EXCEPTION '001 ROLLBACK PRE-FLIGHT: offboarding.% missing', v_t; END IF;
        EXECUTE format('SELECT count(*) FROM offboarding.%I', v_t) INTO v_n;
        IF v_n > 0 THEN RAISE EXCEPTION '001 ROLLBACK PRE-FLIGHT: offboarding.% holds % row(s); refusing to drop business data', v_t, v_n; END IF;
    END LOOP;
END;
$$;

DROP SCHEMA "offboarding" CASCADE;

DO $$
BEGIN
    IF to_regnamespace('offboarding') IS NOT NULL THEN RAISE EXCEPTION '001 ROLLBACK POST-CHECK: schema offboarding still exists'; END IF;
    IF to_regtype('offboarding.case_status') IS NOT NULL THEN RAISE EXCEPTION '001 ROLLBACK POST-CHECK: offboarding types still exist'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 001_offboarding_schema_ROLLBACK.sql
-- ========================================================================
