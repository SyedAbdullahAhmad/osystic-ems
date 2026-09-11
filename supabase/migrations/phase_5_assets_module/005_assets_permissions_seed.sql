-- ========================================================================
-- 005_assets_permissions_seed.sql
-- Idempotent, safe as a normal migration - same pattern as
-- 006_leave_permissions_seed.sql / 005_attendance_permissions_seed.sql.
-- ========================================================================

INSERT INTO "core"."permissions" ("code", "name", "module", "action", "description", "created_by")
SELECT * FROM (VALUES
    ('ASSET_MANAGE', 'Manage Assets', 'assets', 'MANAGE', 'Approve asset requests, fulfill them with a physical unit, and manage the asset inventory/categories', NULL::uuid),
    ('ASSET_VIEW_ALL', 'View All Asset Requests', 'assets', 'VIEW_ALL', 'View any employee''s asset requests and assignments, regardless of involvement', NULL::uuid)
) AS v("code", "name", "module", "action", "description", "created_by")
WHERE NOT EXISTS (
    SELECT 1 FROM "core"."permissions" WHERE "permissions"."code" = v."code"
);

-- ========================================================================
-- END 005_assets_permissions_seed.sql
-- ========================================================================
