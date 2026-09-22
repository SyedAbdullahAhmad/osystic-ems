-- Corrected re-run of TEST_submit_approve_fulfill_asset_request.sql,
-- pointed at LAP-0002 instead of LAP-0001 (LAP-0001 is permanently
-- ASSIGNED from the module's original verification run - no
-- return/unassign flow exists to free it up again). Otherwise
-- identical logic/actors to the original test script.

DO $$
DECLARE
    v_category_id uuid;
    v_asset_id uuid;
    v_submit_result jsonb;
    v_request_id uuid;
    v_workflow_request_id uuid;
    v_step_id uuid;
    v_current_version int;
    v_approve_result jsonb;
    v_fulfill_result jsonb;
BEGIN
    SELECT "id" INTO v_category_id FROM "assets"."asset_categories" WHERE "category_code" = 'LAPTOP';
    SELECT "id" INTO v_asset_id FROM "assets"."assets" WHERE "asset_code" = 'LAP-0002';

    IF v_asset_id IS NULL THEN
        RAISE EXCEPTION 'LAP-0002 not found - check assets.assets';
    END IF;

    -- ---- Submit as the employee ----
    PERFORM set_config('request.jwt.claims', json_build_object('sub', 'ed761a27-783e-43d2-8fcd-ac2f64b29249', 'role', 'authenticated')::text, true);

    v_submit_result := "assets"."submit_asset_request"(
        v_category_id,
        'Shared-core cutover regression test - safe to ignore.',
        'test-asset-cutover-regression-' || now()::text
    );
    RAISE NOTICE 'Submit result: %', v_submit_result;

    v_request_id := (v_submit_result->>'asset_request_id')::uuid;
    v_workflow_request_id := (v_submit_result->>'workflow_request_id')::uuid;

    -- ---- Approve as LOCAL_TEST_ADMIN (resolved via ASSET_MANAGE permission) ----
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'role', 'authenticated')::text, true);

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
        'test-asset-cutover-approve-' || v_request_id::text, v_current_version
    );
    RAISE NOTICE 'Approve result: %', v_approve_result;

    -- ---- Fulfill as LOCAL_TEST_ADMIN (still authenticated as it) ----
    v_fulfill_result := "assets"."fulfill_asset_request"(v_request_id, v_asset_id);
    RAISE NOTICE 'Fulfill result: %', v_fulfill_result;
END;
$$;

-- Verify: request_status FULFILLED, LAP-0002 now ASSIGNED, and the new
-- assignment row's hr_employee_id populated (proves 009c's dual-write,
-- carried over from the request row, works for new activity).
SELECT
    ar."request_status",
    a."asset_code",
    a."current_status" AS "asset_status",
    aa."employee_id",
    aa."hr_employee_id" AS "assignment_hr_employee_id",
    aa."assigned_at"
FROM "assets"."asset_requests" ar
JOIN "assets"."asset_assignments" aa ON aa."asset_request_id" = ar."id"
JOIN "assets"."assets" a ON a."id" = aa."asset_id"
WHERE ar."employee_id" = 'ed761a27-783e-43d2-8fcd-ac2f64b29249'
ORDER BY ar."created_at" DESC
LIMIT 1;
