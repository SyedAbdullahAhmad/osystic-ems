-- ========================================================================
-- 003_assets_submit_and_fulfill_request.sql
-- Phase 5: Assets Module - integration point with the workflow engine.
--
-- Two RPCs, matching the two real-world moments in this flow:
--   1. submit_asset_request() - employee asks for a category of asset.
--      Same shape as leave.submit_leave_request() /
--      attendance.submit_correction_request().
--   2. fulfill_asset_request() - AFTER approval, an ASSET_MANAGE holder
--      hands over a specific physical unit. Deliberately NOT automatic
--      on APPROVED (unlike leave's ledger deduction or attendance's day
--      update) - picking which physical unit to hand over is a real
--      logistics decision, not something to auto-resolve. The workflow
--      trigger below only flips request_status to APPROVED; it does not
--      create the assignment.
--
-- FIX (post-apply, found during Step 6 end-to-end testing): the original
-- version of _on_workflow_status_change() below did
--   SET "request_status" = NEW."to_status"
-- directly. NEW."to_status" is workflow.status_history's varchar column
-- value, not an untyped string literal - Postgres will not implicitly
-- cast a typed varchar into an enum column in an UPDATE SET, and this
-- failed with:
--   ERROR 42804: column "request_status" is of type asset_request_status
--   but expression is of type character varying
-- Leave/Attendance's equivalent triggers never hit this because they
-- branch per status and assign untyped literals ('APPROVED'/'REJECTED'),
-- which Postgres does auto-cast. Fixed here with an explicit cast
-- (NEW."to_status"::"assets"."asset_request_status") rather than
-- rewriting to match their branched form, since Assets' 1:1 mapping
-- (to_status always equals the new request_status) doesn't need
-- per-branch logic - verified working via TEST_submit_approve_fulfill_
-- asset_request.sql after this fix.
-- ========================================================================

CREATE OR REPLACE FUNCTION "assets"."submit_asset_request"(
    "p_asset_category_id" uuid,
    "p_justification" text,
    "p_idempotency_key" varchar(255) DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "assets", "workflow", "core", "auth"
AS $$
DECLARE
    v_employee_id uuid;
    v_request_id uuid;
    v_workflow_definition_id uuid;
    v_start_result jsonb;
    v_idempotency_key varchar(255);
BEGIN
    v_employee_id := auth.uid();
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'ASSETS_UNAUTHENTICATED: submit_asset_request requires an authenticated session';
    END IF;

    IF p_justification IS NULL OR btrim(p_justification) = '' THEN
        RAISE EXCEPTION 'ASSETS_JUSTIFICATION_REQUIRED: a justification is required for an asset request';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "assets"."asset_categories" WHERE "id" = p_asset_category_id) THEN
        RAISE EXCEPTION 'ASSETS_INVALID_CATEGORY: no such asset category';
    END IF;

    INSERT INTO "assets"."asset_requests" ("employee_id", "asset_category_id", "justification", "request_status")
    VALUES (v_employee_id, p_asset_category_id, p_justification, 'SUBMITTED')
    RETURNING "id" INTO v_request_id;

    SELECT "id" INTO v_workflow_definition_id
    FROM "workflow"."workflow_definitions"
    WHERE "module" = 'assets' AND "code" = 'ASSET_REQUEST_APPROVAL';

    IF v_workflow_definition_id IS NULL THEN
        RAISE EXCEPTION 'ASSETS_WORKFLOW_NOT_CONFIGURED: no ACTIVE ASSET_REQUEST_APPROVAL workflow_definition found - run 004''s seed function first';
    END IF;

    v_idempotency_key := COALESCE(p_idempotency_key, 'asset-request-' || v_request_id::text);

    v_start_result := "workflow"."start_approval_request"(
        v_workflow_definition_id,
        'asset_request',
        v_request_id,
        jsonb_build_object('asset_category_id', p_asset_category_id),
        v_idempotency_key
    );

    UPDATE "assets"."asset_requests"
    SET "workflow_request_id" = (v_start_result->>'approval_request_id')::uuid,
        "submitted_at" = now()
    WHERE "id" = v_request_id;

    RETURN jsonb_build_object(
        'asset_request_id', v_request_id,
        'workflow_request_id', v_start_result->>'approval_request_id',
        'status', v_start_result->>'status'
    );
END;
$$;

REVOKE ALL ON FUNCTION "assets"."submit_asset_request"(uuid, text, varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "assets"."submit_asset_request"(uuid, text, varchar) TO "authenticated";

-- ------------------------------------------------------------------------
-- React to the workflow reaching a terminal state - flips request_status
-- only. Fulfillment (assigning a real unit) is a deliberate separate step.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "assets"."_on_workflow_status_change"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "assets", "workflow"
AS $$
BEGIN
    IF NEW."to_status" NOT IN ('APPROVED', 'REJECTED') THEN
        RETURN NEW;
    END IF;

    UPDATE "assets"."asset_requests"
    SET "request_status" = NEW."to_status"::"assets"."asset_request_status"
    WHERE "workflow_request_id" = NEW."approval_request_id"
      AND "request_status" = 'SUBMITTED';  -- guard: don't stomp FULFILLED/CANCELLED

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_assets_on_workflow_status_change" ON "workflow"."status_history";
CREATE TRIGGER "trg_assets_on_workflow_status_change"
    AFTER INSERT ON "workflow"."status_history"
    FOR EACH ROW EXECUTE FUNCTION "assets"."_on_workflow_status_change"();

-- ------------------------------------------------------------------------
-- fulfill_asset_request() - the physical handover. Callable only by an
-- ASSET_MANAGE holder, only on an APPROVED request, only with an
-- AVAILABLE asset of the matching category. Flips both the request and
-- the chosen asset's status atomically.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "assets"."fulfill_asset_request"(
    "p_asset_request_id" uuid,
    "p_asset_id" uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "assets", "core", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_request "assets"."asset_requests";
    v_asset "assets"."assets";
    v_assignment_id uuid;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'ASSETS_UNAUTHENTICATED: fulfill_asset_request requires an authenticated session';
    END IF;
    IF NOT core.has_permission(v_actor, 'ASSET_MANAGE') THEN
        RAISE EXCEPTION 'ASSETS_NOT_AUTHORIZED: ASSET_MANAGE required to fulfill an asset request';
    END IF;

    SELECT * INTO v_request FROM "assets"."asset_requests" WHERE "id" = p_asset_request_id FOR UPDATE;
    IF v_request IS NULL THEN
        RAISE EXCEPTION 'ASSETS_REQUEST_NOT_FOUND: no such asset request';
    END IF;
    IF v_request."request_status" != 'APPROVED' THEN
        RAISE EXCEPTION 'ASSETS_REQUEST_NOT_APPROVED: request must be APPROVED before it can be fulfilled (currently %)', v_request."request_status";
    END IF;

    SELECT * INTO v_asset FROM "assets"."assets" WHERE "id" = p_asset_id FOR UPDATE;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'ASSETS_ASSET_NOT_FOUND: no such asset';
    END IF;
    IF v_asset."current_status" != 'AVAILABLE' THEN
        RAISE EXCEPTION 'ASSETS_ASSET_NOT_AVAILABLE: asset is not AVAILABLE (currently %)', v_asset."current_status";
    END IF;
    IF v_asset."asset_category_id" != v_request."asset_category_id" THEN
        RAISE EXCEPTION 'ASSETS_CATEGORY_MISMATCH: asset does not belong to the requested category';
    END IF;

    INSERT INTO "assets"."asset_assignments" ("asset_request_id", "asset_id", "employee_id", "assigned_by")
    VALUES (p_asset_request_id, p_asset_id, v_request."employee_id", v_actor)
    RETURNING "id" INTO v_assignment_id;

    UPDATE "assets"."assets" SET "current_status" = 'ASSIGNED' WHERE "id" = p_asset_id;
    UPDATE "assets"."asset_requests" SET "request_status" = 'FULFILLED' WHERE "id" = p_asset_request_id;

    RETURN jsonb_build_object('assignment_id', v_assignment_id, 'asset_id', p_asset_id, 'status', 'FULFILLED');
END;
$$;

REVOKE ALL ON FUNCTION "assets"."fulfill_asset_request"(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "assets"."fulfill_asset_request"(uuid, uuid) TO "authenticated";

-- ========================================================================
-- END 003_assets_submit_and_fulfill_request.sql
-- ========================================================================