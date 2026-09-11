-- Run as ONE complete paste in the Supabase SQL Editor.
-- Requires TEST_bootstrap_contracts_workflow.sql to have been run first.
--
-- Creates AND approves as the SAME account, LOCAL_TEST_ADMIN - this is
-- expected, not a mistake. Per team lead's confirmed decision, this
-- slice has no segregation-of-duties split (CONTRACT_MANAGE gates both
-- creation and approval), and 004 set is_maker_checker = false on the
-- approval step specifically because of that. Contract is created FOR
-- the same test employee account used across Leave/Attendance/Assets,
-- even though that employee never touches this flow themselves
-- (HR/Admin-initiated only, per design).

DO $$
DECLARE
    v_create_result jsonb;
    v_contract_id uuid;
    v_workflow_request_id uuid;
    v_step_id uuid;
    v_current_version int;
    v_approve_result jsonb;
BEGIN
    -- ---- Create + submit as LOCAL_TEST_ADMIN (HR/Admin-initiated) ----
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'role', 'authenticated')::text, true);

    v_create_result := "hr"."create_contract"(
        'ed761a27-783e-43d2-8fcd-ac2f64b29249'::uuid,  -- p_employee_id: the test employee, contract is FOR them
        'PERMANENT'::"hr"."contract_type",
        current_date,                                    -- p_effective_from
        NULL,                                             -- p_effective_to
        NULL,                                             -- p_document_file_id (optional, omitted for this test)
        'Test contract created via TEST_create_approve_contract.sql',
        NULL,                                              -- p_contract_number (auto-generated)
        'test-contract-create-' || now()::text
    );
    RAISE NOTICE 'Create result: %', v_create_result;

    v_contract_id := (v_create_result->>'contract_id')::uuid;
    v_workflow_request_id := (v_create_result->>'workflow_request_id')::uuid;

    -- ---- Approve, still as LOCAL_TEST_ADMIN (same session - no actor switch needed, see header) ----
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
        'test-contract-approve-' || v_contract_id::text, v_current_version
    );
    RAISE NOTICE 'Approve result: %', v_approve_result;
END;
$$;

-- Verify: status should be ACTIVE (direct flip, no separate manual step
-- - see 003's header), current_version_id should be set, and the
-- approval-history view should show the SUBMITTED->APPROVED transition
-- with LOCAL_TEST_ADMIN as the actor.
SELECT
    c."contract_number",
    c."contract_type",
    c."status",
    c."current_version_id",
    cv."effective_from",
    cv."version_no"
FROM "hr"."contracts" c
JOIN "hr"."contract_versions" cv ON cv."id" = c."current_version_id"
WHERE c."employee_id" = 'ed761a27-783e-43d2-8fcd-ac2f64b29249'
ORDER BY c."created_at" DESC
LIMIT 1;

SELECT * FROM "hr"."v_contract_approvals"
WHERE "employee_id" = 'ed761a27-783e-43d2-8fcd-ac2f64b29249'
ORDER BY "changed_at" DESC
LIMIT 5;
