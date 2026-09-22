-- ========================================================================
-- 011_drop_legacy_employee_id.sql
-- Phase 7: drop the legacy employee_id column from all 9 tables, and
-- (recommended, see below) switch RLS/RPC authorization to depend on
-- hr_employee_id instead of employee_id.
--
-- ****************************************************************
-- * HELD. DO NOT RUN. Written now so the whole package is        *
-- * reviewable as a unit, per the team lead's explicit            *
-- * instruction: this file requires a SEPARATE sign-off, after    *
-- * 010's checks pass clean, before it is ever executed.          *
-- * Confirmed a second time in the team lead's follow-up review:  *
-- * remains strictly excluded from the 001-010 approval, and      *
-- * that separate sign-off requires THREE things completed first, *
-- * not just 010 passing:                                         *
-- *   1. The complete authorization/RLS/RPC rewrite (listed below)*
-- *   2. A database dependency scan (views, functions, triggers,  *
-- *      or anything else in the live schema that reads           *
-- *      employee_id and isn't one of the RPCs already accounted  *
-- *      for here - not yet performed, needs a real query against *
-- *      pg_depend / information_schema before this file is ever  *
-- *      approved, not assumed clean from the migration files     *
-- *      alone)                                                   *
-- *   3. Application compatibility checks (a real grep across the *
-- *      Next.js frontend/API code for direct employee_id reads,  *
-- *      not assumed from the SQL side)                           *
-- ****************************************************************
--
-- This is IRREVERSIBLE in the ordinary sense - once employee_id is
-- dropped, reverting means re-deriving it from hr_employee_id via the
-- same chain in reverse (possible, since person_user_links still holds
-- the mapping, but not a simple rollback). Treat this file as a
-- one-way door.
--
-- SCOPE NOTE carried over from 009's header: 009a-d only dual-wrote
-- hr_employee_id: authorization (RLS policies, RPC checks) still runs
-- on employee_id/auth.uid() today. This file is where that actually
-- flips - dropping employee_id necessarily means every RLS policy and
-- RPC that currently reads it must be rewritten to use hr_employee_id
-- (resolved via auth.uid() -> person_user_links -> hr.employees)
-- FIRST, in the same sign-off cycle as this file, not after. Listed
-- below is what needs rewriting when that sign-off happens - not
-- written yet, since writing it now would mean guessing at a switch
-- the team lead hasn't approved:
--   - leave.submit_leave_request(): balance check, overlap check
--   - attendance.submit_correction_request(): find-or-create lookup
--   - assets RLS SELECT policies keyed on employee_id = auth.uid()
--   - contracts RLS SELECT policies keyed on employee_id = auth.uid()
--   - any frontend/API code reading *.employee_id directly instead of
--     *.hr_employee_id (needs a real grep across the Next.js app
--     before this runs, not assumed from the SQL side alone)
--
-- The DROP COLUMN statements below are correct and ready for whenever
-- that separate sign-off is given - they do NOT need to change; only
-- the authorization rewrite above needs to happen before they run.
-- ========================================================================

ALTER TABLE "leave"."leave_requests" DROP COLUMN "employee_id";
ALTER TABLE "leave"."leave_ledger" DROP COLUMN "employee_id";
ALTER TABLE "leave"."leave_accruals" DROP COLUMN "employee_id";
ALTER TABLE "leave"."leave_adjustments" DROP COLUMN "employee_id";
ALTER TABLE "attendance"."attendance_days" DROP COLUMN "employee_id";
ALTER TABLE "attendance"."correction_requests" DROP COLUMN "employee_id";
ALTER TABLE "assets"."asset_requests" DROP COLUMN "employee_id";
ALTER TABLE "assets"."asset_assignments" DROP COLUMN "employee_id";
ALTER TABLE "hr"."contracts" DROP COLUMN "employee_id";

-- Optional, only once the above is confirmed safe: rename
-- hr_employee_id -> employee_id on each table for a clean final name.
-- NOT included here - a rename is a separate, easily-reversible
-- decision that doesn't need to be bundled into the irreversible part
-- of this file. Revisit if wanted once the drops above are confirmed.

-- ========================================================================
-- END 011_drop_legacy_employee_id.sql (HELD)
-- ========================================================================
