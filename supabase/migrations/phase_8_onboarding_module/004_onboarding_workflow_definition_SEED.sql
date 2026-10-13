-- ========================================================================
-- 004_onboarding_workflow_definition_SEED.sql  (v3 - corrected per
-- Arslan's round-2 review, items 5 and 9)
--
-- PERMISSION-based assignee (ONBOARDING_MANAGE), same pattern as Assets/
-- Contracts. Resolves dynamically at request time - activates
-- immediately, no placeholder.
--
-- OPERATIONAL PRECONDITION: at least TWO real users must hold
-- ONBOARDING_MANAGE (maker-checker is ON - item 9 from round 1).
--
-- CHANGES IN THIS REVISION:
--   - Item 9: the workflow_definition is now seeded bound to the
--     OSYSTIC organization_id (same lookup 003 uses for core.people),
--     not left organization_id = NULL. See 003's own comment at its
--     workflow_definition lookup for the honest limitation this does
--     NOT fix: workflow.start_approval_request() (the shared engine,
--     phase_2) hardcodes approval_requests.organization_id = NULL
--     unconditionally regardless of the definition's own binding - that
--     is out of scope for this module to change.
--   - Item 5: deterministic rollback provenance, reusing the EXACT
--     mechanism already established for the shared engine's own seed
--     data (workflow."_seed_provenance", see
--     phase_2_workflow_engine/006_workflow_reference_seed.sql) rather
--     than inventing a second, onboarding-specific tracking table. Every
--     row this function creates across workflow_definitions/versions/
--     statuses/transition_rules/steps/step_assignees is recorded there,
--     captured via RETURNING on each INSERT so only rows THIS call
--     actually created are ever recorded - never inferred from current
--     absence of references. 004's rollback now deletes ONLY what's
--     recorded here, nothing inferred.
--   - Item 10 (round 3) / Item 1 (round 4 - CORRECTED): round 3
--     verified "authenticated" has base GRANT SELECT/INSERT/UPDATE on
--     the six workflow-config tables this function writes to
--     (workflow_definitions/versions/statuses/steps/step_assignees/
--     transition_rules), each gated by an RLS policy requiring
--     WORKFLOW_CONFIG_MANAGE - all true, and SECURITY INVOKER was
--     correct for those six. But this function ALSO writes to a
--     SEVENTH table, workflow."_seed_provenance" (item 5/round 2's
--     deterministic-rollback mechanism), which round 3's verification
--     missed. Checked directly against
--     phase_2_workflow_engine/006_workflow_reference_seed.sql: that
--     table has NO GRANT to "authenticated" at all, and no RLS policy
--     either - a plain top-level migration DML table, written only by
--     whichever privileged role runs migrations, never intended to be
--     writable by an ordinary authenticated session. Under SECURITY
--     INVOKER, THIS function's own _seed_provenance INSERTs would have
--     failed with a permission-denied error even though the other six
--     tables' writes would have succeeded - a real, confirmed execution
--     blocker, not a hypothetical one.
--
--     FIX: this function is now SECURITY DEFINER instead - its writes
--     (to all seven tables) run as the function's OWNER, not the
--     caller, bypassing grants/RLS entirely by design, the same
--     principle every other RPC in this module already relies on (003/
--     006/007). The WORKFLOW_CONFIG_MANAGE gate at the top is now the
--     ONLY thing standing between an ordinary authenticated session and
--     privileged workflow configuration - kept exactly as it was.
--     search_path stays fully pinned (no "public" or ambient
--     resolution), PUBLIC execute is revoked, only "authenticated" can
--     call it, and the function takes zero parameters - no user-
--     controlled table or record identifiers anywhere in its body, so
--     there is no injection surface this elevation could expose.
--     workflow."_seed_provenance" itself is NOT granted or widened -
--     the fix is entirely in how THIS function runs, not in loosening
--     what ordinary users can touch directly.
-- ========================================================================

CREATE OR REPLACE FUNCTION "onboarding"."seed_onboarding_workflow_definition"()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "onboarding", "workflow", "core"
AS $$
DECLARE
    v_organization_id uuid;
    v_def_id uuid;
    v_ver_id uuid;
    v_step1_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_SEED_REQUIRES_AUTHENTICATED_ADMIN: set your session before calling this';
    END IF;

    IF NOT core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE') THEN
        RAISE EXCEPTION 'ONBOARDING_SEED_NOT_AUTHORIZED: WORKFLOW_CONFIG_MANAGE required to create or activate a workflow definition';
    END IF;

    SELECT "id" INTO v_organization_id FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    IF v_organization_id IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_OSYSTIC_ORG_MISSING: seeded OSYSTIC organization row not found';
    END IF;

    IF EXISTS (
        SELECT 1 FROM "workflow"."workflow_definitions"
        WHERE "module" = 'onboarding' AND "code" = 'ONBOARDING_OFFER_APPROVAL'
          AND "organization_id" IS NOT DISTINCT FROM v_organization_id
    ) THEN
        SELECT "id" INTO v_def_id FROM "workflow"."workflow_definitions"
        WHERE "module" = 'onboarding' AND "code" = 'ONBOARDING_OFFER_APPROVAL'
          AND "organization_id" IS NOT DISTINCT FROM v_organization_id;
        RAISE NOTICE 'ONBOARDING_OFFER_APPROVAL already exists for organization % (id=%), skipping', v_organization_id, v_def_id;
        RETURN v_def_id;
    END IF;

    WITH "ins_def" AS (
        INSERT INTO "workflow"."workflow_definitions" ("organization_id", "module", "code", "name", "initiation_permission_code")
        VALUES (v_organization_id, 'onboarding', 'ONBOARDING_OFFER_APPROVAL', 'Onboarding Offer Approval', 'ONBOARDING_MANAGE')
        RETURNING "id"
    ), "prov_def" AS (
        INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
        SELECT 'workflow', 'workflow_definitions', "id", '004_onboarding_workflow_definition_SEED'
        FROM "ins_def"
        ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING
    )
    SELECT "id" INTO v_def_id FROM "ins_def";

    WITH "ins_ver" AS (
        INSERT INTO "workflow"."workflow_versions" ("workflow_definition_id", "version_no", "status")
        VALUES (v_def_id, 1, 'DRAFT')
        RETURNING "id"
    ), "prov_ver" AS (
        INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
        SELECT 'workflow', 'workflow_versions', "id", '004_onboarding_workflow_definition_SEED'
        FROM "ins_ver"
        ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING
    )
    SELECT "id" INTO v_ver_id FROM "ins_ver";

    WITH "ins_statuses" AS (
        INSERT INTO "workflow"."workflow_statuses" ("workflow_version_id", "workflow_definition_id", "status_code", "display_name", "is_initial", "is_terminal")
        VALUES
            (v_ver_id, v_def_id, 'PENDING', 'Pending Approval', true, false),
            (v_ver_id, v_def_id, 'APPROVED', 'Approved', false, true),
            (v_ver_id, v_def_id, 'REJECTED', 'Rejected', false, true),
            (v_ver_id, v_def_id, 'CANCELLED', 'Withdrawn', false, true)
        RETURNING "id"
    )
    INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
    SELECT 'workflow', 'workflow_statuses', "id", '004_onboarding_workflow_definition_SEED'
    FROM "ins_statuses"
    ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;

    WITH "ins_rules" AS (
        INSERT INTO "workflow"."transition_rules" ("workflow_version_id", "workflow_definition_id", "from_status", "to_status", "trigger_action", "is_maker_checker")
        VALUES
            (v_ver_id, v_def_id, 'PENDING', 'APPROVED', 'APPROVE', true),
            (v_ver_id, v_def_id, 'PENDING', 'REJECTED', 'REJECT', true),
            (v_ver_id, v_def_id, 'PENDING', 'CANCELLED', 'CANCEL', false)
        RETURNING "id"
    )
    INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
    SELECT 'workflow', 'transition_rules', "id", '004_onboarding_workflow_definition_SEED'
    FROM "ins_rules"
    ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;

    WITH "ins_step" AS (
        INSERT INTO "workflow"."workflow_steps" (
            "workflow_version_id", "step_key", "step_no", "sequence_no", "step_name",
            "approval_mode", "is_maker_checker", "rejection_mode", "sla_minutes"
        ) VALUES
            (v_ver_id, 'hr_offer_approval', 1, 1, 'HR Offer Approval', 'ONE_OF', true, 'ANY_REJECT', 2880)
        RETURNING "id"
    ), "prov_step" AS (
        INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
        SELECT 'workflow', 'workflow_steps', "id", '004_onboarding_workflow_definition_SEED'
        FROM "ins_step"
        ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING
    )
    SELECT "id" INTO v_step1_id FROM "ins_step";

    WITH "ins_assignee" AS (
        INSERT INTO "workflow"."workflow_step_assignees" ("workflow_step_id", "assignee_type", "permission_code")
        VALUES (v_step1_id, 'PERMISSION', 'ONBOARDING_MANAGE')
        RETURNING "id"
    )
    INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
    SELECT 'workflow', 'workflow_step_assignees', "id", '004_onboarding_workflow_definition_SEED'
    FROM "ins_assignee"
    ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;

    PERFORM "workflow"."activate_workflow_version"(v_ver_id);

    RAISE NOTICE 'ONBOARDING_OFFER_APPROVAL created and ACTIVATED for organization % (id=%, version_id=%). Maker-checker is ON. Make sure at least TWO different real users hold ONBOARDING_MANAGE before testing.',
        v_organization_id, v_def_id, v_ver_id;

    RETURN v_def_id;
END;
$$;

REVOKE ALL ON FUNCTION "onboarding"."seed_onboarding_workflow_definition"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "onboarding"."seed_onboarding_workflow_definition"() TO "authenticated";

-- Run this once you've set your admin session (requires both an
-- authenticated session AND WORKFLOW_CONFIG_MANAGE):
-- SELECT "onboarding"."seed_onboarding_workflow_definition"();

-- ========================================================================
-- END 004_onboarding_workflow_definition_SEED.sql
-- ========================================================================
