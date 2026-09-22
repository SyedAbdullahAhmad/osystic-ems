-- ========================================================================
-- 009b_attendance_rls_rpc_cutover.sql
-- Phase 7: Attendance module dual-write cutover. See 009's header for
-- the scope decision (dual-write, not a full authorization switch).
--
-- Reproduces attendance.submit_correction_request() and
-- attendance._on_workflow_status_change() from
-- phase_4_attendance_module/003_attendance_submit_correction_request.sql
-- EXACTLY, only functional addition marked "NEW:" below. Same
-- signature, existing GRANT/REVOKE from phase 4 remain valid.
-- ========================================================================

CREATE OR REPLACE FUNCTION "attendance"."submit_correction_request"(
    "p_attendance_date" date,
    "p_requested_check_in" timestamptz DEFAULT NULL,
    "p_requested_check_out" timestamptz DEFAULT NULL,
    "p_reason" text DEFAULT NULL,
    "p_idempotency_key" varchar(255) DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "attendance", "workflow", "core", "auth"
AS $$
DECLARE
    v_employee_id uuid;
    v_hr_employee_id uuid;  -- NEW
    v_attendance_day_id uuid;
    v_request_id uuid;
    v_workflow_definition_id uuid;
    v_start_result jsonb;
    v_idempotency_key varchar(255);
BEGIN
    v_employee_id := auth.uid();
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_UNAUTHENTICATED: submit_correction_request requires an authenticated session';
    END IF;

    -- NEW: resolve, never blocks - see 009's header.
    v_hr_employee_id := "core"."resolve_hr_employee_id"(v_employee_id);

    IF p_attendance_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ATTENDANCE_INVALID_DATE: attendance_date cannot be in the future';
    END IF;
    IF p_requested_check_in IS NULL AND p_requested_check_out IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_MISSING_CORRECTION: at least one of requested_check_in / requested_check_out must be supplied';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ATTENDANCE_REASON_REQUIRED: a reason is required for a correction request';
    END IF;

    SELECT "id" INTO v_attendance_day_id
    FROM "attendance"."attendance_days"
    WHERE "employee_id" = v_employee_id AND "attendance_date" = p_attendance_date;

    IF v_attendance_day_id IS NULL THEN
        -- NEW: hr_employee_id added to the find-or-create INSERT too.
        INSERT INTO "attendance"."attendance_days" ("employee_id", "hr_employee_id", "attendance_date")
        VALUES (v_employee_id, v_hr_employee_id, p_attendance_date)
        RETURNING "id" INTO v_attendance_day_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM "attendance"."correction_requests"
        WHERE "attendance_day_id" = v_attendance_day_id AND "request_status" = 'SUBMITTED'
    ) THEN
        RAISE EXCEPTION 'ATTENDANCE_OPEN_REQUEST_EXISTS: an open correction request already exists for this day';
    END IF;

    -- NEW: hr_employee_id added to the INSERT.
    INSERT INTO "attendance"."correction_requests" (
        "attendance_day_id", "employee_id", "hr_employee_id", "requested_check_in", "requested_check_out", "reason", "request_status"
    ) VALUES (
        v_attendance_day_id, v_employee_id, v_hr_employee_id, p_requested_check_in, p_requested_check_out, p_reason, 'SUBMITTED'
    ) RETURNING "id" INTO v_request_id;

    SELECT "id" INTO v_workflow_definition_id
    FROM "workflow"."workflow_definitions"
    WHERE "module" = 'attendance' AND "code" = 'ATTENDANCE_CORRECTION_APPROVAL';

    IF v_workflow_definition_id IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_WORKFLOW_NOT_CONFIGURED: no ACTIVE ATTENDANCE_CORRECTION_APPROVAL workflow_definition found - run 004_attendance_correction_workflow_definition_SEED.sql first (see that file''s header for why it cannot be a normal migration)';
    END IF;

    v_idempotency_key := COALESCE(p_idempotency_key, 'attendance-correction-' || v_request_id::text);

    v_start_result := "workflow"."start_approval_request"(
        v_workflow_definition_id,
        'attendance_correction_request',
        v_request_id,
        jsonb_build_object(
            'attendance_day_id', v_attendance_day_id,
            'attendance_date', p_attendance_date,
            'requested_check_in', p_requested_check_in,
            'requested_check_out', p_requested_check_out
        ),
        v_idempotency_key
    );

    UPDATE "attendance"."correction_requests"
    SET "workflow_request_id" = (v_start_result->>'approval_request_id')::uuid,
        "submitted_at" = now()
    WHERE "id" = v_request_id;

    RETURN jsonb_build_object(
        'correction_request_id', v_request_id,
        'attendance_day_id', v_attendance_day_id,
        'workflow_request_id', v_start_result->>'approval_request_id',
        'status', v_start_result->>'status'
    );
END;
$$;

-- _on_workflow_status_change() unchanged - it never inserts a new row
-- referencing employee_id (only UPDATEs attendance_days by id), so
-- there is nothing for it to dual-write. Not reproduced here; the
-- version from phase 4 is left exactly as-is.

-- ========================================================================
-- END 009b_attendance_rls_rpc_cutover.sql
-- ========================================================================
