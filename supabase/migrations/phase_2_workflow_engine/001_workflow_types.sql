-- ========================================================================
-- 001_workflow_types.sql
-- Creates the workflow schema and all named enum types used by the
-- centralized Workflow Service tables (002_workflow_tables.sql).
--
-- DEPENDENCY: none. This is the first file in the migration sequence
-- and does not depend on the shared-core migration (core.people/
-- profiles/departments) or on Finance's existing core.roles/
-- core.permissions/core.role_permissions/core.user_roles, since it
-- only creates types, not tables with foreign keys.
--
-- Safe to re-run: type creation is wrapped so re-running this file on
-- an environment where the types already exist does not error.
--
-- EXTENSION DEPENDENCY (discovered during first real scratch apply):
-- start_approval_request() (004, item 3's idempotency payload_hash)
-- calls digest(), which is NOT built into Postgres core - it requires
-- the pgcrypto extension. gen_random_uuid() elsewhere in this package
-- did not surface this earlier because that specific function HAS
-- been built into core Postgres since PG13, unlike digest(). Declared
-- here, once, as a genuine prerequisite of this migration set.
-- ========================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE SCHEMA IF NOT EXISTS "workflow";
ALTER SCHEMA "workflow" OWNER TO "postgres";

COMMENT ON SCHEMA "workflow" IS
  'Centralized approval/workflow engine, shared across all EMS modules '
  '(leave, attendance corrections, contracts, onboarding, payroll '
  'snapshots, assets, NFC access, grievances, offboarding). Modules '
  'retain ownership of their own business record and status; this '
  'schema owns approval routing, maker-checker, delegation, escalation, '
  'and approval history only.';


-- ------------------------------------------------------------------------
-- workflow_version_status
-- ------------------------------------------------------------------------
DO $$
BEGIN
  CREATE TYPE "workflow"."workflow_version_status" AS ENUM (
    'DRAFT',
    'ACTIVE',
    'RETIRED'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------------------
-- approval_priority
-- ------------------------------------------------------------------------
DO $$
BEGIN
  CREATE TYPE "workflow"."approval_priority" AS ENUM (
    'LOW',
    'NORMAL',
    'HIGH',
    'URGENT'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------------------
-- approval_mode
-- ONE_OF   = any single assignee's approval completes the step
-- ALL_OF   = every assignee must approve
-- MIN_N    = at least workflow_steps.required_approvals assignees must approve
-- ------------------------------------------------------------------------
DO $$
BEGIN
  CREATE TYPE "workflow"."approval_mode" AS ENUM (
    'ONE_OF',
    'ALL_OF',
    'MIN_N'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------------------
-- assignee_type
-- Sole source of who can approve a step (workflow_step_assignees /
-- approval_step_assignees). PERMISSION supports permission-based
-- routing in addition to fixed ROLE or named USER assignment.
-- ------------------------------------------------------------------------
DO $$
BEGIN
  CREATE TYPE "workflow"."assignee_type" AS ENUM (
    'ROLE',
    'USER',
    'PERMISSION'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------------------
-- step_status (runtime approval_steps.status)
-- ------------------------------------------------------------------------
DO $$
BEGIN
  CREATE TYPE "workflow"."step_status" AS ENUM (
    'PENDING',
    'IN_PROGRESS',
    'APPROVED',
    'REJECTED',
    'SKIPPED',
    'ESCALATED',
    'CANCELLED'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------------------
-- assignee_status (runtime approval_step_assignees.status)
-- ------------------------------------------------------------------------
DO $$
BEGIN
  CREATE TYPE "workflow"."assignee_status" AS ENUM (
    'PENDING',
    'APPROVED',
    'REJECTED',
    'SKIPPED',
    'CANCELLED'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------------------
-- approval_action_type
-- Extended per review to include request-level and system-adjacent
-- actions, not just step-level maker-checker actions.
-- ------------------------------------------------------------------------
DO $$
BEGIN
  CREATE TYPE "workflow"."approval_action_type" AS ENUM (
    'SUBMIT',
    'VERIFY',
    'APPROVE',
    'REJECT',
    'DELEGATE',
    'ESCALATE',
    'RECALL',
    'CANCEL',
    'RESUBMIT',
    'CLAIM',
    'RELEASE',
    'SKIP'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------------------
-- escalation_status
-- ------------------------------------------------------------------------
DO $$
BEGIN
  CREATE TYPE "workflow"."escalation_status" AS ENUM (
    'PENDING',
    'NOTIFIED',
    'ACKNOWLEDGED',
    'RESOLVED',
    'EXPIRED'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------------------
-- actor_type
-- Distinguishes human-initiated approval_actions from system-generated
-- ones (SLA automation, integration-driven transitions). SYSTEM actions
-- carry actor_user_id = NULL rather than being attributed to an
-- unrelated human - see 002_workflow_tables.sql approval_actions and
-- the CHECK constraint added in 003_workflow_constraints_indexes.sql.
-- ------------------------------------------------------------------------
DO $$
BEGIN
  CREATE TYPE "workflow"."actor_type" AS ENUM (
    'USER',
    'SYSTEM'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;


-- ========================================================================
-- END 001_workflow_types.sql
-- ========================================================================
