-- ========================================================================
-- 009a_leave_rls_rpc_cutover.sql
-- Phase 7: Leave module dual-write cutover. See 009's header for the
-- scope decision (dual-write, not a full authorization switch).
--
-- Reproduces leave.submit_leave_request() and
-- leave._on_workflow_status_change() from
-- phase_3_leave_module/003_leave_submit_request.sql EXACTLY, with the
-- only functional addition marked "NEW:" in comments below. Same
-- signature (CREATE OR REPLACE, no DROP needed), so the existing
-- GRANT/REVOKE from phase 3 remain valid unchanged.
-- ========================================================================

CREATE OR REPLACE FUNCTION "leave"."submit_leave_request"(
    "p_leave_type_id" uuid,
    "p_start_date" date,
    "p_end_date" date,
    "p_total_days" numeric(6,2),
    "p_reason" text DEFAULT NULL,
    "p_idempotency_key" varchar(255) DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "leave", "workflow", "core", "auth"
AS $$
DECLARE
    v_employee_id uuid;
    v_hr_employee_id uuid;  -- NEW
    v_leave_type "leave"."leave_types";
    v_current_balance numeric(6,2);
    v_request_id uuid;
    v_workflow_definition_id uuid;
    v_start_result jsonb;
    v_idempotency_key varchar(255);
BEGIN
    v_employee_id := auth.uid();
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'LEAVE_UNAUTHENTICATED: submit_leave_request requires an authenticated session';
    END IF;

    -- NEW: resolve, but never block on it - see 009's header.
    v_hr_employee_id := "core"."resolve_hr_employee_id"(v_employee_id);

    IF p_end_date < p_start_date THEN
        RAISE EXCEPTION 'LEAVE_INVALID_DATE_RANGE: end_date must be on or after start_date';
    END IF;
    IF p_total_days <= 0 THEN
        RAISE EXCEPTION 'LEAVE_INVALID_TOTAL_DAYS: total_days must be greater than zero';
    END IF;

    SELECT * INTO v_leave_type FROM "leave"."leave_types" WHERE "id" = p_leave_type_id AND "status" = 'ACTIVE';
    IF v_leave_type IS NULL THEN
        RAISE EXCEPTION 'LEAVE_TYPE_NOT_FOUND: no active leave type with id %', p_leave_type_id;
    END IF;

    -- Balance check UNCHANGED - still keyed on employee_id (auth.uid()),
    -- not hr_employee_id. See 009's header for why authorization/
    -- business logic isn't switched yet.
    IF v_leave_type."max_days_per_year" IS NOT NULL THEN
        SELECT COALESCE(SUM("amount_days"), 0) INTO v_current_balance
        FROM "leave"."leave_ledger"
        WHERE "employee_id" = v_employee_id AND "leave_type_id" = p_leave_type_id;

        IF v_current_balance < p_total_days THEN
            RAISE EXCEPTION 'LEAVE_INSUFFICIENT_BALANCE: requested % days but only % available for %',
                p_total_days, v_current_balance, v_leave_type."leave_name";
        END IF;
    END IF;

    IF EXISTS (
        SELECT 1 FROM "leave"."leave_requests"
        WHERE "employee_id" = v_employee_id
          AND "request_status" IN ('SUBMITTED', 'APPROVED')
          AND "start_date" <= p_end_date AND "end_date" >= p_start_date
    ) THEN
        RAISE EXCEPTION 'LEAVE_OVERLAPPING_REQUEST: an existing submitted or approved request already covers part of this date range';
    END IF;

    -- NEW: hr_employee_id added to the INSERT, everything else identical.
    INSERT INTO "leave"."leave_requests" (
        "employee_id", "hr_employee_id", "leave_type_id", "start_date", "end_date", "total_days", "reason", "request_status"
    ) VALUES (
        v_employee_id, v_hr_employee_id, p_leave_type_id, p_start_date, p_end_date, p_total_days, p_reason, 'SUBMITTED'
    ) RETURNING "id" INTO v_request_id;

    SELECT "id" INTO v_workflow_definition_id
    FROM "workflow"."workflow_definitions"
    WHERE "module" = 'leave' AND "code" = 'LEAVE_REQUEST_APPROVAL';

    IF v_workflow_definition_id IS NULL THEN
        RAISE EXCEPTION 'LEAVE_WORKFLOW_NOT_CONFIGURED: no ACTIVE LEAVE_REQUEST_APPROVAL workflow_definition found - run supabase/migrations/P0/phase_2_leave_module/004_leave_workflow_definition_SEED.sql first (see that file''s header for why it cannot be a normal migration)';
    END IF;

    v_idempotency_key := COALESCE(p_idempotency_key, 'leave-request-' || v_request_id::text);

    v_start_result := "workflow"."start_approval_request"(
        v_workflow_definition_id,
        'leave_request',
        v_request_id,
        jsonb_build_object(
            'leave_type_id', p_leave_type_id,
            'start_date', p_start_date,
            'end_date', p_end_date,
            'total_days', p_total_days
        ),
        v_idempotency_key
    );

    UPDATE "leave"."leave_requests"
    SET "workflow_request_id" = (v_start_result->>'approval_request_id')::uuid,
        "submitted_at" = now()
    WHERE "id" = v_request_id;

    RETURN jsonb_build_object(
        'leave_request_id', v_request_id,
        'workflow_request_id', v_start_result->>'approval_request_id',
        'status', v_start_result->>'status'
    );
END;
$$;

CREATE OR REPLACE FUNCTION "leave"."_on_workflow_status_change"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "leave", "workflow"
AS $$
DECLARE
    v_leave_request "leave"."leave_requests";
BEGIN
    IF NEW."to_status" NOT IN ('APPROVED', 'REJECTED') THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_leave_request FROM "leave"."leave_requests" WHERE "workflow_request_id" = NEW."approval_request_id";
    IF v_leave_request IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW."to_status" = 'APPROVED' THEN
        UPDATE "leave"."leave_requests" SET "request_status" = 'APPROVED' WHERE "id" = v_leave_request."id";

        -- NEW: hr_employee_id carried over from the request row (already
        -- resolved at submit time above) rather than re-resolved here -
        -- avoids a second lookup and stays consistent with whatever was
        -- true at submission.
        INSERT INTO "leave"."leave_ledger" (
            "employee_id", "hr_employee_id", "leave_type_id", "movement_type", "amount_days",
            "effective_date", "source_request_id", "created_by"
        ) VALUES (
            v_leave_request."employee_id", v_leave_request."hr_employee_id", v_leave_request."leave_type_id", 'DEDUCTION',
            -1 * v_leave_request."total_days", v_leave_request."start_date", v_leave_request."id",
            v_leave_request."employee_id"
        );
    ELSIF NEW."to_status" = 'REJECTED' THEN
        UPDATE "leave"."leave_requests" SET "request_status" = 'REJECTED' WHERE "id" = v_leave_request."id";
    END IF;

    RETURN NEW;
END;
$$;

-- ========================================================================
-- END 009a_leave_rls_rpc_cutover.sql
-- ========================================================================
