-- ========================================================================
-- 004_leave_workflow_definition_SEED.sql
--
-- IMPORTANT: this is NOT a normal migration. It cannot be run as part of
-- an automated migration pipeline (supabase db push / CLI migrate), and
-- it will FAIL if you try, by design.
--
-- WHY: workflow._force_created_by() (in 004_workflow_functions_triggers.sql,
-- already applied and tested) hard-requires auth.uid() IS NOT NULL for any
-- INSERT into workflow_definitions/workflow_versions/delegations - this was
-- a deliberate security decision (see LEAVE_MODULE_HANDOFF.md section 4/
-- the original team-lead instruction: "Do not silently work around this
-- with fake user IDs. Either use an approved system/service actor
-- convention or create module workflow definitions through controlled
-- admin tooling/RPCs.") A bare migration script has no session, so
-- auth.uid() is NULL, so this INSERT is rejected outright.
--
-- HOW TO RUN THIS: as a real, logged-in admin (someone holding
-- WORKFLOW_CONFIG_MANAGE), via the Supabase SQL Editor, with your own
-- session's JWT claim set first. Replace <YOUR_ADMIN_USER_ID> below with
-- your own auth.users.id (find it via `select auth.uid()` while logged in,
-- or from the auth.users table), then run this file once.
--
-- TODO (tracked, not blocking): once there's an actual admin UI, this
-- becomes a one-time setup action performed there instead of a manual SQL
-- script - the RPC below (leave.seed_leave_workflow_definition) is written
-- so that UI action can just call it directly.
-- ========================================================================

-- Uncomment and fill in before running interactively in the SQL Editor:
-- SELECT set_config('request.jwt.claims', json_build_object('sub', '<YOUR_ADMIN_USER_ID>', 'role', 'authenticated')::text, true);
   SELECT set_config('request.jwt.claims', json_build_object('sub', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'role', 'authenticated')::text, true);
CREATE OR REPLACE FUNCTION "leave"."seed_leave_workflow_definition"()
RETURNS uuid
LANGUAGE plpgsql
SET search_path = pg_catalog, "leave", "workflow"
AS $$
DECLARE
    v_def_id uuid;
    v_ver_id uuid;
    v_step1_id uuid;
    v_step2_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'LEAVE_SEED_REQUIRES_AUTHENTICATED_ADMIN: set your session (see this file''s header) before calling this';
    END IF;

    IF EXISTS (SELECT 1 FROM "workflow"."workflow_definitions" WHERE "module" = 'leave' AND "code" = 'LEAVE_REQUEST_APPROVAL') THEN
        SELECT "id" INTO v_def_id FROM "workflow"."workflow_definitions" WHERE "module" = 'leave' AND "code" = 'LEAVE_REQUEST_APPROVAL';
        RAISE NOTICE 'LEAVE_REQUEST_APPROVAL already exists (id=%), skipping', v_def_id;
        RETURN v_def_id;
    END IF;

    INSERT INTO "workflow"."workflow_definitions" ("module", "code", "name", "initiation_permission_code")
    VALUES ('leave', 'LEAVE_REQUEST_APPROVAL', 'Leave Request Approval', NULL)
    RETURNING "id" INTO v_def_id;

    INSERT INTO "workflow"."workflow_versions" ("workflow_definition_id", "version_no", "status")
    VALUES (v_def_id, 1, 'DRAFT')
    RETURNING "id" INTO v_ver_id;

    -- Two-stage approval: direct manager, then HR sign-off. Both
    -- ONE_OF/single-assignee for v1 - real assignee resolution
    -- (by role or by reporting-line lookup) is a follow-up once HR's
    -- org-structure tables exist; for now this uses ROLE-type assignment
    -- against a placeholder role so the workflow is genuinely runnable
    -- end-to-end rather than blocked on an unrelated module.
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
        (v_ver_id, 'manager_approval', 1, 1, 'Manager Approval', 'ONE_OF', true, 'ANY_REJECT', 2880)
    RETURNING "id" INTO v_step1_id;

    INSERT INTO "workflow"."workflow_steps" (
        "workflow_version_id", "step_key", "step_no", "sequence_no", "step_name",
        "approval_mode", "is_maker_checker", "rejection_mode", "sla_minutes"
    ) VALUES
        (v_ver_id, 'hr_signoff', 2, 1, 'HR Sign-off', 'ONE_OF', false, 'ANY_REJECT', 2880)
    RETURNING "id" INTO v_step2_id;

    -- TODO: replace with real role_id values once HR/org roles exist -
    -- <<CONFIRM: exact core.roles.name for direct-manager role>> and
    -- <<CONFIRM: exact core.roles.name for HR role>>, same pattern as
    -- 006a's still-open placeholders. Until confirmed, this workflow
    -- version is deliberately left in DRAFT (not activated) below, so it
    -- cannot actually be used for a real submission yet - activate it
    -- only once real assignees are wired in.

    RAISE NOTICE 'LEAVE_REQUEST_APPROVAL created as DRAFT (id=%, version_id=%) - NOT activated. Wire real manager/HR role assignees into workflow_step_assignees for steps % and %, then call workflow.activate_workflow_version(%) as an admin.',
        v_def_id, v_ver_id, v_step1_id, v_step2_id, v_ver_id;

    RETURN v_def_id;
END;
$$;

REVOKE ALL ON FUNCTION "leave"."seed_leave_workflow_definition"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "leave"."seed_leave_workflow_definition"() TO "authenticated";

-- Run this once you've set your admin session (see header):
-- SELECT "leave"."seed_leave_workflow_definition"();
 SELECT "leave"."seed_leave_workflow_definition"();
-- ========================================================================
-- END 004_leave_workflow_definition_SEED.sql
-- ========================================================================
