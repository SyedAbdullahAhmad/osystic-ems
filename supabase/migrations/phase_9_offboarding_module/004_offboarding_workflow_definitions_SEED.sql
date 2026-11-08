-- ========================================================================
-- 004_offboarding_workflow_definitions_SEED.sql
-- Creates the seed FUNCTION for the two SEPARATE Offboarding workflow definitions:
--   OFFBOARDING_RESIGNATION_APPROVAL  (initiation: any authenticated user via the RPC layer)
--   OFFBOARDING_TERMINATION_APPROVAL  (initiation permission: OFFBOARDING_MANAGE)
-- Each: one step, ONE_OF approval by OFFBOARDING_MANAGE holders, maker-checker ON (the initiator
-- can never approve their own request), statuses PENDING/APPROVED/REJECTED/CANCELLED.
-- Creating the function changes no workflow data. The definitions are created and ACTIVATED only
-- when an authenticated WORKFLOW_CONFIG_MANAGE admin calls
--   SELECT offboarding.seed_offboarding_workflow_definitions();
-- Activated workflow configuration is immutable, so a SEEDED database cannot roll this back.
-- Track A (fresh DB: apply, do NOT seed, roll back) is the supported rollback path, same as Onboarding.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regnamespace('offboarding') IS NULL THEN RAISE EXCEPTION '004 PRE-FLIGHT: run 001-003 first'; END IF;
    IF to_regprocedure('offboarding.seed_offboarding_workflow_definitions()') IS NOT NULL THEN
        RAISE EXCEPTION '004 PRE-FLIGHT: seed function already exists (already applied?)'; END IF;
    IF (SELECT count(*) FROM core.permissions WHERE code = 'OFFBOARDING_MANAGE') <> 1 THEN
        RAISE EXCEPTION '004 PRE-FLIGHT: OFFBOARDING_MANAGE permission missing (apply 003)'; END IF;
    IF to_regprocedure('workflow.activate_workflow_version(uuid)') IS NULL THEN
        RAISE EXCEPTION '004 PRE-FLIGHT: workflow.activate_workflow_version(uuid) missing'; END IF;
    IF to_regclass('workflow._seed_provenance') IS NULL OR to_regclass('core.organizations') IS NULL THEN
        RAISE EXCEPTION '004 PRE-FLIGHT: workflow._seed_provenance or core.organizations missing'; END IF;
    IF EXISTS (SELECT 1 FROM workflow.workflow_definitions WHERE module = 'offboarding') THEN
        RAISE EXCEPTION '004 PRE-FLIGHT: offboarding workflow definitions already exist'; END IF;
END;
$$;

CREATE FUNCTION "offboarding"."seed_offboarding_workflow_definitions"()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core"
AS $$
DECLARE
    v_organization_id uuid;
    v_def     record;
    v_def_id  uuid;
    v_ver_id  uuid;
    v_step_id uuid;
    v_result  jsonb := '{}'::jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'OFFBOARDING_SEED_REQUIRES_AUTHENTICATED_ADMIN: set your session before calling this';
    END IF;
    IF NOT core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE') THEN
        RAISE EXCEPTION 'OFFBOARDING_SEED_NOT_AUTHORIZED: WORKFLOW_CONFIG_MANAGE required to create or activate a workflow definition';
    END IF;
    SELECT "id" INTO v_organization_id FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    IF v_organization_id IS NULL THEN
        RAISE EXCEPTION 'OFFBOARDING_OSYSTIC_ORG_MISSING: seeded OSYSTIC organization row not found';
    END IF;

    FOR v_def IN
        SELECT * FROM (VALUES
            ('OFFBOARDING_RESIGNATION_APPROVAL', 'Offboarding Resignation Approval', NULL::text,              'Withdrawn', 'hr_resignation_approval', 'HR Resignation Approval'),
            ('OFFBOARDING_TERMINATION_APPROVAL', 'Offboarding Termination Approval', 'OFFBOARDING_MANAGE',    'Cancelled', 'hr_termination_approval', 'HR Termination Approval')
        ) AS t("code", "name", "initiation_permission_code", "cancel_label", "step_key", "step_name")
    LOOP
        IF EXISTS (SELECT 1 FROM "workflow"."workflow_definitions"
                    WHERE "module" = 'offboarding' AND "code" = v_def."code" AND "organization_id" IS NOT DISTINCT FROM v_organization_id) THEN
            SELECT "id" INTO v_def_id FROM "workflow"."workflow_definitions"
             WHERE "module" = 'offboarding' AND "code" = v_def."code" AND "organization_id" IS NOT DISTINCT FROM v_organization_id;
            RAISE NOTICE '% already exists (id=%), skipping', v_def."code", v_def_id;
            v_result := v_result || jsonb_build_object(v_def."code", v_def_id);
            CONTINUE;
        END IF;

        WITH "ins_def" AS (
            INSERT INTO "workflow"."workflow_definitions" ("organization_id", "module", "code", "name", "initiation_permission_code")
            VALUES (v_organization_id, 'offboarding', v_def."code", v_def."name", v_def."initiation_permission_code")
            RETURNING "id"
        ), "prov" AS (
            INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
            SELECT 'workflow', 'workflow_definitions', "id", '004_offboarding_workflow_definitions_SEED' FROM "ins_def"
            ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING
        )
        SELECT "id" INTO v_def_id FROM "ins_def";

        WITH "ins_ver" AS (
            INSERT INTO "workflow"."workflow_versions" ("workflow_definition_id", "version_no", "status")
            VALUES (v_def_id, 1, 'DRAFT') RETURNING "id"
        ), "prov" AS (
            INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
            SELECT 'workflow', 'workflow_versions', "id", '004_offboarding_workflow_definitions_SEED' FROM "ins_ver"
            ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING
        )
        SELECT "id" INTO v_ver_id FROM "ins_ver";

        WITH "ins_statuses" AS (
            INSERT INTO "workflow"."workflow_statuses" ("workflow_version_id", "workflow_definition_id", "status_code", "display_name", "is_initial", "is_terminal")
            VALUES
                (v_ver_id, v_def_id, 'PENDING',   'Pending Approval', true,  false),
                (v_ver_id, v_def_id, 'APPROVED',  'Approved',         false, true),
                (v_ver_id, v_def_id, 'REJECTED',  'Rejected',         false, true),
                (v_ver_id, v_def_id, 'CANCELLED', v_def."cancel_label", false, true)
            RETURNING "id"
        )
        INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
        SELECT 'workflow', 'workflow_statuses', "id", '004_offboarding_workflow_definitions_SEED' FROM "ins_statuses"
        ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;

        WITH "ins_rules" AS (
            INSERT INTO "workflow"."transition_rules" ("workflow_version_id", "workflow_definition_id", "from_status", "to_status", "trigger_action", "is_maker_checker")
            VALUES
                (v_ver_id, v_def_id, 'PENDING', 'APPROVED',  'APPROVE', true),
                (v_ver_id, v_def_id, 'PENDING', 'REJECTED',  'REJECT',  true),
                (v_ver_id, v_def_id, 'PENDING', 'CANCELLED', 'CANCEL',  false)
            RETURNING "id"
        )
        INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
        SELECT 'workflow', 'transition_rules', "id", '004_offboarding_workflow_definitions_SEED' FROM "ins_rules"
        ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;

        WITH "ins_step" AS (
            INSERT INTO "workflow"."workflow_steps" (
                "workflow_version_id", "step_key", "step_no", "sequence_no", "step_name",
                "approval_mode", "is_maker_checker", "rejection_mode", "sla_minutes"
            ) VALUES (v_ver_id, v_def."step_key", 1, 1, v_def."step_name", 'ONE_OF', true, 'ANY_REJECT', 2880)
            RETURNING "id"
        ), "prov" AS (
            INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
            SELECT 'workflow', 'workflow_steps', "id", '004_offboarding_workflow_definitions_SEED' FROM "ins_step"
            ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING
        )
        SELECT "id" INTO v_step_id FROM "ins_step";

        WITH "ins_assignee" AS (
            INSERT INTO "workflow"."workflow_step_assignees" ("workflow_step_id", "assignee_type", "permission_code")
            VALUES (v_step_id, 'PERMISSION', 'OFFBOARDING_MANAGE')
            RETURNING "id"
        )
        INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
        SELECT 'workflow', 'workflow_step_assignees', "id", '004_offboarding_workflow_definitions_SEED' FROM "ins_assignee"
        ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;

        PERFORM "workflow"."activate_workflow_version"(v_ver_id);
        RAISE NOTICE '% created and ACTIVATED (definition id=%, version id=%). Maker-checker is ON: at least TWO different users must hold OFFBOARDING_MANAGE before testing.',
            v_def."code", v_def_id, v_ver_id;
        v_result := v_result || jsonb_build_object(v_def."code", v_def_id);
    END LOOP;
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION "offboarding"."seed_offboarding_workflow_definitions"() FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "offboarding"."seed_offboarding_workflow_definitions"() TO "authenticated";

DO $$
DECLARE v_oid oid := to_regprocedure('offboarding.seed_offboarding_workflow_definitions()')::oid;
BEGIN
    IF v_oid IS NULL THEN RAISE EXCEPTION '004 POST-CHECK: seed function was not created'; END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN RAISE EXCEPTION '004 POST-CHECK: seed function is not SECURITY DEFINER'; END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') OR NOT has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
        RAISE EXCEPTION '004 POST-CHECK: seed function EXECUTE privileges are wrong (authenticated only, no PUBLIC/anon)'; END IF;
    IF EXISTS (SELECT 1 FROM workflow.workflow_definitions WHERE module = 'offboarding') THEN
        RAISE EXCEPTION '004 POST-CHECK: creating the function must not create definitions'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 004_offboarding_workflow_definitions_SEED.sql
-- ========================================================================
