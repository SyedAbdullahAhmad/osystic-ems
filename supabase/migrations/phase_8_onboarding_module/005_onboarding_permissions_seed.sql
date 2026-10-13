-- ========================================================================
-- 005_onboarding_permissions_seed.sql  (v3 - corrected per Arslan's
-- round-2 review, item 3)
-- Idempotent, safe as a normal migration. ONBOARDING_MANAGE confirmed
-- as a NEW permission (v2 S6, decision #4) - not a reuse of
-- PEOPLE_MANAGE.
--
-- CHANGE IN THIS REVISION:
--   The round-1 fix recorded nothing provenance-wise and let rollback
--   infer "safe to delete" from the CURRENT absence of role_permissions
--   references - which, as Arslan pointed out, proves nothing about
--   whether 005 actually created the row: if ONBOARDING_MANAGE already
--   existed before this migration for some other reason and simply had
--   no role mapping yet, that heuristic would delete pre-existing
--   shared data on rollback.
--
--   FIX: reuses the exact same deterministic provenance mechanism
--   already established for the shared engine's own permission seed
--   (workflow."_seed_provenance" - see
--   phase_2_workflow_engine/006_workflow_reference_seed.sql) rather
--   than inventing a second tracking table. RETURNING on the INSERT
--   captures ONLY the rows THIS statement actually newly created - a
--   permission that already existed and merely matched the
--   WHERE NOT EXISTS guard is never recorded here, so rollback can
--   never mistake it for something 005 created.
-- ========================================================================

WITH "inserted_permissions" AS (
    INSERT INTO "core"."permissions" ("code", "name", "module", "action", "description", "created_by")
    SELECT * FROM (VALUES
        ('ONBOARDING_MANAGE', 'Manage Onboarding', 'onboarding', 'MANAGE', 'Create and approve onboarding_records via the controlled RPC path only - no general row INSERT/UPDATE privilege exists for this permission (see 002). HIRED is reachable only via confirm_employee_hire(), WITHDRAWN only via withdraw_onboarding_request(), and APPROVED/REJECTED only via the workflow engine''s own reaction trigger - maker-checker is enforced on the approval step so the submitter cannot also approve their own candidate', NULL::uuid),
        ('ONBOARDING_VIEW_ALL', 'View All Onboarding Records', 'onboarding', 'VIEW_ALL', 'View any onboarding_records row, regardless of involvement', NULL::uuid)
    ) AS v("code", "name", "module", "action", "description", "created_by")
    WHERE NOT EXISTS (
        SELECT 1 FROM "core"."permissions" WHERE "permissions"."code" = v."code"
    )
    RETURNING "id"
)
INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
SELECT 'core', 'permissions', "id", '005_onboarding_permissions_seed'
FROM "inserted_permissions"
ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;

-- ========================================================================
-- END 005_onboarding_permissions_seed.sql
-- ========================================================================
