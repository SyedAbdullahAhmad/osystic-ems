-- ========================================================================
-- 004_asset_request_workflow_definition_SEED.sql
--
-- Same "requires a real authenticated admin session" constraint as
-- leave's and attendance's 004 seed files (workflow._force_created_by()
-- hard-requires auth.uid() IS NOT NULL on workflow_definitions/
-- workflow_versions). Function creation itself is a normal migration;
-- calling it is not - same split as before.
--
-- THE DIFFERENCE FROM LEAVE/ATTENDANCE: this step's assignee is
-- PERMISSION-based (ASSET_MANAGE), not a fixed user or a role name
-- waiting on Finance's UAT project. workflow.start_approval_request()
-- resolves PERMISSION assignees dynamically at request time by finding
-- whoever currently holds that permission (see
-- phase_2_workflow_engine/004_workflow_functions_triggers.sql's
-- assignee-resolution logic) - so this seed can activate the version
-- immediately, no test-admin placeholder, no version-2-later TODO.
--
-- OPERATIONAL PRECONDITION (not a design blocker, just needs doing once):
-- at least one real user must actually hold ASSET_MANAGE for the step to
-- have anyone eligible. Grant it via core.role_permissions (if an
-- existing role should have it) or directly via core.user_roles - your
-- call, same as any other permission grant in this system.
-- ========================================================================

CREATE OR REPLACE FUNCTION "assets"."seed_asset_request_workflow_definition"()
RETURNS uuid
LANGUAGE plpgsql
SET search_path = pg_catalog, "assets", "workflow"
AS $$
DECLARE
    v_def_id uuid;
    v_ver_id uuid;
    v_step1_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'ASSETS_SEED_REQUIRES_AUTHENTICATED_ADMIN: set your session before calling this';
    END IF;

    IF EXISTS (SELECT 1 FROM "workflow"."workflow_definitions" WHERE "module" = 'assets' AND "code" = 'ASSET_REQUEST_APPROVAL') THEN
        SELECT "id" INTO v_def_id FROM "workflow"."workflow_definitions" WHERE "module" = 'assets' AND "code" = 'ASSET_REQUEST_APPROVAL';
        RAISE NOTICE 'ASSET_REQUEST_APPROVAL already exists (id=%), skipping', v_def_id;
        RETURN v_def_id;
    END IF;

    INSERT INTO "workflow"."workflow_definitions" ("module", "code", "name", "initiation_permission_code")
    VALUES ('assets', 'ASSET_REQUEST_APPROVAL', 'Asset Request Approval', NULL)
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
        (v_ver_id, 'asset_manager_approval', 1, 1, 'Asset Manager Approval', 'ONE_OF', false, 'ANY_REJECT', 2880)
    RETURNING "id" INTO v_step1_id;

    -- PERMISSION-based assignee - resolved dynamically, no fixed user or
    -- role_id needed. This is the step that would otherwise be a
    -- test-admin/role-name placeholder in Leave/Attendance.
    INSERT INTO "workflow"."workflow_step_assignees" ("workflow_step_id", "assignee_type", "permission_code")
    VALUES (v_step1_id, 'PERMISSION', 'ASSET_MANAGE');

    PERFORM "workflow"."activate_workflow_version"(v_ver_id);

    RAISE NOTICE 'ASSET_REQUEST_APPROVAL created and ACTIVATED (id=%, version_id=%). No placeholder assignee needed - resolves ASSET_MANAGE holders at request time. Make sure at least one real user actually holds ASSET_MANAGE before testing.',
        v_def_id, v_ver_id;

    RETURN v_def_id;
END;
$$;

REVOKE ALL ON FUNCTION "assets"."seed_asset_request_workflow_definition"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "assets"."seed_asset_request_workflow_definition"() TO "authenticated";

-- Run this once you've set your admin session:
-- SELECT "assets"."seed_asset_request_workflow_definition"();

-- ========================================================================
-- END 004_asset_request_workflow_definition_SEED.sql
-- ========================================================================
