-- ========================================================================
-- 005_attendance_permissions_seed.sql
-- Mirrors 006_leave_permissions_seed.sql's exact pattern: idempotent
-- (WHERE NOT EXISTS), created_by left NULL (nullable on core.permissions),
-- safe as a normal migration - core.permissions has no actor-integrity
-- trigger requiring an authenticated session.
-- ========================================================================

INSERT INTO "core"."permissions" ("code", "name", "module", "action", "description", "created_by")
SELECT * FROM (VALUES
    ('ATTENDANCE_CONFIG_MANAGE', 'Manage Attendance Configuration', 'attendance', 'MANAGE', 'Manage attendance correction workflow configuration', NULL::uuid),
    ('ATTENDANCE_VIEW_ALL', 'View All Attendance Records', 'attendance', 'VIEW_ALL', 'View any employee''s attendance days and correction requests, regardless of involvement', NULL::uuid)
) AS v("code", "name", "module", "action", "description", "created_by")
WHERE NOT EXISTS (
    SELECT 1 FROM "core"."permissions" WHERE "permissions"."code" = v."code"
);

-- ========================================================================
-- END 005_attendance_permissions_seed.sql
-- ========================================================================
