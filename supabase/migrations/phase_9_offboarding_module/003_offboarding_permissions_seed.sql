-- ========================================================================
-- 003_offboarding_permissions_seed.sql  -  new permission CODES only (no role mappings:
-- production role names are not guessed; 006a mapping stays blocked on Finance role names).
-- Seeded rows are recorded in workflow._seed_provenance so the rollback removes exactly them.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regclass('core.permissions') IS NULL OR to_regclass('workflow._seed_provenance') IS NULL THEN
        RAISE EXCEPTION '003 PRE-FLIGHT: core.permissions or workflow._seed_provenance missing'; END IF;
    IF EXISTS (SELECT 1 FROM core.permissions WHERE code LIKE 'OFFBOARDING\_%') THEN
        RAISE EXCEPTION '003 PRE-FLIGHT: OFFBOARDING_* permission codes already exist (already applied?)'; END IF;
END;
$$;

WITH "inserted_permissions" AS (
    INSERT INTO "core"."permissions" ("code", "name", "module", "action", "description", "created_by")
    SELECT * FROM (VALUES
        ('OFFBOARDING_MANAGE',              'Manage Offboarding',                'offboarding', 'MANAGE',              'Start terminations and resignations on behalf, approve offboarding requests, waive non-asset clearances with a reason, complete offboarding, withdraw or cancel cases - via the controlled RPC path only', NULL::uuid),
        ('OFFBOARDING_VIEW_ALL',            'View All Offboarding Cases',        'offboarding', 'VIEW_ALL',            'View any offboarding case (type, category and status; termination reason detail is reserved for OFFBOARDING_MANAGE)', NULL::uuid),
        ('OFFBOARDING_CLEARANCE_ASSETS',    'Sign off Assets Clearance',         'offboarding', 'CLEARANCE_ASSETS',    'Sign off the assets clearance task after independent verification of zero unreturned assignments; cannot return an asset', NULL::uuid),
        ('OFFBOARDING_CLEARANCE_ACCESS',    'Sign off Access Clearance',         'offboarding', 'CLEARANCE_ACCESS',    'Sign off the systems/access clearance task', NULL::uuid),
        ('OFFBOARDING_CLEARANCE_FINANCE',   'Sign off Finance Clearance',        'offboarding', 'CLEARANCE_FINANCE',   'Sign off the finance clearance task', NULL::uuid),
        ('OFFBOARDING_CLEARANCE_HANDOVER',  'Sign off Handover Clearance',       'offboarding', 'CLEARANCE_HANDOVER',  'Sign off the work handover clearance task', NULL::uuid),
        ('OFFBOARDING_CLEARANCE_HR',        'Sign off HR Clearance',             'offboarding', 'CLEARANCE_HR',        'Sign off the HR clearance task', NULL::uuid)
    ) AS v("code", "name", "module", "action", "description", "created_by")
    WHERE NOT EXISTS (SELECT 1 FROM "core"."permissions" p WHERE p."code" = v."code")
    RETURNING "id"
)
INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
SELECT 'core', 'permissions', "id", '003_offboarding_permissions_seed' FROM "inserted_permissions"
ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;

DO $$
DECLARE v_n int; v_prov int;
BEGIN
    SELECT count(*) INTO v_n FROM core.permissions
     WHERE code IN ('OFFBOARDING_MANAGE','OFFBOARDING_VIEW_ALL','OFFBOARDING_CLEARANCE_ASSETS','OFFBOARDING_CLEARANCE_ACCESS',
                    'OFFBOARDING_CLEARANCE_FINANCE','OFFBOARDING_CLEARANCE_HANDOVER','OFFBOARDING_CLEARANCE_HR') AND module = 'offboarding';
    IF v_n <> 7 THEN RAISE EXCEPTION '003 POST-CHECK: expected 7 offboarding permissions, found %', v_n; END IF;
    SELECT count(*) INTO v_prov FROM workflow._seed_provenance WHERE seeded_by_migration = '003_offboarding_permissions_seed';
    IF v_prov <> 7 THEN RAISE EXCEPTION '003 POST-CHECK: expected 7 provenance rows, found %', v_prov; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 003_offboarding_permissions_seed.sql
-- ========================================================================
