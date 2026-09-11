-- ========================================================================
-- 005_contracts_permissions_seed.sql
-- Idempotent, safe as a normal migration - same pattern as
-- 005_assets_permissions_seed.sql / 006_leave_permissions_seed.sql /
-- 005_attendance_permissions_seed.sql.
-- ========================================================================

INSERT INTO "core"."permissions" ("code", "name", "module", "action", "description", "created_by")
SELECT * FROM (VALUES
    ('CONTRACT_MANAGE', 'Manage Contracts', 'contracts', 'MANAGE', 'Create contracts for employees and approve them through the workflow engine. Governs both creation and approval in this slice - no segregation-of-duties split yet (see design notes)', NULL::uuid),
    ('CONTRACT_VIEW_ALL', 'View All Contracts', 'contracts', 'VIEW_ALL', 'View any employee''s contracts and contract requests, regardless of involvement', NULL::uuid)
) AS v("code", "name", "module", "action", "description", "created_by")
WHERE NOT EXISTS (
    SELECT 1 FROM "core"."permissions" WHERE "permissions"."code" = v."code"
);

-- ========================================================================
-- END 005_contracts_permissions_seed.sql
-- ========================================================================
