-- ========================================================================
-- 003_offboarding_permissions_seed_ROLLBACK.sql
-- Removes exactly the 7 seeded permissions (by provenance). REFUSES if any role mapping or
-- workflow step assignee still references them.
-- ========================================================================
BEGIN;

DO $$
DECLARE v_ids uuid[];
BEGIN
    SELECT array_agg(record_id) INTO v_ids FROM workflow._seed_provenance
     WHERE seeded_by_migration = '003_offboarding_permissions_seed' AND schema_name = 'core' AND table_name = 'permissions';
    IF v_ids IS NULL OR cardinality(v_ids) <> 7 THEN RAISE EXCEPTION '003 ROLLBACK PRE-FLIGHT: expected 7 provenance rows, found %', coalesce(cardinality(v_ids), 0); END IF;
    IF EXISTS (SELECT 1 FROM core.role_permissions WHERE permission_id = ANY (v_ids)) THEN
        RAISE EXCEPTION '003 ROLLBACK PRE-FLIGHT: a role mapping still references an offboarding permission - remove it first'; END IF;
    IF EXISTS (SELECT 1 FROM workflow.workflow_step_assignees a JOIN core.permissions p ON p.code = a.permission_code WHERE p.id = ANY (v_ids)) THEN
        RAISE EXCEPTION '003 ROLLBACK PRE-FLIGHT: a workflow step assignee still references an offboarding permission - roll back 004 first'; END IF;
END;
$$;

DELETE FROM "core"."permissions" WHERE "id" IN (
    SELECT record_id FROM "workflow"."_seed_provenance"
     WHERE seeded_by_migration = '003_offboarding_permissions_seed' AND schema_name = 'core' AND table_name = 'permissions');
DELETE FROM "workflow"."_seed_provenance" WHERE seeded_by_migration = '003_offboarding_permissions_seed';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM core.permissions WHERE code LIKE 'OFFBOARDING\_%') THEN RAISE EXCEPTION '003 ROLLBACK POST-CHECK: offboarding permissions remain'; END IF;
    IF EXISTS (SELECT 1 FROM workflow._seed_provenance WHERE seeded_by_migration = '003_offboarding_permissions_seed') THEN RAISE EXCEPTION '003 ROLLBACK POST-CHECK: provenance rows remain'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 003_offboarding_permissions_seed_ROLLBACK.sql
-- ========================================================================
