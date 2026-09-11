-- Run as ONE complete paste in the Supabase SQL Editor, as a real
-- logged-in admin session (LOCAL_TEST_ADMIN: 2d48e4e3-fee2-4034-8b8d-a3cce8298ce2 -
-- the same account already used for Leave/Assets).
--
-- Grants CONTRACT_MANAGE to the LOCAL_TEST_ADMIN role via
-- core.role_permissions, then seeds + activates the CONTRACT_APPROVAL
-- workflow. Since this slice has no segregation-of-duties split (same
-- permission gates both creation and approval, per team lead's decision),
-- LOCAL_TEST_ADMIN will be used as BOTH the creator and the approver in
-- TEST_create_approve_contract.sql - that's expected, not a bug, and is
-- exactly why is_maker_checker is false on this workflow step.

SELECT set_config('request.jwt.claims', json_build_object('sub', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'role', 'authenticated')::text, true);

DO $$
DECLARE
    v_role_id uuid;
    v_permission_id uuid;
BEGIN
    SELECT "id" INTO v_role_id FROM "core"."roles" WHERE "name" = 'LOCAL_TEST_ADMIN';
    IF v_role_id IS NULL THEN
        RAISE EXCEPTION 'LOCAL_TEST_ADMIN role not found - check core.roles for the exact name before re-running';
    END IF;

    SELECT "id" INTO v_permission_id FROM "core"."permissions" WHERE "code" = 'CONTRACT_MANAGE';
    IF v_permission_id IS NULL THEN
        RAISE EXCEPTION 'CONTRACT_MANAGE permission not found - run 005_contracts_permissions_seed.sql first';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "core"."role_permissions" WHERE "role_id" = v_role_id AND "permission_id" = v_permission_id) THEN
        INSERT INTO "core"."role_permissions" ("role_id", "permission_id") VALUES (v_role_id, v_permission_id);
        RAISE NOTICE 'Granted CONTRACT_MANAGE to LOCAL_TEST_ADMIN role';
    ELSE
        RAISE NOTICE 'LOCAL_TEST_ADMIN already has CONTRACT_MANAGE - left unchanged';
    END IF;
END;
$$;

SELECT "hr"."seed_contract_request_workflow_definition"();

-- Verify:
SELECT wd."code", wv."version_no", wv."status", ws."step_key", wsa."assignee_type", wsa."permission_code"
FROM "workflow"."workflow_definitions" wd
JOIN "workflow"."workflow_versions" wv ON wv."workflow_definition_id" = wd."id"
JOIN "workflow"."workflow_steps" ws ON ws."workflow_version_id" = wv."id"
LEFT JOIN "workflow"."workflow_step_assignees" wsa ON wsa."workflow_step_id" = ws."id"
WHERE wd."code" = 'CONTRACT_APPROVAL';
-- expect: version_no 1, status ACTIVE, step_key contract_approval,
-- assignee_type PERMISSION, permission_code CONTRACT_MANAGE

SELECT core.has_permission('2d48e4e3-fee2-4034-8b8d-a3cce8298ce2'::uuid, 'CONTRACT_MANAGE') AS "local_test_admin_has_contract_manage";
-- expect: true
