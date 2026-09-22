-- ========================================================================
-- 010_full_validation.sql
-- Phase 7: Full validation after 009a-d. READ-ONLY. Same evidence
-- standard as every prior module's own apply checklist - real query
-- output, not "should work." Confirms the dual-write cutover is
-- working going forward, without touching the legacy employee_id path
-- (still untouched, still authoritative, still what every RLS policy
-- and RPC authorization check actually relies on today).
-- ========================================================================

-- Check 1 - going forward, hr_employee_id populates itself on new
-- activity. Run this BEFORE and AFTER manually exercising each RPC
-- (submit_leave_request, submit_correction_request,
-- submit_asset_request + fulfill_asset_request, create_contract) as a
-- backfilled test account, and confirm the "after" counts increase and
-- every new row has hr_employee_id populated (not NULL), while
-- employee_id is completely unaffected before/after.
SELECT 'leave_requests' AS "table", count(*) AS "total", count("hr_employee_id") AS "with_hr_employee_id" FROM "leave"."leave_requests"
UNION ALL SELECT 'leave_ledger (pre-cutover rows permanently NULL - see 008a)', count(*), count("hr_employee_id") FROM "leave"."leave_ledger"
UNION ALL SELECT 'attendance_days', count(*), count("hr_employee_id") FROM "attendance"."attendance_days"
UNION ALL SELECT 'correction_requests', count(*), count("hr_employee_id") FROM "attendance"."correction_requests"
UNION ALL SELECT 'asset_requests', count(*), count("hr_employee_id") FROM "assets"."asset_requests"
UNION ALL SELECT 'asset_assignments', count(*), count("hr_employee_id") FROM "assets"."asset_assignments"
UNION ALL SELECT 'contracts', count(*), count("hr_employee_id") FROM "hr"."contracts";
-- for rows created by an account WITHOUT an hr.employees record yet,
-- total > with_hr_employee_id is EXPECTED (resolves to NULL, does not
-- block) - only flag this if a row from a KNOWN-backfilled test account
-- (e.g. ed761a27-...) shows NULL, since that would mean the resolution
-- itself is broken, not just "this account has no employee record yet."
-- ADDITIONALLY for leave_ledger specifically: every PRE-CUTOVER row is
-- PERMANENTLY NULL by design (leave_ledger is append-only, discovered
-- on first live run - see 008a's header) - total > with_hr_employee_id
-- for leave_ledger is a permanent, expected state for old rows, not
-- something that ever resolves to equal. Only NEW leave_ledger rows
-- (inserted by 009a after this migration) should show hr_employee_id
-- populated.

-- Check 2 - re-run each module's existing end-to-end proof case exactly
-- as it was originally verified, confirm it still passes UNCHANGED:
--   - Leave: the real leave request used in TEST_leave_full_flow.sql
--     (or equivalent) - submit, approve, ledger deduction - all still
--     resolve correctly.
--   - Attendance: TEST_attendance_full_flow.sql equivalent - submit,
--     approve, attendance_days updated correctly.
--   - Assets: TEST_submit_approve_fulfill_asset_request.sql - submit,
--     approve, fulfill - all three steps still succeed.
--   - Contracts: create -> approve -> ACTIVE flow still succeeds.
-- These are behavioral re-runs, not a query to paste here - run each
-- module's actual existing test script again and confirm identical
-- results to when it was first verified. This IS the real regression
-- check for this batch - the dual-write logic doesn't touch any
-- existing behavior, so if any of these four break, the break is in
-- the 009x file's structure (a typo, a wrong column list), not in the
-- underlying business logic, which was left untouched.

-- Check 3 - RLS still correctly rejects an ineligible actor. Re-run the
-- same "ineligible actor gets rejected" check already used for
-- Leave/Attendance (attempt a call as a session with no relevant
-- permission, confirm it's rejected) - unaffected by this batch since
-- no RLS policy or permission check was modified, but confirming
-- nothing regressed regardless.

-- Check 4 - the provisioning RPC (003) still behaves correctly for a
-- fresh signup, tested independently of the 9-table cutover:
--   1. A brand-new auth.users session (never seen before) calls
--      core.provision_person_for_user() - expect action_taken =
--      'CREATED_NEW_PERSON', a new core.people row, a new ACTIVE
--      person_user_links row.
--   2. That same session calls it again - expect action_taken =
--      'ALREADY_LINKED', same person_id returned, no duplicate rows.
--   3. An HR/PEOPLE_MANAGE holder manually REVOKEs that link
--      (UPDATE core.person_user_links SET status = 'REVOKED' WHERE
--      person_id = ... - simulating an offboarding), then the SAME
--      auth.users session calls provision_person_for_user() again -
--      expect action_taken = 'REACTIVATED_SAME_LOGIN', the SAME
--      person_id as step 1, link status back to ACTIVE.
SELECT "person_id", "user_id", "status", "linked_at" FROM "core"."person_user_links"
ORDER BY "linked_at" DESC LIMIT 10;
-- eyeball this after running the three-step sequence above - confirm
-- no duplicate ACTIVE rows, no unexpected person_id created in step 2/3.

-- ========================================================================
-- END 010_full_validation.sql
-- ========================================================================
