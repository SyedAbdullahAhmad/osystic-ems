-- ========================================================================
-- 009c_assets_rls_rpc_cutover.sql
-- Phase 7: Assets module dual-write cutover. See 009's header for the
-- scope decision (dual-write, not a full authorization switch).
--
-- Reproduces assets.submit_asset_request() and
-- assets.fulfill_asset_request() from
-- phase_5_assets_module/003_assets_submit_and_fulfill_request.sql
-- EXACTLY, only functional addition marked "NEW:" below. Same
-- signatures, existing GRANT/REVOKE from phase 5 remain valid.
--
-- assets._on_workflow_status_change() unchanged - it only UPDATEs
-- asset_requests.request_status by workflow_request_id, never inserts a
-- new row, so there's nothing to dual-write there. Not reproduced here.
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
    v_hr_employee_id uuid;  -- NEW
    v_request_id uuid;
    v_workflow_definition_id uuid;
    v_start_result jsonb;
    v_idempotency_key varchar(255);
BEGIN
    v_employee_id := auth.uid();
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'ASSETS_UNAUTHENTICATED: submit_asset_request requires an authenticated session';
    END IF;

    -- NEW: resolve, never blocks - see 009's header.
    v_hr_employee_id := "core"."resolve_hr_employee_id"(v_employee_id);

    IF p_justification IS NULL OR btrim(p_justification) = '' THEN
        RAISE EXCEPTION 'ASSETS_JUSTIFICATION_REQUIRED: a justification is required for an asset request';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "assets"."asset_categories" WHERE "id" = p_asset_category_id) THEN
        RAISE EXCEPTION 'ASSETS_INVALID_CATEGORY: no such asset category';
    END IF;

    -- NEW: hr_employee_id added to the INSERT.
    INSERT INTO "assets"."asset_requests" ("employee_id", "hr_employee_id", "asset_category_id", "justification", "request_status")
    VALUES (v_employee_id, v_hr_employee_id, p_asset_category_id, p_justification, 'SUBMITTED')
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

    -- NEW: hr_employee_id carried over from the REQUEST row
    -- (v_request."hr_employee_id", resolved at submit time above), not
    -- re-resolved from the actor - the assignment belongs to the
    -- requesting employee, never to whoever fulfills it (v_actor is a
    -- different person - the ASSET_MANAGE holder handing the item
    -- over). Same "identify the employee this row is actually about,
    -- not the acting user" principle applies here as everywhere else.
    INSERT INTO "assets"."asset_assignments" ("asset_request_id", "asset_id", "employee_id", "hr_employee_id", "assigned_by")
    VALUES (p_asset_request_id, p_asset_id, v_request."employee_id", v_request."hr_employee_id", v_actor)
    RETURNING "id" INTO v_assignment_id;

    UPDATE "assets"."assets" SET "current_status" = 'ASSIGNED' WHERE "id" = p_asset_id;
    UPDATE "assets"."asset_requests" SET "request_status" = 'FULFILLED' WHERE "id" = p_asset_request_id;

    RETURN jsonb_build_object('assignment_id', v_assignment_id, 'asset_id', p_asset_id, 'status', 'FULFILLED');
END;
$$;

-- ========================================================================
-- END 009c_assets_rls_rpc_cutover.sql
-- ========================================================================
