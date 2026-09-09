-- Run as ONE complete paste in the Supabase SQL Editor.
-- Requires TEST_bootstrap_attendance_workflow.sql to have been run first
-- (ATTENDANCE_CORRECTION_APPROVAL must be ACTIVE with an assignee).
--
-- Submits as the same real test employee account used for the leave
-- verification (ed761a27-783e-43d2-8fcd-ac2f64b29249), then approves as
-- the test-admin fixture account assigned to manager_approval.

DO $$
DECLARE
    v_target_date date := CURRENT_DATE - 1;
    v_submit_result jsonb;
    v_correction_request_id uuid;
    v_workflow_request_id uuid;
    v_step_id uuid;
    v_current_version int;
    v_approve_result jsonb;
    v_final_status text;
BEGIN
    -- ---- Submit as the employee ----
    PERFORM set_config('request.jwt.claims', json_build_object('sub', 'ed761a27-783e-43d2-8fcd-ac2f64b29249', 'role', 'authenticated')::text, true);

    v_submit_result := "attendance"."submit_correction_request"(
        v_target_date,
        (v_target_date::text || ' 09:15:00')::timestamptz,
        (v_target_date::text || ' 18:00:00')::timestamptz,
        'Forgot to check in on time due to a client meeting off-site.',
        'test-attendance-correction-' || v_target_date::text
    );
    RAISE NOTICE 'Submit result: %', v_submit_result;

    v_correction_request_id := (v_submit_result->>'correction_request_id')::uuid;
    v_workflow_request_id := (v_submit_result->>'workflow_request_id')::uuid;

    -- ---- Approve as test-admin (the assigned manager_approval approver) ----
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000a6', 'role', 'authenticated')::text, true);

    SELECT s."id" INTO v_step_id
    FROM "workflow"."approval_steps" s
    WHERE s."approval_request_id" = v_workflow_request_id
      AND s."status" IN ('PENDING', 'IN_PROGRESS')
    ORDER BY s."step_no"
    LIMIT 1;

    IF v_step_id IS NULL THEN
        RAISE EXCEPTION 'No open step found for workflow_request %', v_workflow_request_id;
    END IF;

    SELECT "version" INTO v_current_version FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;

    v_approve_result := "workflow"."process_approval_action"(
        v_workflow_request_id, 'APPROVE', v_step_id, 'approved (test)', NULL,
        'test-attendance-approve-' || v_correction_request_id::text, v_current_version
    );
    RAISE NOTICE 'Approve result: %', v_approve_result;

    SELECT "current_status" INTO v_final_status FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;
    RAISE NOTICE 'Final workflow status: %', v_final_status;
END;
$$;

-- Verify: request_status should be APPROVED, and attendance_days should
-- show the corrected times with attendance_status PRESENT.
SELECT
    cr."request_status",
    cr."requested_check_in",
    cr."requested_check_out",
    ad."attendance_date",
    ad."first_check_in",
    ad."last_check_out",
    ad."worked_minutes",
    ad."attendance_status"
FROM "attendance"."correction_requests" cr
JOIN "attendance"."attendance_days" ad ON ad."id" = cr."attendance_day_id"
WHERE cr."employee_id" = 'ed761a27-783e-43d2-8fcd-ac2f64b29249'
ORDER BY cr."created_at" DESC
LIMIT 1;
