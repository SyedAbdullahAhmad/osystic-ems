-- ========================================================================
-- 001_leave_schema.sql
-- Phase 2: Leave Module - core tables
--
-- Data ownership model, exactly as instructed by team lead:
--   - leave.leave_requests owns the leave business record
--   - leave.leave_requests.workflow_request_id links to workflow.approval_requests
--   - workflow.* owns all approval routing/state (steps, assignees, actions,
--     status_history) - this module never writes to those tables directly
--   - leave module owns leave-specific policy validation, balance checks,
--     and final leave-ledger effects
--
-- Corrections applied vs. the original EMS_part2_revised.dbml draft
-- (see LEAVE_MODULE_HANDOFF.md for full context):
--   1. NO leave.leave_approvals table - approval history lives entirely in
--      workflow.status_history / workflow.approval_actions. A read-only
--      view is provided below instead (leave.v_leave_request_approvals).
--   2. leave_requests.workflow_request_id ADDED - the actual link this
--      whole design depends on, missing from the stale draft.
--   3. created_by/updated_by reference auth.users(id), NOT core.profiles -
--      core.profiles does not match the confirmed real RBAC model
--      (core.roles/permissions/role_permissions/user_roles), and is not
--      used anywhere in the workflow schema either.
-- ========================================================================

CREATE SCHEMA IF NOT EXISTS "leave";

CREATE TYPE "leave"."leave_type_status" AS ENUM ('ACTIVE', 'INACTIVE');
CREATE TYPE "leave"."ledger_movement_type" AS ENUM ('ACCRUAL', 'DEDUCTION', 'ADJUSTMENT', 'CARRYOVER', 'FORFEITURE');
CREATE TYPE "leave"."leave_request_status" AS ENUM ('DRAFT', 'SUBMITTED', 'APPROVED', 'REJECTED', 'CANCELLED');

-- ------------------------------------------------------------------------
-- leave.leave_types - reference data, rarely changes
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "leave"."leave_types" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "leave_code" varchar(50) NOT NULL UNIQUE,
    "leave_name" varchar(255) NOT NULL,
    "description" text,
    "requires_approval" boolean NOT NULL DEFAULT true,
    "is_paid" boolean NOT NULL DEFAULT true,
    "max_days_per_year" numeric(6,2),
    "status" "leave"."leave_type_status" NOT NULL DEFAULT 'ACTIVE',
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

-- ------------------------------------------------------------------------
-- leave.leave_ledger - append-only. Balances are ALWAYS derived as
-- SUM(amount_days) grouped by (employee_id, leave_type_id) - no code
-- anywhere writes available_days/used_days/pending_days directly.
-- (This rule carried forward from the DBML draft - it was correct there.)
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "leave"."leave_ledger" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "employee_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "leave_type_id" uuid NOT NULL REFERENCES "leave"."leave_types"("id"),
    "movement_type" "leave"."ledger_movement_type" NOT NULL,
    "amount_days" numeric(6,2) NOT NULL,
    "effective_date" date NOT NULL DEFAULT CURRENT_DATE,
    "policy_version_id" uuid,
    "source_request_id" uuid,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);
-- source_request_id's FK to leave_requests is added via ALTER TABLE
-- further below, once leave_requests exists - inline REFERENCES here
-- would fail at DDL time since leave_requests isn't defined yet
-- (unlike a deferred CONSTRAINT trigger, Postgres needs the referenced
-- table to already exist to even parse an inline REFERENCES clause).

-- ------------------------------------------------------------------------
-- leave.leave_requests - the business record. workflow_request_id is the
-- link into the centralized workflow engine - THE key architectural piece.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "leave"."leave_requests" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "employee_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "leave_type_id" uuid NOT NULL REFERENCES "leave"."leave_types"("id"),
    "start_date" date NOT NULL,
    "end_date" date NOT NULL,
    "total_days" numeric(6,2) NOT NULL CHECK ("total_days" > 0),
    "reason" text,
    "request_status" "leave"."leave_request_status" NOT NULL DEFAULT 'DRAFT',
    "workflow_request_id" uuid REFERENCES "workflow"."approval_requests"("id"),
    "submitted_at" timestamptz,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1,
    CHECK ("end_date" >= "start_date")
);

ALTER TABLE "leave"."leave_ledger"
    ADD CONSTRAINT "leave_ledger_source_request_id_fkey"
    FOREIGN KEY ("source_request_id") REFERENCES "leave"."leave_requests"("id");

-- ------------------------------------------------------------------------
-- leave.leave_accruals / leave.leave_adjustments - each movement here
-- MUST also produce a corresponding leave_ledger row (enforced by the
-- trigger below) - these tables record the WHY, leave_ledger records the
-- actual balance-affecting movement.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "leave"."leave_accruals" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "employee_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "leave_type_id" uuid NOT NULL REFERENCES "leave"."leave_types"("id"),
    "accrued_days" numeric(6,2) NOT NULL,
    "accrual_date" date NOT NULL DEFAULT CURRENT_DATE,
    "remarks" text,
    "ledger_id" uuid NOT NULL REFERENCES "leave"."leave_ledger"("id"),
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS "leave"."leave_adjustments" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "employee_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "leave_type_id" uuid NOT NULL REFERENCES "leave"."leave_types"("id"),
    "adjustment_days" numeric(6,2) NOT NULL,
    "adjustment_reason" text NOT NULL,
    "ledger_id" uuid NOT NULL REFERENCES "leave"."leave_ledger"("id"),
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS "idx_leave_requests_employee" ON "leave"."leave_requests"("employee_id");
CREATE INDEX IF NOT EXISTS "idx_leave_requests_workflow" ON "leave"."leave_requests"("workflow_request_id");
CREATE INDEX IF NOT EXISTS "idx_leave_ledger_employee_type" ON "leave"."leave_ledger"("employee_id", "leave_type_id");

-- ========================================================================
-- END 001_leave_schema.sql
-- ========================================================================
