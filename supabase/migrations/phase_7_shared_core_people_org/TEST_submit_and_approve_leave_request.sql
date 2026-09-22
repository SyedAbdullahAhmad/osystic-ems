-- Run as ONE complete paste in the Supabase SQL Editor.
-- Regression re-test for Leave, post-shared-core-cutover (009a). Not
-- part of the original phase_3_leave_module deliverables - written now
-- because no TEST_*.sql was checked in for Leave originally (it was
-- verified live through the UI the first time). Mirrors the exact
-- pattern of TEST_submit_and_approve_attendance_correction.sql.
--
-- Verified against the LIVE workflow config before writing this (not
-- assumed from the stale DRAFT-state seed file comments):
-- LEAVE_REQUEST_APPROVAL v1 is ACTIVE, two sequential steps
-- (manager_approval -> hr_signoff), BOTH assigned to the same
-- test-admin fixture user (00000000-0000-0000-0000-0000000000a6) -
-- same actor already used as the approver in the Attendance test.
--
-- Uses leave_code = 'UNPAID' specifically: its max_days_per_year is
-- NULL, so submit_leave_request() skips the balance check entirely -
-- this test doesn't need to know the test employee's current ANNUAL/
-- SICK/CASUAL balance to be guaranteed to pass that check. Dates are
-- far enough in the future (CURRENT_DATE + 30/+31) to not overlap any
-- existing test request for this employee.

DO $$
DECLARE
    v_leave_type_id uuid;
    v_start_date date := CURRENT_DATE + 30;
    v_end_date date := CURRENT_DATE + 31;
    v_submit_result jsonb;
    v_leave_request_id uuid;
    v_workflow_request_id uuid;
    v_step_id uuid;
    v_current_version int;
    v_approve_result jsonb;
    v_final_status text;
BEGIN
    SELECT "id" INTO v_leave_type_id FROM "leave"."leave_types" WHERE "leave_code" = 'UNPAID' AND "status" = 'ACTIVE';
    IF v_leave_type_id IS NULL THEN
        RAISE EXCEPTION 'UNPAID leave type not found - check leave.leave_types';
    END IF;

    -- ---- Submit as the employee ----
    PERFORM set_config('request.jwt.claims', json_build_object('sub', 'ed761a27-783e-43d2-8fcd-ac2f64b29249', 'role', 'authenticated')::text, true);

    v_submit_result := "leave"."submit_leave_request"(
        v_leave_type_id, v_start_date, v_end_date, 2,
        'Shared-core cutover regression test - safe to reject/ignore.',
        'test-leave-cutover-regression-' || v_start_date::text
    );
    RAISE NOTICE 'Submit result: %', v_submit_result;

    v_leave_request_id := (v_submit_result->>'leave_request_id')::uuid;
    v_workflow_request_id := (v_submit_result->>'workflow_request_id')::uuid;

    -- ---- Approve step 1 (manager_approval) as the fixture approver ----
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000a6', 'role', 'authenticated')::text, true);

    SELECT s."id" INTO v_step_id
    FROM "workflow"."approval_steps" s
    WHERE s."approval_request_id" = v_workflow_request_id
      AND s."status" IN ('PENDING', 'IN_PROGRESS')
    ORDER BY s."step_no"
    LIMIT 1;
    IF v_step_id IS NULL THEN
        RAISE EXCEPTION 'No open step found (step 1) for workflow_request %', v_workflow_request_id;
    END IF;

    SELECT "version" INTO v_current_version FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;

    v_approve_result := "workflow"."process_approval_action"(
        v_workflow_request_id, 'APPROVE', v_step_id, 'manager approved (test)', NULL,
        'test-leave-approve-step1-' || v_leave_request_id::text, v_current_version
    );
    RAISE NOTICE 'Step 1 (manager_approval) result: %', v_approve_result;

    -- ---- Approve step 2 (hr_signoff) as the same fixture approver ----
    SELECT s."id" INTO v_step_id
    FROM "workflow"."approval_steps" s
    WHERE s."approval_request_id" = v_workflow_request_id
      AND s."status" IN ('PENDING', 'IN_PROGRESS')
    ORDER BY s."step_no"
    LIMIT 1;
    IF v_step_id IS NULL THEN
        RAISE EXCEPTION 'No open step found (step 2) for workflow_request % - check whether step 1 actually advanced the workflow', v_workflow_request_id;
    END IF;

    SELECT "version" INTO v_current_version FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;

    v_approve_result := "workflow"."process_approval_action"(
        v_workflow_request_id, 'APPROVE', v_step_id, 'hr signed off (test)', NULL,
        'test-leave-approve-step2-' || v_leave_request_id::text, v_current_version
    );
    RAISE NOTICE 'Step 2 (hr_signoff) result: %', v_approve_result;

    SELECT "current_status" INTO v_final_status FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;
    RAISE NOTICE 'Final workflow status: %', v_final_status;
END;
$$;

-- Verify: request_status should be APPROVED, and a new DEDUCTION row
-- should exist in leave_ledger for -2 days on UNPAID, WITH
-- hr_employee_id populated this time (proves 009a's dual-write is
-- actually working for new activity, not just old backfilled rows).
SELECT
    lr."request_status", lr."start_date", lr."end_date", lr."total_days",
    lr."hr_employee_id" AS "request_hr_employee_id"
FROM "leave"."leave_requests" lr
WHERE lr."employee_id" = 'ed761a27-783e-43d2-8fcd-ac2f64b29249'
ORDER BY lr."created_at" DESC
LIMIT 1;

SELECT
    ll."movement_type", ll."amount_days", ll."effective_date",
    ll."hr_employee_id" AS "ledger_hr_employee_id"
FROM "leave"."leave_ledger" ll
WHERE ll."employee_id" = 'ed761a27-783e-43d2-8fcd-ac2f64b29249'
ORDER BY ll."created_at" DESC
LIMIT 1;
