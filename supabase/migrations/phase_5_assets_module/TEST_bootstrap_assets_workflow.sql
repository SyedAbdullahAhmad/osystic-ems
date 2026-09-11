-- Run as ONE complete paste in the Supabase SQL Editor, as a real
-- logged-in admin session (LOCAL_TEST_ADMIN: 2d48e4e3-fee2-4034-8b8d-a3cce8298ce2 -
-- the same account already used to activate Leave's workflow version,
-- and which already holds WORKFLOW_CONFIG_MANAGE).
--
-- Grants ASSET_MANAGE to the LOCAL_TEST_ADMIN role (which this account
-- already holds) via core.role_permissions, then seeds + activates the
-- ASSET_REQUEST_APPROVAL workflow. Unlike Leave/Attendance's test-admin
-- fixture (no real login), LOCAL_TEST_ADMIN IS a real, loggable-in
-- account - so this is also your path to proving an ELIGIBLE approver
-- clicking Approve through the actual browser UI, closing the gap
-- flagged as unproven for the other two modules.

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

    SELECT "id" INTO v_permission_id FROM "core"."permissions" WHERE "code" = 'ASSET_MANAGE';
    IF v_permission_id IS NULL THEN
        RAISE EXCEPTION 'ASSET_MANAGE permission not found - run 005_assets_permissions_seed.sql first';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "core"."role_permissions" WHERE "role_id" = v_role_id AND "permission_id" = v_permission_id) THEN
        INSERT INTO "core"."role_permissions" ("role_id", "permission_id") VALUES (v_role_id, v_permission_id);
        RAISE NOTICE 'Granted ASSET_MANAGE to LOCAL_TEST_ADMIN role';
    ELSE
        RAISE NOTICE 'LOCAL_TEST_ADMIN already has ASSET_MANAGE - left unchanged';
    END IF;
END;
$$;

SELECT "assets"."seed_asset_request_workflow_definition"();

-- Verify:
SELECT wd."code", wv."version_no", wv."status", ws."step_key", wsa."assignee_type", wsa."permission_code"
FROM "workflow"."workflow_definitions" wd
JOIN "workflow"."workflow_versions" wv ON wv."workflow_definition_id" = wd."id"
JOIN "workflow"."workflow_steps" ws ON ws."workflow_version_id" = wv."id"
LEFT JOIN "workflow"."workflow_step_assignees" wsa ON wsa."workflow_step_id" = ws."id"
WHERE wd."code" = 'ASSET_REQUEST_APPROVAL';
-- expect: version_no 1, status ACTIVE, step_key asset_manager_approval,
-- assignee_type PERMISSION, permission_code ASSET_MANAGE

SELECT core.has_permission('2d48e4e3-fee2-4034-8b8d-a3cce8298ce2'::uuid, 'ASSET_MANAGE') AS "local_test_admin_has_asset_manage";
-- expect: true
