-- ========================================================================
-- RUN_seed_offboarding_workflow_definitions.sql  -  Track B ONLY, run ONCE after 004.
-- Creates and ACTIVATES the two Offboarding workflow definitions (irreversible on this database:
-- activated workflow configuration is immutable). Track A (fresh DB) never runs this file.
-- Maker-checker is ON, so at least TWO different users must hold OFFBOARDING_MANAGE for a real approval.
-- ========================================================================
DO $$
DECLARE v_admin uuid;
BEGIN
    SELECT id INTO v_admin FROM auth.users WHERE core.has_permission(id, 'WORKFLOW_CONFIG_MANAGE') ORDER BY created_at LIMIT 1;
    IF v_admin IS NULL THEN RAISE EXCEPTION 'SETUP: no user holds WORKFLOW_CONFIG_MANAGE'; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
    PERFORM offboarding.seed_offboarding_workflow_definitions();
END;
$$;

SELECT d.code, d.initiation_permission_code, v.version_no, v.status
FROM workflow.workflow_definitions d
JOIN workflow.workflow_versions v ON v.workflow_definition_id = d.id
WHERE d.module = 'offboarding'
ORDER BY d.code;
