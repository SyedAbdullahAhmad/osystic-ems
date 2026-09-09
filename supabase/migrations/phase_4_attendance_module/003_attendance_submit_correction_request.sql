-- ========================================================================
-- 003_attendance_submit_correction_request.sql
-- Phase 4: Attendance Corrections Module - the integration point with the
-- centralized workflow engine. Mirrors 003_leave_submit_request.sql.
--
-- attendance.submit_correction_request() is the ONLY way a correction
-- request gets created and routed for approval. It:
--   1. Validates the date isn't in the future and at least one of
--      requested_check_in/requested_check_out is supplied.
--   2. Find-or-creates the attendance_days row for (employee, date) - see
--      001's header for why this is find-or-create rather than requiring
--      the row to pre-exist.
--   3. Guards against a second open (SUBMITTED) request for the same day.
--   4. Creates the correction_requests row.
--   5. Calls workflow.start_approval_request() - the integration point.
--   6. Stores the returned approval_request_id onto workflow_request_id.
--
-- Runs as SECURITY DEFINER so it can call the service_role-only
-- workflow.start_approval_request() internally, same as
-- leave.submit_leave_request().
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

    IF p_attendance_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ATTENDANCE_INVALID_DATE: attendance_date cannot be in the future';
    END IF;
    IF p_requested_check_in IS NULL AND p_requested_check_out IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_MISSING_CORRECTION: at least one of requested_check_in / requested_check_out must be supplied';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ATTENDANCE_REASON_REQUIRED: a reason is required for a correction request';
    END IF;

    -- Find-or-create the attendance_days row - see 001's header. A brand
    -- new row defaults to ABSENT/no times, which is exactly correct for
    -- the "I forgot to check in entirely" case.
    SELECT "id" INTO v_attendance_day_id
    FROM "attendance"."attendance_days"
    WHERE "employee_id" = v_employee_id AND "attendance_date" = p_attendance_date;

    IF v_attendance_day_id IS NULL THEN
        INSERT INTO "attendance"."attendance_days" ("employee_id", "attendance_date")
        VALUES (v_employee_id, p_attendance_date)
        RETURNING "id" INTO v_attendance_day_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM "attendance"."correction_requests"
        WHERE "attendance_day_id" = v_attendance_day_id AND "request_status" = 'SUBMITTED'
    ) THEN
        RAISE EXCEPTION 'ATTENDANCE_OPEN_REQUEST_EXISTS: an open correction request already exists for this day';
    END IF;

    INSERT INTO "attendance"."correction_requests" (
        "attendance_day_id", "employee_id", "requested_check_in", "requested_check_out", "reason", "request_status"
    ) VALUES (
        v_attendance_day_id, v_employee_id, p_requested_check_in, p_requested_check_out, p_reason, 'SUBMITTED'
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

REVOKE ALL ON FUNCTION "attendance"."submit_correction_request"(date, timestamptz, timestamptz, text, varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "attendance"."submit_correction_request"(date, timestamptz, timestamptz, text, varchar) TO "authenticated";

-- ------------------------------------------------------------------------
-- React to the workflow reaching a terminal state - mirrors
-- leave._on_workflow_status_change() exactly. On APPROVED, apply the
-- correction onto attendance_days in the SAME transaction as the terminal
-- status_history row, so either both commit or neither does.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "attendance"."_on_workflow_status_change"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "attendance", "workflow"
AS $$
DECLARE
    v_request "attendance"."correction_requests";
BEGIN
    IF NEW."to_status" NOT IN ('APPROVED', 'REJECTED') THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_request FROM "attendance"."correction_requests" WHERE "workflow_request_id" = NEW."approval_request_id";
    IF v_request IS NULL THEN
        RETURN NEW;  -- this status_history row belongs to a different module's request
    END IF;

    IF NEW."to_status" = 'APPROVED' THEN
        UPDATE "attendance"."correction_requests" SET "request_status" = 'APPROVED' WHERE "id" = v_request."id";

        UPDATE "attendance"."attendance_days"
        SET
            "first_check_in" = COALESCE(v_request."requested_check_in", "first_check_in"),
            "last_check_out" = COALESCE(v_request."requested_check_out", "last_check_out"),
            "worked_minutes" = CASE
                WHEN COALESCE(v_request."requested_check_in", "first_check_in") IS NOT NULL
                     AND COALESCE(v_request."requested_check_out", "last_check_out") IS NOT NULL
                THEN GREATEST(0, EXTRACT(EPOCH FROM (
                    COALESCE(v_request."requested_check_out", "last_check_out")
                    - COALESCE(v_request."requested_check_in", "first_check_in")
                )) / 60)::int
                ELSE "worked_minutes"
            END,
            "attendance_status" = 'PRESENT'
        WHERE "id" = v_request."attendance_day_id";
    ELSIF NEW."to_status" = 'REJECTED' THEN
        UPDATE "attendance"."correction_requests" SET "request_status" = 'REJECTED' WHERE "id" = v_request."id";
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_attendance_on_workflow_status_change" ON "workflow"."status_history";
CREATE TRIGGER "trg_attendance_on_workflow_status_change"
    AFTER INSERT ON "workflow"."status_history"
    FOR EACH ROW EXECUTE FUNCTION "attendance"."_on_workflow_status_change"();

-- ========================================================================
-- END 003_attendance_submit_correction_request.sql
-- ========================================================================
