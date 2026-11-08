-- ========================================================================
-- 004_offboarding_workflow_definitions_SEED_ROLLBACK.sql
-- CASE 1 (Track A, never seeded): nothing to delete; drops the seed function.
-- CASE 2 (seeded): refuses if any seeded version is ACTIVE/RETIRED (activated workflow
-- configuration is immutable) or if any approval request references a seeded definition.
-- After success it PROVES both Offboarding definitions and every dependent row are gone.
-- ========================================================================
BEGIN;

DO $$
DECLARE
    v_def_ids uuid[]; v_version_ids uuid[]; v_locked int; v_requests int;
BEGIN
    IF to_regprocedure('offboarding.seed_offboarding_workflow_definitions()') IS NULL THEN
        RAISE EXCEPTION '004 ROLLBACK PRE-FLIGHT: seed function does not exist (004 not applied?)'; END IF;
    SELECT array_agg(DISTINCT record_id) INTO v_def_ids FROM workflow._seed_provenance
     WHERE seeded_by_migration = '004_offboarding_workflow_definitions_SEED' AND schema_name = 'workflow' AND table_name = 'workflow_definitions';
    IF EXISTS (SELECT 1 FROM workflow.workflow_definitions WHERE module = 'offboarding'
               AND (v_def_ids IS NULL OR id <> ALL (v_def_ids))) THEN
        RAISE EXCEPTION '004 ROLLBACK PRE-FLIGHT: an offboarding workflow definition exists that this seed did not create'; END IF;
    IF v_def_ids IS NOT NULL THEN
        SELECT array_agg(DISTINCT record_id) INTO v_version_ids FROM workflow._seed_provenance
         WHERE seeded_by_migration = '004_offboarding_workflow_definitions_SEED' AND schema_name = 'workflow' AND table_name = 'workflow_versions';
        SELECT count(*) INTO v_locked FROM workflow.workflow_versions
         WHERE id = ANY (coalesce(v_version_ids, ARRAY[]::uuid[])) AND status IN ('ACTIVE', 'RETIRED');
        IF v_locked > 0 THEN
            RAISE EXCEPTION 'OFFBOARDING_ROLLBACK_BLOCKED_ACTIVE_WORKFLOW: % seeded offboarding workflow version(s) are ACTIVE or RETIRED; activated configuration is immutable. Use Track A (fresh database, never seeded) for rollback proof.', v_locked; END IF;
        SELECT count(*) INTO v_requests FROM workflow.approval_requests WHERE workflow_definition_id = ANY (v_def_ids);
        IF v_requests > 0 THEN
            RAISE EXCEPTION 'OFFBOARDING_ROLLBACK_BLOCKED: % approval request(s) reference a seeded offboarding definition', v_requests; END IF;

        DELETE FROM workflow.workflow_step_assignees WHERE id IN (SELECT record_id FROM workflow._seed_provenance WHERE seeded_by_migration = '004_offboarding_workflow_definitions_SEED' AND table_name = 'workflow_step_assignees');
        DELETE FROM workflow.workflow_steps          WHERE id IN (SELECT record_id FROM workflow._seed_provenance WHERE seeded_by_migration = '004_offboarding_workflow_definitions_SEED' AND table_name = 'workflow_steps');
        DELETE FROM workflow.transition_rules        WHERE id IN (SELECT record_id FROM workflow._seed_provenance WHERE seeded_by_migration = '004_offboarding_workflow_definitions_SEED' AND table_name = 'transition_rules');
        DELETE FROM workflow.workflow_statuses       WHERE id IN (SELECT record_id FROM workflow._seed_provenance WHERE seeded_by_migration = '004_offboarding_workflow_definitions_SEED' AND table_name = 'workflow_statuses');
        DELETE FROM workflow.workflow_versions       WHERE id IN (SELECT record_id FROM workflow._seed_provenance WHERE seeded_by_migration = '004_offboarding_workflow_definitions_SEED' AND table_name = 'workflow_versions');
        DELETE FROM workflow.workflow_definitions    WHERE id = ANY (v_def_ids);
        DELETE FROM workflow._seed_provenance        WHERE seeded_by_migration = '004_offboarding_workflow_definitions_SEED';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION "offboarding"."seed_offboarding_workflow_definitions"() FROM "authenticated";
DROP FUNCTION "offboarding"."seed_offboarding_workflow_definitions"();

-- Explicit proof for the Track A rollback chain (required before 001 may drop the schema)
DO $$
BEGIN
    IF to_regprocedure('offboarding.seed_offboarding_workflow_definitions()') IS NOT NULL THEN RAISE EXCEPTION '004 ROLLBACK POST-CHECK: seed function still exists'; END IF;
    IF EXISTS (SELECT 1 FROM workflow.workflow_definitions WHERE module = 'offboarding') THEN RAISE EXCEPTION '004 ROLLBACK POST-CHECK: an offboarding workflow definition remains'; END IF;
    IF EXISTS (SELECT 1 FROM workflow.workflow_versions v WHERE NOT EXISTS (SELECT 1 FROM workflow.workflow_definitions d WHERE d.id = v.workflow_definition_id)) THEN
        RAISE EXCEPTION '004 ROLLBACK POST-CHECK: orphan workflow versions remain'; END IF;
    IF EXISTS (SELECT 1 FROM workflow._seed_provenance WHERE seeded_by_migration = '004_offboarding_workflow_definitions_SEED') THEN
        RAISE EXCEPTION '004 ROLLBACK POST-CHECK: seed provenance rows remain'; END IF;
    IF EXISTS (SELECT 1 FROM workflow.workflow_step_assignees WHERE permission_code = 'OFFBOARDING_MANAGE') THEN
        RAISE EXCEPTION '004 ROLLBACK POST-CHECK: an OFFBOARDING_MANAGE step assignee remains'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 004_offboarding_workflow_definitions_SEED_ROLLBACK.sql
-- ========================================================================
