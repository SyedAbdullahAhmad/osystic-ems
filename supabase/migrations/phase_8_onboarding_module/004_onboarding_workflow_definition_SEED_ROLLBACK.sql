-- ========================================================================
-- 004_onboarding_workflow_definition_SEED_ROLLBACK.sql  (v8 - corrected
-- per Shawaiz's round-7 decision, items C/D)
--
-- WHAT THIS ROLLBACK CAN AND CANNOT DO (read this first)
--
--   CASE 1 - seed FUNCTION installed, but never invoked
--            (no workflow._seed_provenance rows for this migration):
--            Rollback is fully supported. It simply drops
--            onboarding.seed_onboarding_workflow_definition().
--            This is the case the migration-reversibility proof (Track A
--            in the checklist) uses.
--
--   CASE 2 - the seed function WAS invoked, so an ONBOARDING workflow
--            version was created AND ACTIVATED (the seed calls
--            workflow.activate_workflow_version() as its last step):
--            The activated configuration is IMMUTABLE and is NOT removed
--            by Phase 8 rollback. This script detects it up front and
--            raises ONBOARDING_ROLLBACK_BLOCKED_ACTIVE_WORKFLOW before
--            deleting anything. Nothing is partially rolled back.
--
-- WHY CASE 2 CANNOT BE DELETED (corrects the v3-v7 header of this file)
--
--   Earlier versions of this header claimed there was no DELETE-blocking
--   trigger on the workflow configuration tables. THAT WAS WRONG. The
--   check only looked at phase_2_workflow_engine/
--   004_workflow_functions_triggers.sql and missed
--   phase_2_workflow_engine/005_workflow_rls_grants.sql, which installs
--   BEFORE INSERT OR UPDATE OR DELETE triggers on:
--       workflow.workflow_steps
--       workflow.workflow_statuses
--       workflow.transition_rules
--       workflow.workflow_step_assignees
--   that raise WORKFLOW_VERSION_IMMUTABLE for any change once the parent
--   version is ACTIVE or RETIRED (e.g. WORKFLOW_VERSION_IMMUTABLE: cannot
--   DELETE workflow_step_assignees for a step belonging to an ACTIVE or
--   RETIRED workflow version, raised by
--   workflow.prevent_active_version_assignee_mutation()).
--   Triggers apply to every role, so this is not a grants/RLS matter, and
--   there is no sanctioned "retract version" function in the engine.
--
--   This is a SHARED WORKFLOW-ENGINE CHARACTERISTIC, not a Phase 8
--   defect: Leave, Attendance, Assets and Contracts have the same
--   property. This script does not, and must never, disable triggers,
--   change version status directly, use CASCADE, or otherwise weaken the
--   engine's immutability. If a retraction mechanism is ever wanted, it
--   has to be added to the shared engine (and regression-tested across
--   all five modules), not patched in here.
--
-- DETERMINISTIC PROVENANCE: when deletes ARE permitted (Case 1 never
-- reaches them; the only other possible case is a seed that stopped
-- before activation, leaving a DRAFT version), only the exact rows 004
-- recorded in workflow."_seed_provenance" are deleted - never "everything
-- matching module/code".
--
-- Canonical rollback order: 008, 007, 006, 004 (this file), 005, 003, 002,
-- 001. This file must run BEFORE 005 (005 removes the
-- ONBOARDING_MANAGE permission row that seeded data still references).
-- ========================================================================

DO $$
DECLARE
    v_def_ids        uuid[];
    v_version_ids    uuid[];
    v_locked_count   int;
    v_open_requests  int;
BEGIN
    SELECT array_agg(DISTINCT "record_id") INTO v_def_ids
    FROM "workflow"."_seed_provenance"
    WHERE "seeded_by_migration" = '004_onboarding_workflow_definition_SEED'
      AND "schema_name" = 'workflow' AND "table_name" = 'workflow_definitions';

    -- CASE 1: seed function never invoked -> nothing to remove here.
    IF v_def_ids IS NULL OR array_length(v_def_ids, 1) IS NULL THEN
        RAISE NOTICE 'CASE 1: no workflow._seed_provenance rows for 004_onboarding_workflow_definition_SEED - the seed function was never invoked (or was already rolled back). Only the seed function itself will be dropped below.';
        RETURN;
    END IF;

    SELECT array_agg(DISTINCT "record_id") INTO v_version_ids
    FROM "workflow"."_seed_provenance"
    WHERE "seeded_by_migration" = '004_onboarding_workflow_definition_SEED'
      AND "schema_name" = 'workflow' AND "table_name" = 'workflow_versions';

    -- CASE 2 fail-fast: any ACTIVE/RETIRED seeded version is permanent.
    SELECT count(*) INTO v_locked_count
    FROM "workflow"."workflow_versions"
    WHERE "id" = ANY(COALESCE(v_version_ids, ARRAY[]::uuid[]))
      AND "status" IN ('ACTIVE', 'RETIRED');

    IF v_locked_count > 0 THEN
        RAISE EXCEPTION 'ONBOARDING_ROLLBACK_BLOCKED_ACTIVE_WORKFLOW: % seeded onboarding workflow version(s) are ACTIVE or RETIRED (workflow definition id(s): %). Activated workflow configuration is immutable (triggers from phase_2_workflow_engine/005_workflow_rls_grants.sql) and is intentionally NOT removed by Phase 8 rollback. Nothing was deleted and the seed function was left in place. To prove migration reversibility, use a fresh scratch database where seed_onboarding_workflow_definition() was NEVER called (checklist Track A).', v_locked_count, v_def_ids;
    END IF;

    -- Only reachable for a seed that never reached activation (DRAFT).
    SELECT count(*) INTO v_open_requests
    FROM "workflow"."approval_requests"
    WHERE "workflow_definition_id" = ANY(v_def_ids);

    IF v_open_requests > 0 THEN
        RAISE EXCEPTION 'ONBOARDING_ROLLBACK_BLOCKED: % workflow.approval_requests row(s) still reference a workflow_definition this seed created.', v_open_requests;
    END IF;

    DELETE FROM "workflow"."workflow_step_assignees"
    WHERE "id" IN (SELECT "record_id" FROM "workflow"."_seed_provenance"
        WHERE "seeded_by_migration" = '004_onboarding_workflow_definition_SEED' AND "table_name" = 'workflow_step_assignees');
    DELETE FROM "workflow"."workflow_steps"
    WHERE "id" IN (SELECT "record_id" FROM "workflow"."_seed_provenance"
        WHERE "seeded_by_migration" = '004_onboarding_workflow_definition_SEED' AND "table_name" = 'workflow_steps');
    DELETE FROM "workflow"."transition_rules"
    WHERE "id" IN (SELECT "record_id" FROM "workflow"."_seed_provenance"
        WHERE "seeded_by_migration" = '004_onboarding_workflow_definition_SEED' AND "table_name" = 'transition_rules');
    DELETE FROM "workflow"."workflow_statuses"
    WHERE "id" IN (SELECT "record_id" FROM "workflow"."_seed_provenance"
        WHERE "seeded_by_migration" = '004_onboarding_workflow_definition_SEED' AND "table_name" = 'workflow_statuses');
    DELETE FROM "workflow"."workflow_versions"
    WHERE "id" IN (SELECT "record_id" FROM "workflow"."_seed_provenance"
        WHERE "seeded_by_migration" = '004_onboarding_workflow_definition_SEED' AND "table_name" = 'workflow_versions');
    DELETE FROM "workflow"."workflow_definitions" WHERE "id" = ANY(v_def_ids);

    DELETE FROM "workflow"."_seed_provenance"
    WHERE "seeded_by_migration" = '004_onboarding_workflow_definition_SEED';

    RAISE NOTICE 'Unactivated ONBOARDING_OFFER_APPROVAL seed data removed (definition id(s): %).', v_def_ids;
END;
$$;

-- Reached only in CASE 1 (or an unactivated seed). If the DO block above
-- raised, the script stops here and nothing below executes.
REVOKE ALL ON FUNCTION "onboarding"."seed_onboarding_workflow_definition"() FROM "authenticated";
DROP FUNCTION IF EXISTS "onboarding"."seed_onboarding_workflow_definition"();

-- ========================================================================
-- END 004_onboarding_workflow_definition_SEED_ROLLBACK.sql
-- ========================================================================
