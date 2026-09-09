-- ========================================================================
-- 001_attendance_corrections_schema.sql
-- Phase 4: Attendance Corrections Module - core tables
--
-- Scope note: this covers ATTENDANCE CORRECTIONS specifically (the module
-- named in the original module list), not the full attendance-tracking
-- system (shifts, holidays, biometric/NFC event ingestion, timesheets).
-- Those exist as a broader draft in EMS_part2_revised.dbml but are a
-- separate, larger piece of work with their own dependencies (real
-- device/event pipeline) - out of scope here, same way hr.employees was
-- out of scope for Leave.
--
-- Data ownership model, mirroring the proven Leave Module pattern exactly:
--   - attendance.correction_requests owns the correction business record
--   - attendance.correction_requests.workflow_request_id links to
--     workflow.approval_requests
--   - workflow.* owns all approval routing/state - this module never
--     writes to those tables directly
--   - attendance module owns correction-specific validation and the final
--     effect on the attendance_days record once approved
--
-- Corrections applied vs. the original EMS_part2_revised.dbml draft
-- (same 3 issues already found and fixed once for leave.leave_approvals -
-- see LEAVE_MODULE_HANDOFF.md; flagging again here since the attendance
-- section of the DBML was never revisited after that review):
--   1. The DBML's attendance.correction_requests has its own
--      approval_status / approved_by / approved_at columns - this
--      duplicates data the centralized workflow engine already owns,
--      the exact anti-pattern the team lead explicitly rejected for
--      leave.leave_approvals ("do not maintain a second writable
--      approvals table"). REMOVED. workflow_request_id ADDED instead -
--      the actual link this design depends on, same as leave_requests.
--   2. created_by/updated_by/approved_by referenced core.profiles.id in
--      the DBML - core.profiles does not match the confirmed real RBAC
--      model. Changed to auth.users(id), consistent with every other
--      table in workflow and leave.
--   3. employee_id referenced hr.employees.id, which does not exist yet
--      (no HR/org-structure module). Changed to auth.users(id) directly -
--      the same deliberate simplification already applied to
--      leave.leave_requests.employee_id, flagged the same way: revisit
--      once an HR module exists.
--
-- Design note (proposal, not yet confirmed by team lead - flagging for
-- review the same way the original workflow ERD was submitted before
-- being applied): since no check-in/biometric pipeline exists yet either,
-- attendance.attendance_days is intentionally minimal here, and
-- attendance.submit_correction_request() (003) find-or-creates the day
-- row rather than requiring it to already exist - this also covers the
-- real-world case of an employee correcting a day with NO record at all
-- (e.g. forgot to check in), not just editing a wrong time.
-- ========================================================================

CREATE SCHEMA IF NOT EXISTS "attendance";

CREATE TYPE "attendance"."attendance_status" AS ENUM ('PRESENT', 'ABSENT', 'LATE', 'HALF_DAY', 'ON_LEAVE');
CREATE TYPE "attendance"."correction_request_status" AS ENUM ('SUBMITTED', 'APPROVED', 'REJECTED', 'CANCELLED');

-- ------------------------------------------------------------------------
-- attendance.attendance_days - one row per employee per day. Minimal by
-- design (see header) - a future check-in/NFC event pipeline would
-- populate first_check_in/last_check_out/worked_minutes directly; until
-- then, rows are created on-demand by a correction request.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "attendance"."attendance_days" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "employee_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "attendance_date" date NOT NULL,
    "first_check_in" timestamptz,
    "last_check_out" timestamptz,
    "worked_minutes" int,
    "attendance_status" "attendance"."attendance_status" NOT NULL DEFAULT 'ABSENT',
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1,
    UNIQUE ("employee_id", "attendance_date")
);

-- ------------------------------------------------------------------------
-- attendance.correction_requests - the business record.
-- workflow_request_id is the link into the centralized workflow engine,
-- same architectural role as leave_requests.workflow_request_id.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "attendance"."correction_requests" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "attendance_day_id" uuid NOT NULL REFERENCES "attendance"."attendance_days"("id"),
    "employee_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "requested_check_in" timestamptz,
    "requested_check_out" timestamptz,
    "reason" text NOT NULL,
    "request_status" "attendance"."correction_request_status" NOT NULL DEFAULT 'SUBMITTED',
    "workflow_request_id" uuid REFERENCES "workflow"."approval_requests"("id"),
    "submitted_at" timestamptz,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1,
    CHECK ("requested_check_in" IS NOT NULL OR "requested_check_out" IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS "idx_attendance_days_employee_date" ON "attendance"."attendance_days"("employee_id", "attendance_date");
CREATE INDEX IF NOT EXISTS "idx_correction_requests_employee" ON "attendance"."correction_requests"("employee_id");
CREATE INDEX IF NOT EXISTS "idx_correction_requests_workflow" ON "attendance"."correction_requests"("workflow_request_id");
CREATE INDEX IF NOT EXISTS "idx_correction_requests_attendance_day" ON "attendance"."correction_requests"("attendance_day_id");

-- One open (SUBMITTED) correction request per attendance day at a time -
-- same "no duplicate open request" guarantee workflow.approval_requests
-- itself enforces per entity, applied here at the module level too so the
-- RPC has a clean, obvious guard to check.
CREATE UNIQUE INDEX IF NOT EXISTS "idx_correction_requests_one_open_per_day"
    ON "attendance"."correction_requests"("attendance_day_id")
    WHERE "request_status" = 'SUBMITTED';

-- ========================================================================
-- END 001_attendance_corrections_schema.sql
-- ========================================================================
