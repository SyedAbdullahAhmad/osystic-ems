-- ========================================================================
-- 006a_workflow_role_permission_mapping.sql
--
-- SEPARATE from 006 on purpose - a distinct, independently reviewable
-- migration, per your explicit instruction ("Please use the exact
-- existing core.roles IDs/names when creating the separate
-- role-mapping migration. Do not use role-level heuristics.").
--
-- DEPENDENCY: 006 already applied (WORKFLOW_CONFIG_MANAGE and
-- WORKFLOW_VIEW_ALL must already exist in core.permissions).
--
-- GENUINE BLOCKER, CANNOT BE RESOLVED FROM THE SUPPLIED FILES:
-- schema.sql is a structure-only dump - it does not contain the actual
-- seeded core.roles rows (no INSERT INTO core.roles statements
-- anywhere in it). I do not know the exact core.roles.name values in
-- your real database for "CTO / System Admin", "Technical Admin", or
-- "CEO / Executive" - whether those are the literal `name` column
-- values, the `display_name` values, or descriptive labels over some
-- other actual name (e.g. is it 'CTO', 'SYSTEM_ADMIN', 'ADMIN',
-- something else entirely?).
--
-- This migration is written to look roles up BY NAME, matching against
-- core.roles.name (adjust to display_name below if that is the correct
-- column for your convention), using PLACEHOLDER strings marked
-- <<CONFIRM>> below. Before this can be applied, please either:
--   (a) replace each <<CONFIRM: ...>> placeholder with the exact
--       core.roles.name value from your database, or
--   (b) run: SELECT id, name, display_name, level FROM core.roles
--       ORDER BY level DESC; and send me the output, and I will fill
--       these in for you.
--
-- WORKFLOW_CONFIG_MANAGE decision (yours, verbatim):
--   - CTO / System Admin
--   - Technical Admin
--   Do NOT grant to ordinary HR roles, managers, employees, payroll
--   reviewers, or Finance users.
--
-- WORKFLOW_VIEW_ALL decision (yours, verbatim):
--   - CEO / Executive ONLY
--   Do NOT grant to Technical Admin (technical access must not imply
--   access to sensitive HR approval data).
--   Do NOT grant to HR Head (an EMS/module-scoped permission for
--   HR-wide oversight will be used instead, in a future migration, so
--   this does not later expose Finance or other workflow domains when
--   the engine is reused).
-- ========================================================================

-- Item 1 (round 4): deterministic idempotency and rollback ownership.
-- core.role_permissions has no unique constraint to lean on (confirmed
-- against schema.sql), so idempotency is enforced explicitly here via
-- WHERE NOT EXISTS on the INSERT ... SELECT, checked against the exact
-- (role_id, permission_id) pair. Provenance is recorded the same way
-- 006 does it: RETURNING on the INSERT captures ONLY the rows THIS
-- statement actually newly created - a pre-existing Finance role
-- mapping that already had the grant is never touched and never
-- recorded here, so rollback can never delete something 006a didn't
-- create.
DO $$
DECLARE
    v_config_manage_permission_id uuid;
    v_view_all_permission_id uuid;
    v_role_id uuid;
    v_role_name text;
    v_inserted_id uuid;
BEGIN
    SELECT "id" INTO v_config_manage_permission_id FROM "core"."permissions" WHERE "code" = 'WORKFLOW_CONFIG_MANAGE';
    SELECT "id" INTO v_view_all_permission_id FROM "core"."permissions" WHERE "code" = 'WORKFLOW_VIEW_ALL';

    IF v_config_manage_permission_id IS NULL OR v_view_all_permission_id IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_ROLE_MAPPING_PREREQ_MISSING: run 006_workflow_reference_seed.sql first';
    END IF;

    -- ------------------------------------------------------------------
    -- WORKFLOW_CONFIG_MANAGE -> CTO / System Admin, Technical Admin
    -- ------------------------------------------------------------------
    FOREACH v_role_name IN ARRAY ARRAY[
        '<<CONFIRM: exact core.roles.name for CTO / System Admin>>',
        '<<CONFIRM: exact core.roles.name for Technical Admin>>'
    ]
    LOOP
        SELECT "id" INTO v_role_id FROM "core"."roles" WHERE "name" = v_role_name;
        IF v_role_id IS NULL THEN
            RAISE EXCEPTION 'WORKFLOW_ROLE_MAPPING_ROLE_NOT_FOUND: no core.roles row with name = %. Confirm the exact role name before re-running.', v_role_name;
        END IF;

        WITH "inserted_grant" AS (
            INSERT INTO "core"."role_permissions" ("role_id", "permission_id", "data_scope", "effective_from", "created_by")
            SELECT v_role_id, v_config_manage_permission_id, 'ALL', CURRENT_DATE, NULL
            WHERE NOT EXISTS (
                SELECT 1 FROM "core"."role_permissions"
                WHERE "role_id" = v_role_id AND "permission_id" = v_config_manage_permission_id
            )
            RETURNING "id"
        )
        INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
        SELECT 'core', 'role_permissions', "id", '006a_workflow_role_permission_mapping'
        FROM "inserted_grant"
        ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;
    END LOOP;

    -- ------------------------------------------------------------------
    -- WORKFLOW_VIEW_ALL -> CEO / Executive only
    -- ------------------------------------------------------------------
    v_role_name := '<<CONFIRM: exact core.roles.name for CEO / Executive>>';
    SELECT "id" INTO v_role_id FROM "core"."roles" WHERE "name" = v_role_name;
    IF v_role_id IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_ROLE_MAPPING_ROLE_NOT_FOUND: no core.roles row with name = %. Confirm the exact role name before re-running.', v_role_name;
    END IF;

    WITH "inserted_grant" AS (
        INSERT INTO "core"."role_permissions" ("role_id", "permission_id", "data_scope", "effective_from", "created_by")
        SELECT v_role_id, v_view_all_permission_id, 'ALL', CURRENT_DATE, NULL
        WHERE NOT EXISTS (
            SELECT 1 FROM "core"."role_permissions"
            WHERE "role_id" = v_role_id AND "permission_id" = v_view_all_permission_id
        )
        RETURNING "id"
    )
    INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
    SELECT 'core', 'role_permissions', "id", '006a_workflow_role_permission_mapping'
    FROM "inserted_grant"
    ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;
END;
$$;


-- ========================================================================
-- END 006a_workflow_role_permission_mapping.sql
-- ========================================================================
