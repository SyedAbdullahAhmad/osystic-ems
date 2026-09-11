-- ========================================================================
-- 001_assets_schema.sql
-- Phase 5: Assets Module - core tables
--
-- Scope note: this covers a REQUEST-AND-ASSIGN slice of asset management -
-- an employee requests an asset by category, an Asset Manager approves
-- through the workflow engine, then fulfills the request by handing over
-- a specific physical unit. The DBML's broader asset lifecycle (events,
-- returns, verifications, damage reports, offboarding clearance links) is
-- real future scope but not built here - same "a slice, not the whole
-- draft" approach already used for Attendance Corrections.
--
-- Corrections applied vs. EMS_part2_revised.dbml's assets.* tables (same
-- 2 of the 3 recurring issues already fixed for leave/attendance - the
-- DBML's asset tables have NO approval_status/approved_by columns at all,
-- so issue #1 doesn't apply here, there's simply no workflow integration
-- to begin with, which this module adds):
--   1. created_by/updated_by/assigned_by/received_by/verified_by/
--      cleared_by/performed_by all referenced core.profiles.id in the
--      DBML. Changed to auth.users(id), same as every other module.
--   2. employee_id (on asset_assignments/asset_damage_reports) referenced
--      hr.employees.id, which doesn't exist. Changed to auth.users(id)
--      directly, same deliberate simplification as leave/attendance.
--   3. NEW, not a DBML fix: assets.asset_requests doesn't exist in the
--      DBML at all - the draft jumps straight from an asset existing to
--      it being assigned, with no request/approval stage. Added here as
--      the actual integration point with the centralized workflow
--      engine, same architectural role as leave_requests/
--      correction_requests.
--
-- The genuine advantage of this module vs. Leave/Attendance: the
-- approver here is resolved by PERMISSION (ASSET_MANAGE), not by a
-- per-employee manager/HR lookup - so there is no HR/org-structure
-- blocker and no test-admin placeholder needed (see 004's header).
-- ========================================================================

CREATE SCHEMA IF NOT EXISTS "assets";

CREATE TYPE "assets"."asset_status" AS ENUM ('AVAILABLE', 'ASSIGNED', 'IN_REPAIR', 'RETIRED');
CREATE TYPE "assets"."asset_request_status" AS ENUM ('SUBMITTED', 'APPROVED', 'REJECTED', 'CANCELLED', 'FULFILLED');

CREATE TABLE IF NOT EXISTS "assets"."asset_categories" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "category_code" varchar(50) NOT NULL UNIQUE,
    "category_name" varchar(255) NOT NULL,
    "description" text,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS "assets"."assets" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "asset_category_id" uuid NOT NULL REFERENCES "assets"."asset_categories"("id"),
    "asset_code" varchar(100) NOT NULL UNIQUE,
    "asset_name" varchar(255) NOT NULL,
    "serial_number" varchar(255),
    "current_status" "assets"."asset_status" NOT NULL DEFAULT 'AVAILABLE',
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

-- ------------------------------------------------------------------------
-- assets.asset_requests - the business record and the actual integration
-- point with the workflow engine. Requested by category, not a specific
-- unit - the specific physical asset is chosen at fulfillment time (003),
-- since real handover involves picking an actual available unit, not a
-- blind auto-assignment at approval time.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "assets"."asset_requests" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "employee_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "asset_category_id" uuid NOT NULL REFERENCES "assets"."asset_categories"("id"),
    "justification" text NOT NULL,
    "request_status" "assets"."asset_request_status" NOT NULL DEFAULT 'SUBMITTED',
    "workflow_request_id" uuid REFERENCES "workflow"."approval_requests"("id"),
    "submitted_at" timestamptz,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

-- ------------------------------------------------------------------------
-- assets.asset_assignments - created only at fulfillment (003), after
-- the request has been APPROVED. One active assignment per asset at a
-- time, enforced below.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "assets"."asset_assignments" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "asset_request_id" uuid NOT NULL REFERENCES "assets"."asset_requests"("id"),
    "asset_id" uuid NOT NULL REFERENCES "assets"."assets"("id"),
    "employee_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "assigned_at" timestamptz NOT NULL DEFAULT now(),
    "assigned_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "returned_at" timestamptz,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "version" int NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS "idx_assets_category" ON "assets"."assets"("asset_category_id");
CREATE INDEX IF NOT EXISTS "idx_asset_requests_employee" ON "assets"."asset_requests"("employee_id");
CREATE INDEX IF NOT EXISTS "idx_asset_requests_workflow" ON "assets"."asset_requests"("workflow_request_id");
CREATE INDEX IF NOT EXISTS "idx_asset_assignments_asset" ON "assets"."asset_assignments"("asset_id");
CREATE INDEX IF NOT EXISTS "idx_asset_assignments_employee" ON "assets"."asset_assignments"("employee_id");

-- Only one currently-active (not yet returned) assignment per asset.
CREATE UNIQUE INDEX IF NOT EXISTS "idx_asset_assignments_one_active_per_asset"
    ON "assets"."asset_assignments"("asset_id")
    WHERE "returned_at" IS NULL;

-- ========================================================================
-- END 001_assets_schema.sql
-- ========================================================================
