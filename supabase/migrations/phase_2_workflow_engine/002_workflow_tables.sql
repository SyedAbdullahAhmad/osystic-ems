-- ========================================================================
-- 002_workflow_tables.sql  (CONSOLIDATED BASELINE)
--
-- This is the squashed, final table set - it supersedes and replaces
-- the original 002 plus every column later added by 003c. Nothing in
-- this migration set has been applied to the shared database yet, so
-- this file IS the baseline, not a patch on top of an already-applied
-- one.
--
-- DEPENDENCIES: 001_workflow_types.sql, shared-core migration
-- (core.people/profiles/departments), Finance's existing core.roles/
-- permissions/role_permissions/user_roles, auth.users.
--
-- SCOPE OF THIS FILE: table shape only - columns, PRIMARY KEY,
-- NOT NULL, DEFAULT, and simple single-column REFERENCES. UNIQUE
-- constraints (including composite), CHECK constraints, composite
-- FKs, and indexes are in 003.
-- ========================================================================


-- ------------------------------------------------------------------------
-- 1. workflow.workflow_definitions
-- Item 6: initiation_permission_code added - NULL means any
-- authenticated user may start this workflow; set means the actor
-- must hold that specific permission.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."workflow_definitions" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "organization_id" uuid,
    "module" varchar(50) NOT NULL,
    "code" varchar(100) NOT NULL,
    "name" varchar(255) NOT NULL,
    "description" text,
    "initiation_permission_code" varchar(100),
    "is_active" boolean NOT NULL DEFAULT true,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES auth.users(id),
    "updated_by" uuid REFERENCES auth.users(id),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 2. workflow.workflow_versions
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."workflow_versions" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "workflow_definition_id" uuid NOT NULL REFERENCES "workflow"."workflow_definitions"(id),
    "version_no" int NOT NULL,
    "status" "workflow"."workflow_version_status" NOT NULL DEFAULT 'DRAFT',
    "effective_from" timestamptz,
    "effective_to" timestamptz,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES auth.users(id),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 3. workflow.workflow_statuses
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."workflow_statuses" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "workflow_version_id" uuid NOT NULL REFERENCES "workflow"."workflow_versions"(id),
    "workflow_definition_id" uuid NOT NULL,
    "status_code" varchar(50) NOT NULL,
    "display_name" varchar(100) NOT NULL,
    "is_initial" boolean NOT NULL DEFAULT false,
    "is_terminal" boolean NOT NULL DEFAULT false,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 4. workflow.workflow_steps
-- Item 3/4 support: rejection_mode, skip_allowed, skip_permission_code
-- baked in directly (previously added by 003c as an ALTER).
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."workflow_steps" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "workflow_version_id" uuid NOT NULL REFERENCES "workflow"."workflow_versions"(id),
    "step_key" varchar(50) NOT NULL,
    "step_no" int NOT NULL,
    "sequence_no" int NOT NULL,
    "parallel_group" varchar(50),
    "step_name" varchar(255) NOT NULL,
    "approval_mode" "workflow"."approval_mode" NOT NULL DEFAULT 'ONE_OF',
    "required_approvals" int,
    "is_maker_checker" boolean NOT NULL DEFAULT true,
    "rejection_mode" varchar(20) NOT NULL DEFAULT 'ANY_REJECT',
    "skip_allowed" boolean NOT NULL DEFAULT false,
    "skip_permission_code" varchar(100),
    "sla_minutes" int NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 5. workflow.workflow_step_assignees
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."workflow_step_assignees" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "workflow_step_id" uuid NOT NULL REFERENCES "workflow"."workflow_steps"(id),
    "assignee_type" "workflow"."assignee_type" NOT NULL,
    "role_id" uuid REFERENCES core.roles(id),
    "user_id" uuid REFERENCES auth.users(id),
    "permission_code" varchar(100),
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 6. workflow.transition_rules
-- Item 11: trigger_action is now NOT NULL directly - the "nullable
-- for now" provisional state from 003b no longer applies since this
-- is a fresh baseline with no existing rows to worry about breaking.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."transition_rules" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "workflow_version_id" uuid NOT NULL REFERENCES "workflow"."workflow_versions"(id),
    "workflow_definition_id" uuid NOT NULL,
    "from_status" varchar(50) NOT NULL,
    "to_status" varchar(50) NOT NULL,
    "trigger_action" "workflow"."approval_action_type" NOT NULL,
    "requires_role_id" uuid REFERENCES core.roles(id),
    "requires_permission_code" varchar(100),
    "is_maker_checker" boolean NOT NULL DEFAULT true,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 7. workflow.approval_requests
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."approval_requests" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "organization_id" uuid,
    "workflow_definition_id" uuid NOT NULL REFERENCES "workflow"."workflow_definitions"(id),
    "workflow_version_id" uuid NOT NULL,
    "module" varchar(50) NOT NULL,
    "entity_type" varchar(100) NOT NULL,
    "entity_id" uuid NOT NULL,
    "initiated_by_user_id" uuid NOT NULL REFERENCES auth.users(id),
    "current_status" varchar(50) NOT NULL,
    "current_step_no" int,
    "is_open" boolean NOT NULL DEFAULT true,
    "priority" "workflow"."approval_priority" NOT NULL DEFAULT 'NORMAL',
    "sla_due_at" timestamptz,
    "completed_at" timestamptz,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 8. workflow.approval_steps
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."approval_steps" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "approval_request_id" uuid NOT NULL REFERENCES "workflow"."approval_requests"(id),
    "workflow_step_id" uuid NOT NULL REFERENCES "workflow"."workflow_steps"(id),
    "workflow_version_id" uuid NOT NULL,
    "step_no" int NOT NULL,
    "sequence_no" int NOT NULL,
    "parallel_group" varchar(50),
    "approval_mode" "workflow"."approval_mode" NOT NULL,
    "required_approvals" int,
    "status" "workflow"."step_status" NOT NULL DEFAULT 'PENDING',
    "outcome_action_id" uuid,
    "sla_due_at" timestamptz,
    "started_at" timestamptz,
    "completed_at" timestamptz,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);
-- outcome_action_id (item 2): set to the specific APPROVE or REJECT
-- approval_actions.id that caused this step to resolve to APPROVED/
-- REJECTED. Never set by a SKIP action, even when a SKIP is what
-- completes an ALL_OF step's quorum by shrinking the denominator -
-- SKIP is not approval evidence. FK added in 003 (after
-- approval_actions exists, avoiding a forward reference here).


-- ------------------------------------------------------------------------
-- 9. workflow.approval_step_assignees
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."approval_step_assignees" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "approval_step_id" uuid NOT NULL REFERENCES "workflow"."approval_steps"(id),
    "assignee_user_id" uuid NOT NULL REFERENCES auth.users(id),
    "workflow_step_assignee_id" uuid REFERENCES "workflow"."workflow_step_assignees"(id),
    "resolved_from_role_id" uuid REFERENCES core.roles(id),
    "resolved_from_permission_code" varchar(100),
    "status" "workflow"."assignee_status" NOT NULL DEFAULT 'PENDING',
    "responded_at" timestamptz,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 10. workflow.delegations
-- -- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."delegations" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "organization_id" uuid,
    "delegator_user_id" uuid NOT NULL REFERENCES auth.users(id),
    "delegate_user_id" uuid NOT NULL REFERENCES auth.users(id),
    "role_id" uuid REFERENCES core.roles(id),
    "module" varchar(50),
    "valid_from" timestamptz NOT NULL,
    "valid_to" timestamptz NOT NULL,
    "reason" text,
    "is_active" boolean NOT NULL DEFAULT true,
    "revoked_at" timestamptz,
    "revoked_by" uuid REFERENCES auth.users(id),
    "revocation_reason" text,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES auth.users(id),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 11. workflow.approval_actions
-- Item 7: idempotency_key uniqueness is now composite with
-- approval_request_id (see 003) - NOT globally unique, matching what
-- the RPC actually implements. payload_hash baked in directly.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."approval_actions" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "approval_request_id" uuid NOT NULL REFERENCES "workflow"."approval_requests"(id),
    "approval_step_id" uuid REFERENCES "workflow"."approval_steps"(id),
    "actor_type" "workflow"."actor_type" NOT NULL DEFAULT 'USER',
    "actor_user_id" uuid REFERENCES auth.users(id),
    "action" "workflow"."approval_action_type" NOT NULL,
    "idempotency_key" varchar(255) NOT NULL,
    "delegation_id" uuid REFERENCES "workflow"."delegations"(id),
    "comments" text,
    "metadata" jsonb,
    "payload_hash" text,
    "action_at" timestamptz NOT NULL DEFAULT now(),
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);
-- ------------------------------------------------------------------------
-- 12. workflow.sla_escalations
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."sla_escalations" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "approval_step_id" uuid NOT NULL REFERENCES "workflow"."approval_steps"(id),
    "escalation_level" int NOT NULL,
    "status" "workflow"."escalation_status" NOT NULL DEFAULT 'PENDING',
    "due_at" timestamptz NOT NULL,
    "escalated_to_user_id" uuid REFERENCES auth.users(id),
    "escalated_to_role_id" uuid REFERENCES core.roles(id),
    "escalated_at" timestamptz NOT NULL DEFAULT now(),
    "acknowledged_at" timestamptz,
    "resolved_at" timestamptz,
    "resolved_by_user_id" uuid REFERENCES auth.users(id),
    "resolution_code" varchar(50),
    "resolution_notes" text,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);


-- ------------------------------------------------------------------------
-- 13. workflow.status_history
-- Item 9: organization_id retained (was already present, just wasn't
-- being populated - that's fixed in 004, not here).
-- changed_by_actor_type baked in directly.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."status_history" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "organization_id" uuid,
    "approval_request_id" uuid NOT NULL REFERENCES "workflow"."approval_requests"(id),
    "approval_step_id" uuid REFERENCES "workflow"."approval_steps"(id),
    "workflow_version_id" uuid NOT NULL,
    "triggered_by_approval_action_id" uuid REFERENCES "workflow"."approval_actions"(id),
    "from_status" varchar(50),
    "to_status" varchar(50) NOT NULL,
    "changed_by_user_id" uuid REFERENCES auth.users(id),
    "changed_by_actor_type" "workflow"."actor_type" NOT NULL DEFAULT 'USER',
    "reason" text,
    "changed_at" timestamptz NOT NULL DEFAULT now(),
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);
-- triggered_by_approval_action_id (item 1): records which specific
-- approval_actions row was the decisive one for a stage-advancement
-- transition, so the answer to "who/what caused this transition" is
-- traceable to an exact, already-authorized action rather than
-- re-derived/re-authorized after the fact.


-- ------------------------------------------------------------------------
-- 14. workflow.request_start_idempotency  (NEW - item 7)
-- Durable idempotency for start_approval_request(), independent of
-- approval_actions (which doesn't exist yet at the moment START is
-- first called) and independent of whether the resulting request is
-- still open. A repeated start call with the same key must always
-- resolve to the SAME original request, even after that request has
-- since closed - the open-request lookup used before does not provide
-- that guarantee on its own.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."request_start_idempotency" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "idempotency_key" varchar(255) NOT NULL,
    "approval_request_id" uuid NOT NULL REFERENCES "workflow"."approval_requests"(id),
    "created_by" uuid NOT NULL REFERENCES auth.users(id),
    "payload_hash" text NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now()
);
-- Item 3: created_by is now NOT NULL and doubles as the actor-binding
-- field (the caller who owns this key). payload_hash covers
-- actor_user_id + workflow_definition_id + entity_type + entity_id +
-- metadata. On a key collision, start_approval_request() must verify
-- BOTH created_by = caller AND payload_hash matches before returning
-- ALREADY_PROCESSED - otherwise raise
-- WORKFLOW_IDEMPOTENCY_KEY_REUSE_MISMATCH. This stops the key from
-- acting as a bearer token for another user's request, and stops the
-- same caller silently reusing a key against different parameters.


-- ========================================================================
-- END 002_workflow_tables.sql
-- ========================================================================
