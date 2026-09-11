-- ========================================================================
-- 004_contract_request_workflow_definition_SEED.sql
--
-- Same "requires a real authenticated admin session" constraint as
-- every other module's 004 seed file (workflow._force_created_by()
-- hard-requires auth.uid() IS NOT NULL on workflow_definitions/
-- workflow_versions). Function creation itself is a normal migration;
-- calling it is not - same split as before.
--
-- DIFFERENCE FROM ASSETS: initiation_permission_code is set to
-- CONTRACT_MANAGE here, not NULL. Assets left it NULL because any
-- employee can submit an asset request; Contracts is HR/Admin-initiated
-- only per team lead's decision, so the workflow engine itself enforces
-- that restriction too (confirmed this is a real, enforced check in
-- phase_2_workflow_engine/004_workflow_functions_triggers.sql before
-- relying on it - see 003's header for detail), on top of the create
-- RPC's own explicit check.
--
-- Same as Assets, NOT like Leave/Attendance: this step's assignee is
-- PERMISSION-based (CONTRACT_MANAGE), resolved dynamically - no
-- test-admin placeholder, no HR/org-structure blocker.
--
-- OPERATIONAL PRECONDITION (not a design blocker, just needs doing once):
-- at least one real user must actually hold CONTRACT_MANAGE for both
-- creation and the approval step to have anyone eligible.
-- ========================================================================

CREATE OR REPLACE FUNCTION "hr"."seed_contract_request_workflow_definition"()
RETURNS uuid
LANGUAGE plpgsql
SET search_path = pg_catalog, "hr", "workflow"
AS $$
DECLARE
    v_def_id uuid;
    v_ver_id uuid;
    v_step1_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'CONTRACTS_SEED_REQUIRES_AUTHENTICATED_ADMIN: set your session before calling this';
    END IF;

    IF EXISTS (SELECT 1 FROM "workflow"."workflow_definitions" WHERE "module" = 'contracts' AND "code" = 'CONTRACT_APPROVAL') THEN
        SELECT "id" INTO v_def_id FROM "workflow"."workflow_definitions" WHERE "module" = 'contracts' AND "code" = 'CONTRACT_APPROVAL';
        RAISE NOTICE 'CONTRACT_APPROVAL already exists (id=%), skipping', v_def_id;
        RETURN v_def_id;
    END IF;

    INSERT INTO "workflow"."workflow_definitions" ("module", "code", "name", "initiation_permission_code")
    VALUES ('contracts', 'CONTRACT_APPROVAL', 'Contract Approval', 'CONTRACT_MANAGE')
    RETURNING "id" INTO v_def_id;

    INSERT INTO "workflow"."workflow_versions" ("workflow_definition_id", "version_no", "status")
    VALUES (v_def_id, 1, 'DRAFT')
    RETURNING "id" INTO v_ver_id;

    INSERT INTO "workflow"."workflow_statuses" ("workflow_version_id", "workflow_definition_id", "status_code", "display_name", "is_initial", "is_terminal")
    VALUES
        (v_ver_id, v_def_id, 'PENDING', 'Pending Approval', true, false),
        (v_ver_id, v_def_id, 'APPROVED', 'Approved', false, true),
        (v_ver_id, v_def_id, 'REJECTED', 'Rejected', false, true);

    INSERT INTO "workflow"."transition_rules" ("workflow_version_id", "workflow_definition_id", "from_status", "to_status", "trigger_action", "is_maker_checker")
    VALUES
        (v_ver_id, v_def_id, 'PENDING', 'APPROVED', 'APPROVE', false),
        (v_ver_id, v_def_id, 'PENDING', 'REJECTED', 'REJECT', false);

    INSERT INTO "workflow"."workflow_steps" (
        "workflow_version_id", "step_key", "step_no", "sequence_no", "step_name",
        "approval_mode", "is_maker_checker", "rejection_mode", "sla_minutes"
    ) VALUES
        (v_ver_id, 'contract_approval', 1, 1, 'Contract Approval', 'ONE_OF', false, 'ANY_REJECT', 2880)
    RETURNING "id" INTO v_step1_id;

    INSERT INTO "workflow"."workflow_step_assignees" ("workflow_step_id", "assignee_type", "permission_code")
    VALUES (v_step1_id, 'PERMISSION', 'CONTRACT_MANAGE');

    PERFORM "workflow"."activate_workflow_version"(v_ver_id);

    RAISE NOTICE 'CONTRACT_APPROVAL created and ACTIVATED (id=%, version_id=%). No placeholder assignee needed - resolves CONTRACT_MANAGE holders at request time. Make sure at least one real user actually holds CONTRACT_MANAGE before testing.',
        v_def_id, v_ver_id;

    RETURN v_def_id;
END;
$$;

REVOKE ALL ON FUNCTION "hr"."seed_contract_request_workflow_definition"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "hr"."seed_contract_request_workflow_definition"() TO "authenticated";

-- Run this once you've set your admin session:
-- SELECT "hr"."seed_contract_request_workflow_definition"();

-- ========================================================================
-- END 004_contract_request_workflow_definition_SEED.sql
-- ========================================================================
