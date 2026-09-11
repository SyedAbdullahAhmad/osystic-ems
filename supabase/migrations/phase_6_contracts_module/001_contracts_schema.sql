-- ========================================================================
-- 001_contracts_schema.sql
-- Phase 6: Contracts Module - core tables
--
-- Scope note: this covers a CREATE-AND-APPROVE slice of contract
-- management - HR/Admin creates a contract (with its first version) for
-- an employee, a CONTRACT_MANAGE holder approves through the workflow
-- engine, and the contract goes ACTIVE automatically on approval (no
-- manual fulfillment-style step - see 003's header for why this differs
-- from Assets). The DBML's hr.employment_terms/compensation_term_refs
-- are real future scope but not built here - same "a slice, not the
-- whole draft" approach used for Attendance Corrections and Assets.
-- Design finalized in CONTRACTS_MODULE_DESIGN_NOTES.md, confirmed by
-- team lead.
--
-- Corrections applied vs. EMS_part2_revised.dbml's hr.contracts /
-- hr.contract_versions (same recurring issues already fixed for
-- leave/attendance/assets):
--   1. employee_id/created_by/updated_by referenced hr.employees.id /
--      core.profiles.id in the DBML. Changed to auth.users(id) directly,
--      same as every other module.
--   2. NEW, not a DBML fix: hr.contract_requests doesn't exist in the
--      DBML at all - the draft has no workflow integration whatsoever.
--      Added here as the actual integration point with the centralized
--      workflow engine, same architectural role as
--      leave_requests/correction_requests/asset_requests. Deliberately
--      NOT reusing hr.contracts.status as the thing the workflow trigger
--      writes to via contract_requests directly - see 002/003 for why
--      contract_requests carries no separate status column of its own
--      (would duplicate hr.contracts.status and risk drift).
--   3. current_version_id circular reference: hr.contracts references
--      hr.contract_versions.id, and hr.contract_versions references back
--      to hr.contracts.id. Resolved below by creating contracts first
--      WITHOUT the FK constraint on current_version_id, then
--      contract_versions, then adding the FK via ALTER TABLE. Team lead
--      confirmed this approach (direct FK set by the create RPC, not a
--      computed view) over the alternative considered in design notes.
--
-- Actor model, per team lead's decision: HR/Admin-initiated only (no
-- employee-initiated flow in this slice). Approver resolved by
-- PERMISSION (CONTRACT_MANAGE), same clean mechanism as Assets'
-- ASSET_MANAGE - no manager/org-chart lookup, no placeholder needed.
-- ========================================================================

CREATE SCHEMA IF NOT EXISTS "hr";

CREATE TYPE "hr"."contract_type" AS ENUM ('PERMANENT', 'FIXED_TERM', 'PROBATION', 'INTERNSHIP', 'CONTRACTOR');

-- EXPIRED/TERMINATED included for completeness/future work - no RPC in
-- this slice transitions a contract into either of those (see 003's
-- header). DRAFT is also unused by the current create RPC (which creates
-- and submits in the same call - no separate draft-then-submit flow
-- built yet) but kept in the enum since it's a natural, low-cost future
-- addition and the DBML/team-lead-confirmed list both include it.
CREATE TYPE "hr"."contract_status" AS ENUM ('DRAFT', 'PENDING_APPROVAL', 'APPROVED', 'REJECTED', 'ACTIVE', 'EXPIRED', 'TERMINATED');

CREATE TABLE IF NOT EXISTS "hr"."contracts" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "employee_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "contract_number" varchar(100) NOT NULL UNIQUE,
    "contract_type" "hr"."contract_type" NOT NULL,
    "current_version_id" uuid,  -- FK added below, after contract_versions exists
    "status" "hr"."contract_status" NOT NULL DEFAULT 'DRAFT',
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

-- ------------------------------------------------------------------------
-- hr.contract_versions - the actual contract terms/document for a given
-- version. document_file_id is intentionally a plain nullable uuid with
-- NO foreign key - no file-storage table exists anywhere in this project
-- yet (first module to touch this concern at all), per team lead's
-- decision that a file upload is optional for this slice. Whenever a
-- real file-storage table exists, this becomes a proper FK then.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "hr"."contract_versions" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "contract_id" uuid NOT NULL REFERENCES "hr"."contracts"("id"),
    "version_no" int NOT NULL,
    "effective_from" date NOT NULL,
    "effective_to" date,
    "document_file_id" uuid,
    "notes" text,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1,
    UNIQUE ("contract_id", "version_no")
);

ALTER TABLE "hr"."contracts"
    ADD CONSTRAINT "contracts_current_version_id_fkey"
    FOREIGN KEY ("current_version_id") REFERENCES "hr"."contract_versions"("id");

-- ------------------------------------------------------------------------
-- hr.contract_requests - purely a link/audit table between a contract
-- version and its workflow approval cycle. Deliberately has NO status
-- column of its own - hr.contracts.status is the single source of truth
-- for where a contract stands (unlike assets.asset_requests, which IS
-- the primary business record). Duplicating status here would just be
-- another place for two columns to drift out of sync.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "hr"."contract_requests" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "contract_id" uuid NOT NULL REFERENCES "hr"."contracts"("id"),
    "contract_version_id" uuid NOT NULL REFERENCES "hr"."contract_versions"("id"),
    "workflow_request_id" uuid REFERENCES "workflow"."approval_requests"("id"),
    "requested_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "submitted_at" timestamptz,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS "idx_contracts_employee" ON "hr"."contracts"("employee_id");
CREATE INDEX IF NOT EXISTS "idx_contracts_current_version" ON "hr"."contracts"("current_version_id");
CREATE INDEX IF NOT EXISTS "idx_contract_versions_contract" ON "hr"."contract_versions"("contract_id");
CREATE INDEX IF NOT EXISTS "idx_contract_requests_contract" ON "hr"."contract_requests"("contract_id");
CREATE INDEX IF NOT EXISTS "idx_contract_requests_workflow" ON "hr"."contract_requests"("workflow_request_id");

-- ========================================================================
-- END 001_contracts_schema.sql
-- ========================================================================
