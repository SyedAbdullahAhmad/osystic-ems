-- Run as ONE complete paste in the Supabase SQL Editor, as a real logged-in
-- admin session (LOCAL_TEST_ADMIN, same account used to activate the leave
-- workflow version: 2d48e4e3-fee2-4034-8b8d-a3cce8298ce2).
--
-- Assigns the same test-admin fixture account Leave already uses
-- (00000000-0000-0000-0000-0000000000a6) as the placeholder manager_approval
-- approver - not a new decision, the same documented stand-in used for
-- Leave until a real HR/org-structure lookup exists.

SELECT set_config('request.jwt.claims', json_build_object('sub', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'role', 'authenticated')::text, true);

DO $$
DECLARE
    v_def_id uuid;
    v_ver_id uuid;
    v_step_id uuid;
BEGIN
    v_def_id := "attendance"."seed_attendance_correction_workflow_definition"();

    SELECT "id" INTO v_ver_id FROM "workflow"."workflow_versions"
    WHERE "workflow_definition_id" = v_def_id AND "status" = 'DRAFT'
    ORDER BY "version_no" DESC LIMIT 1;

    IF v_ver_id IS NULL THEN
        RAISE EXCEPTION 'No DRAFT version found for ATTENDANCE_CORRECTION_APPROVAL - it may already be ACTIVE. Check workflow.workflow_versions manually before re-running.';
    END IF;

    SELECT "id" INTO v_step_id FROM "workflow"."workflow_steps"
    WHERE "workflow_version_id" = v_ver_id AND "step_key" = 'manager_approval';

    IF NOT EXISTS (SELECT 1 FROM "workflow"."workflow_step_assignees" WHERE "workflow_step_id" = v_step_id) THEN
        INSERT INTO "workflow"."workflow_step_assignees" ("workflow_step_id", "assignee_type", "user_id")
        VALUES (v_step_id, 'USER', '00000000-0000-0000-0000-0000000000a6');
        RAISE NOTICE 'Assigned test-admin fixture account to step %', v_step_id;
    ELSE
        RAISE NOTICE 'Step % already has an assignee - left unchanged', v_step_id;
    END IF;

    PERFORM "workflow"."activate_workflow_version"(v_ver_id);
    RAISE NOTICE 'Activated workflow_version % (definition %)', v_ver_id, v_def_id;
END;
$$;

-- Verify:
SELECT wd."code", wv."version_no", wv."status", ws."step_key", wsa."assignee_type", wsa."user_id"
FROM "workflow"."workflow_definitions" wd
JOIN "workflow"."workflow_versions" wv ON wv."workflow_definition_id" = wd."id"
JOIN "workflow"."workflow_steps" ws ON ws."workflow_version_id" = wv."id"
LEFT JOIN "workflow"."workflow_step_assignees" wsa ON wsa."workflow_step_id" = ws."id"
WHERE wd."code" = 'ATTENDANCE_CORRECTION_APPROVAL';
-- expect: version_no 1, status ACTIVE, step_key manager_approval, assignee_type USER,
-- user_id 00000000-0000-0000-0000-0000000000a6
