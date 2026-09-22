-- ========================================================================
-- 005_people_org_permissions_seed.sql
-- Idempotent, safe as a normal migration - same pattern as
-- 006_leave_permissions_seed.sql / 005_attendance_permissions_seed.sql /
-- 005_assets_permissions_seed.sql / 005_contracts_permissions_seed.sql.
-- ========================================================================

INSERT INTO "core"."permissions" ("code", "name", "module", "action", "description", "created_by")
SELECT * FROM (VALUES
    ('PEOPLE_MANAGE', 'Manage People & Organization', 'core', 'MANAGE', 'Create/update core.people, core.person_user_links, core.organizations, core.departments, and hr.employees records', NULL::uuid),
    ('PEOPLE_VIEW_ALL', 'View All People', 'core', 'VIEW_ALL', 'View any person''s core.people / hr.employees record, regardless of involvement', NULL::uuid)
) AS v("code", "name", "module", "action", "description", "created_by")
WHERE NOT EXISTS (
    SELECT 1 FROM "core"."permissions" WHERE "permissions"."code" = v."code"
);

-- ========================================================================
-- END 005_people_org_permissions_seed.sql
-- ========================================================================
