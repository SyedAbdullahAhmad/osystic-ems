-- ========================================================================
-- 006_leave_permissions_seed.sql
-- Mirrors 006_workflow_reference_seed.sql's exact pattern: idempotent
-- (WHERE NOT EXISTS), created_by left NULL (nullable on core.permissions,
-- confirmed against the stub/real schema), safe as a normal migration -
-- unlike workflow_definitions, core.permissions has no actor-integrity
-- trigger requiring an authenticated session.
-- ========================================================================

INSERT INTO "core"."permissions" ("code", "name", "module", "action", "description", "created_by")
SELECT * FROM (VALUES
    ('LEAVE_CONFIG_MANAGE', 'Manage Leave Configuration', 'leave', 'MANAGE', 'Create/edit leave types and workflow configuration', NULL::uuid),
    ('LEAVE_VIEW_ALL', 'View All Leave Requests', 'leave', 'VIEW_ALL', 'View any employee''s leave requests and balances, regardless of involvement', NULL::uuid)
) AS v("code", "name", "module", "action", "description", "created_by")
WHERE NOT EXISTS (
    SELECT 1 FROM "core"."permissions" WHERE "permissions"."code" = v."code"
);

-- ========================================================================
-- END 006_leave_permissions_seed.sql
-- ========================================================================
