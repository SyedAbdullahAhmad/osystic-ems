-- ========================================================================
-- 004_attendance_correction_workflow_definition_SEED.sql
--
-- IMPORTANT: this is NOT a normal migration - same reason as
-- 004_leave_workflow_definition_SEED.sql. workflow._force_created_by()
-- hard-requires auth.uid() IS NOT NULL for any INSERT into
-- workflow_definitions/workflow_versions/delegations. A bare migration
-- script has no session, so this INSERT is rejected outright by design.
--
-- HOW TO RUN THIS: as a real, logged-in admin (someone holding
-- WORKFLOW_CONFIG_MANAGE), via the Supabase SQL Editor, with your own
-- session's JWT claim set first. Replace <YOUR_ADMIN_USER_ID> below with
-- your own auth.users.id.
--
-- DESIGN PROPOSAL, FLAGGING FOR REVIEW (not yet confirmed with team lead,
-- same way the original workflow ERD went through review before being
-- applied): this seeds a SINGLE-step manager_approval workflow, unlike
-- Leave's two-step (manager + HR). Rationale: an attendance correction is
-- a factual dispute about a single day's clock times, not a policy
-- decision - it doesn't obviously need HR sign-off the way leave (which
-- affects paid balance) does. If you want HR in the loop too, add a
-- second workflow_steps row here (hr_signoff) before activating, mirroring
-- Leave's structure exactly - the schema and RPC already support it with
-- no changes needed either way.
-- ========================================================================

-- Uncomment and fill in before running interactively in the SQL Editor:
-- SELECT set_config('request.jwt.claims', json_build_object('sub', '<YOUR_ADMIN_USER_ID>', 'role', 'authenticated')::text, true);

CREATE OR REPLACE FUNCTION "attendance"."seed_attendance_correction_workflow_definition"()
RETURNS uuid
LANGUAGE plpgsql
SET search_path = pg_catalog, "attendance", "workflow"
AS $$
DECLARE
    v_def_id uuid;
    v_ver_id uuid;
    v_step1_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_SEED_REQUIRES_AUTHENTICATED_ADMIN: set your session (see this file''s header) before calling this';
    END IF;

    IF EXISTS (SELECT 1 FROM "workflow"."workflow_definitions" WHERE "module" = 'attendance' AND "code" = 'ATTENDANCE_CORRECTION_APPROVAL') THEN
        SELECT "id" INTO v_def_id FROM "workflow"."workflow_definitions" WHERE "module" = 'attendance' AND "code" = 'ATTENDANCE_CORRECTION_APPROVAL';
        RAISE NOTICE 'ATTENDANCE_CORRECTION_APPROVAL already exists (id=%), skipping', v_def_id;
        RETURN v_def_id;
    END IF;

    INSERT INTO "workflow"."workflow_definitions" ("module", "code", "name", "initiation_permission_code")
    VALUES ('attendance', 'ATTENDANCE_CORRECTION_APPROVAL', 'Attendance Correction Approval', NULL)
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

    -- Single step, ONE_OF/single-assignee for v1 - see header for the
    -- one-step-vs-two-step design note. Same placeholder-assignee
    -- situation as Leave: real assignee resolution (by reporting-line
    -- lookup) is a follow-up once HR/org-structure exists.
    INSERT INTO "workflow"."workflow_steps" (
        "workflow_version_id", "step_key", "step_no", "sequence_no", "step_name",
        "approval_mode", "is_maker_checker", "rejection_mode", "sla_minutes"
    ) VALUES
        (v_ver_id, 'manager_approval', 1, 1, 'Manager Approval', 'ONE_OF', true, 'ANY_REJECT', 1440)
    RETURNING "id" INTO v_step1_id;

    -- TODO: replace with a real role_id once HR/org roles exist -
    -- <<CONFIRM: exact core.roles.name for direct-manager role>>, same
    -- open placeholder pattern as 006a and Leave's seed. Left DRAFT (not
    -- activated) below until real assignees are wired in.

    RAISE NOTICE 'ATTENDANCE_CORRECTION_APPROVAL created as DRAFT (id=%, version_id=%) - NOT activated. Wire a real manager-role assignee into workflow_step_assignees for step %, then call workflow.activate_workflow_version(%) as an admin.',
        v_def_id, v_ver_id, v_step1_id, v_ver_id;

    RETURN v_def_id;
END;
$$;

REVOKE ALL ON FUNCTION "attendance"."seed_attendance_correction_workflow_definition"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "attendance"."seed_attendance_correction_workflow_definition"() TO "authenticated";

-- Run this once you've set your admin session (see header):
-- SELECT "attendance"."seed_attendance_correction_workflow_definition"();

-- ========================================================================
-- END 004_attendance_correction_workflow_definition_SEED.sql
-- ========================================================================
