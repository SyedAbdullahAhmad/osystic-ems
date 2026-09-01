-- ========================================================================
-- 003_leave_submit_request.sql
-- Phase 2: Leave Module - the actual integration point with the
-- centralized workflow engine.
--
-- leave.submit_leave_request() is the ONLY way a leave request gets
-- created and routed for approval. It:
--   1. Validates the leave type, dates, and that total_days doesn't
--      exceed the employee's current derived balance (when the leave
--      type is paid and has a max_days_per_year cap).
--   2. Creates the leave.leave_requests row.
--   3. Calls workflow.start_approval_request() to create the linked
--      workflow.approval_requests row - THIS is the integration point.
--   4. Stores the returned approval_request_id back onto
--      workflow_request_id, and sets request_status to SUBMITTED.
--
-- Runs as SECURITY DEFINER so it can call the service_role-only
-- workflow.start_approval_request() internally, the same way a module's
-- own RPC is expected to per the architecture (module RPCs, not bare
-- client calls, are what's allowed to reach the workflow engine's
-- internal functions).
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

    -- Balance check - only meaningful for leave types with a cap. An
    -- uncapped type (max_days_per_year IS NULL) skips this by design.
    IF v_leave_type."max_days_per_year" IS NOT NULL THEN
        SELECT COALESCE(SUM("amount_days"), 0) INTO v_current_balance
        FROM "leave"."leave_ledger"
        WHERE "employee_id" = v_employee_id AND "leave_type_id" = p_leave_type_id;

        IF v_current_balance < p_total_days THEN
            RAISE EXCEPTION 'LEAVE_INSUFFICIENT_BALANCE: requested % days but only % available for %',
                p_total_days, v_current_balance, v_leave_type."leave_name";
        END IF;
    END IF;

    -- Overlap guard - an employee cannot have two SUBMITTED/APPROVED
    -- requests covering the same dates for any leave type.
    IF EXISTS (
        SELECT 1 FROM "leave"."leave_requests"
        WHERE "employee_id" = v_employee_id
          AND "request_status" IN ('SUBMITTED', 'APPROVED')
          AND "start_date" <= p_end_date AND "end_date" >= p_start_date
    ) THEN
        RAISE EXCEPTION 'LEAVE_OVERLAPPING_REQUEST: an existing submitted or approved request already covers part of this date range';
    END IF;

    INSERT INTO "leave"."leave_requests" (
        "employee_id", "leave_type_id", "start_date", "end_date", "total_days", "reason", "request_status"
    ) VALUES (
        v_employee_id, p_leave_type_id, p_start_date, p_end_date, p_total_days, p_reason, 'SUBMITTED'
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

REVOKE ALL ON FUNCTION "leave"."submit_leave_request"(uuid, date, date, numeric, text, varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "leave"."submit_leave_request"(uuid, date, date, numeric, text, varchar) TO "authenticated";

-- ------------------------------------------------------------------------
-- React to the workflow reaching a terminal state - when the linked
-- approval_request becomes APPROVED or REJECTED, mirror that onto
-- leave_requests.request_status and, on approval, write the DEDUCTION
-- ledger row. This is the "leave module owns... final leave-ledger
-- effects" half of the ownership split.
--
-- Implemented as a trigger on workflow.status_history rather than
-- polling, so leave's own state and the ledger update happen in the
-- same transaction as the terminal status_history row - either both
-- commit or neither does.
-- ------------------------------------------------------------------------
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
        RETURN NEW;  -- this status_history row belongs to a different module's request
    END IF;

    IF NEW."to_status" = 'APPROVED' THEN
        UPDATE "leave"."leave_requests" SET "request_status" = 'APPROVED' WHERE "id" = v_leave_request."id";

        INSERT INTO "leave"."leave_ledger" (
            "employee_id", "leave_type_id", "movement_type", "amount_days",
            "effective_date", "source_request_id", "created_by"
        ) VALUES (
            v_leave_request."employee_id", v_leave_request."leave_type_id", 'DEDUCTION',
            -1 * v_leave_request."total_days", v_leave_request."start_date", v_leave_request."id",
            v_leave_request."employee_id"
        );
    ELSIF NEW."to_status" = 'REJECTED' THEN
        UPDATE "leave"."leave_requests" SET "request_status" = 'REJECTED' WHERE "id" = v_leave_request."id";
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_leave_on_workflow_status_change" ON "workflow"."status_history";
CREATE TRIGGER "trg_leave_on_workflow_status_change"
    AFTER INSERT ON "workflow"."status_history"
    FOR EACH ROW EXECUTE FUNCTION "leave"."_on_workflow_status_change"();

-- ========================================================================
-- END 003_leave_submit_request.sql
-- ========================================================================
