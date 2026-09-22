-- ========================================================================
-- 009d_contracts_rls_rpc_cutover.sql
-- Phase 7: Contracts module dual-write cutover. See 009's header for
-- the scope decision (dual-write, not a full authorization switch).
--
-- Reproduces hr.create_contract() from
-- phase_6_contracts_module/003_contracts_create_and_submit_request.sql
-- EXACTLY, only functional addition marked "NEW:" below. Same
-- signature, existing GRANT/REVOKE from phase 6 remain valid.
--
-- IMPORTANT ASYMMETRY vs. the other three modules: create_contract is
-- HR-initiated, not self-service - the employee the contract is FOR is
-- p_employee_id (a parameter), not auth.uid() (that's v_actor, a
-- different person - the CONTRACT_MANAGE holder creating it). The
-- resolution below is keyed on p_employee_id accordingly, matching how
-- hr.contracts.employee_id itself is already populated from
-- p_employee_id, not v_actor.
--
-- hr._on_contract_workflow_status_change() unchanged - it only UPDATEs
-- hr.contracts.status by contract_id, never inserts a new row, so
-- there's nothing to dual-write there. Not reproduced here.
-- ========================================================================

CREATE OR REPLACE FUNCTION "hr"."create_contract"(
    "p_employee_id" uuid,
    "p_contract_type" "hr"."contract_type",
    "p_effective_from" date,
    "p_effective_to" date DEFAULT NULL,
    "p_document_file_id" uuid DEFAULT NULL,
    "p_notes" text DEFAULT NULL,
    "p_contract_number" varchar(100) DEFAULT NULL,
    "p_idempotency_key" varchar(255) DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "hr", "workflow", "core", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_hr_employee_id uuid;  -- NEW
    v_contract_number varchar(100);
    v_contract_id uuid;
    v_version_id uuid;
    v_request_id uuid;
    v_workflow_definition_id uuid;
    v_start_result jsonb;
    v_idempotency_key varchar(255);
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'CONTRACTS_UNAUTHENTICATED: create_contract requires an authenticated session';
    END IF;

    IF NOT core.has_permission(v_actor, 'CONTRACT_MANAGE') THEN
        RAISE EXCEPTION 'CONTRACTS_NOT_AUTHORIZED: CONTRACT_MANAGE required to create a contract';
    END IF;

    IF p_effective_from IS NULL THEN
        RAISE EXCEPTION 'CONTRACTS_EFFECTIVE_FROM_REQUIRED: an effective_from date is required';
    END IF;
    IF p_effective_to IS NOT NULL AND p_effective_to < p_effective_from THEN
        RAISE EXCEPTION 'CONTRACTS_INVALID_DATE_RANGE: effective_to cannot be before effective_from';
    END IF;

    -- NEW: resolved from p_employee_id (the contract's subject), NOT
    -- v_actor (the HR/Admin creator) - see header asymmetry note.
    -- Never blocks - see 009's header.
    v_hr_employee_id := "core"."resolve_hr_employee_id"(p_employee_id);

    v_contract_number := COALESCE(
        p_contract_number,
        'CN-' || to_char(now(), 'YYYYMMDD') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)
    );

    -- NEW: hr_employee_id added to the INSERT.
    INSERT INTO "hr"."contracts" ("employee_id", "hr_employee_id", "contract_number", "contract_type", "status")
    VALUES (p_employee_id, v_hr_employee_id, v_contract_number, p_contract_type, 'PENDING_APPROVAL')
    RETURNING "id" INTO v_contract_id;

    INSERT INTO "hr"."contract_versions" ("contract_id", "version_no", "effective_from", "effective_to", "document_file_id", "notes")
    VALUES (v_contract_id, 1, p_effective_from, p_effective_to, p_document_file_id, p_notes)
    RETURNING "id" INTO v_version_id;

    UPDATE "hr"."contracts" SET "current_version_id" = v_version_id WHERE "id" = v_contract_id;

    INSERT INTO "hr"."contract_requests" ("contract_id", "contract_version_id", "requested_by", "submitted_at")
    VALUES (v_contract_id, v_version_id, v_actor, now())
    RETURNING "id" INTO v_request_id;

    SELECT "id" INTO v_workflow_definition_id
    FROM "workflow"."workflow_definitions"
    WHERE "module" = 'contracts' AND "code" = 'CONTRACT_APPROVAL';

    IF v_workflow_definition_id IS NULL THEN
        RAISE EXCEPTION 'CONTRACTS_WORKFLOW_NOT_CONFIGURED: no ACTIVE CONTRACT_APPROVAL workflow_definition found - run 004''s seed function first';
    END IF;

    v_idempotency_key := COALESCE(p_idempotency_key, 'contract-request-' || v_request_id::text);

    v_start_result := "workflow"."start_approval_request"(
        v_workflow_definition_id,
        'contract_request',
        v_request_id,
        jsonb_build_object('contract_id', v_contract_id, 'contract_version_id', v_version_id),
        v_idempotency_key
    );

    UPDATE "hr"."contract_requests"
    SET "workflow_request_id" = (v_start_result->>'approval_request_id')::uuid
    WHERE "id" = v_request_id;

    RETURN jsonb_build_object(
        'contract_id', v_contract_id,
        'contract_version_id', v_version_id,
        'contract_request_id', v_request_id,
        'contract_number', v_contract_number,
        'workflow_request_id', v_start_result->>'approval_request_id',
        'status', v_start_result->>'status'
    );
END;
$$;

-- ========================================================================
-- END 009d_contracts_rls_rpc_cutover.sql
-- ========================================================================
