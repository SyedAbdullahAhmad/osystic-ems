-- ========================================================================
-- 006_workflow_reference_seed.sql
--
-- DEPENDENCY: 001-005 already applied. Also depends on Finance's
-- existing core.permissions table (not created here - rows inserted
-- into it).
--
-- SCOPE, DELIBERATELY MINIMAL: this file seeds only the two permission
-- CODES the engine itself requires to function (WORKFLOW_CONFIG_MANAGE,
-- WORKFLOW_VIEW_ALL, referenced by 005's RLS policies). It does NOT
-- seed any role_permissions mapping.
--
-- ITEM 11 (round 2): the role_permissions heuristic mapping that used
-- to live here was REMOVED, not fixed in place, per your explicit
-- decision. Confirmed independently against Finance's actual
-- schema.sql: core.role_permissions has NO unique constraint on
-- (role_id, permission_id, effective_from) - the old ON CONFLICT
-- clause against that table would have failed outright on first
-- apply, independent of the rollback-ownership concern that also
-- applied. Role-to-permission mapping is a SEPARATE migration (see
-- your exact decision below), naming real core.roles rows directly.
--
-- ITEM 5 (round 3): deterministic rollback provenance. core.permissions
-- carries no "created by this migration" marker of its own, so this
-- file creates one small, self-contained tracking table and populates
-- it ONLY with the ids of rows its own INSERT actually newly created
-- (captured via RETURNING on the INSERT itself - a row that already
-- existed and merely matched via ON CONFLICT DO NOTHING is never
-- recorded here, so rollback can never mistake it for something 006
-- created). This replaces the previous round's "skip deletion if
-- currently unreferenced" heuristic, which could not actually prove
-- origin - only inferred current disuse. Provenance now proves origin
-- directly.
--
-- OUT OF SCOPE, ON PURPOSE (unchanged from before): actual business
-- workflow_definitions / workflow_versions / workflow_steps /
-- workflow_step_assignees / transition_rules content (e.g. a real
-- "LEAVE_REQUEST_APPROVAL" workflow) is NOT seeded here. That content
-- belongs to each consuming module's own migration or admin tooling.
-- ========================================================================


-- ------------------------------------------------------------------------
-- Provenance tracking table, owned entirely by this seed file (not a
-- general-purpose migration-tracking mechanism - scoped narrowly to
-- what 006 itself seeds, so its own rollback can act deterministically
-- without guessing).
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."_seed_provenance" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "schema_name" text NOT NULL,
    "table_name" text NOT NULL,
    "record_id" uuid NOT NULL,
    "seeded_by_migration" text NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    UNIQUE ("schema_name", "table_name", "record_id")
);


-- ------------------------------------------------------------------------
-- Permission codes. Idempotent via ON CONFLICT on the existing
-- core.permissions.code UNIQUE constraint (Finance's own "permissions_code_key",
-- confirmed present against the actual schema). RETURNING on the
-- INSERT captures ONLY the rows THIS statement actually created - a
-- pre-existing row that hits the ON CONFLICT DO NOTHING branch is not
-- returned, and therefore never recorded in provenance below.
-- ------------------------------------------------------------------------

WITH "inserted_permissions" AS (
    INSERT INTO "core"."permissions" ("code", "name", "module", "action", "description", "is_system")
    VALUES
        (
            'WORKFLOW_CONFIG_MANAGE',
            'Manage Workflow Configuration',
            'workflow',
            'MANAGE',
            'Create and edit workflow_definitions, workflow_versions, workflow_steps, workflow_step_assignees, and transition_rules. Does not grant the ability to act on individual approval requests - see WORKFLOW_VIEW_ALL and each module''s own action-level permission codes for that.',
            true
        ),
        (
            'WORKFLOW_VIEW_ALL',
            'View All Workflow Requests',
            'workflow',
            'VIEW',
            'View any workflow.approval_requests row and its steps/actions/history regardless of ownership or assignment. Does not grant the ability to act - approving/rejecting still requires assignee eligibility, enforced by workflow.process_approval_action().',
            true
        )
    ON CONFLICT ("code") DO NOTHING
    RETURNING "id"
)
INSERT INTO "workflow"."_seed_provenance" ("schema_name", "table_name", "record_id", "seeded_by_migration")
SELECT 'core', 'permissions', "id", '006_workflow_reference_seed'
FROM "inserted_permissions"
ON CONFLICT ("schema_name", "table_name", "record_id") DO NOTHING;


-- ========================================================================
-- END 006_workflow_reference_seed.sql
-- ========================================================================
