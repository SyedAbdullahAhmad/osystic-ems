-- ========================================================================
-- 003_contracts_create_and_submit_request.sql
-- Phase 6: Contracts Module - integration point with the workflow engine.
--
-- ONE RPC, not two like Assets' submit/fulfill split: hr.create_contract()
-- creates the contract + its first version + the contract_request link,
-- then immediately submits for approval - all in one call. This differs
-- from Assets deliberately: Assets splits submit/fulfill because
-- fulfillment requires picking a specific physical unit, a real logistics
-- decision that can't happen at approval time. Nothing analogous blocks a
-- contract from going straight to ACTIVE on approval - see the trigger
-- below and CONTRACTS_MODULE_DESIGN_NOTES.md \u00a74(b) for the full reasoning,
-- confirmed by team lead.
--
-- Confirmed against the actual workflow engine (phase_2_workflow_engine/
-- 004_workflow_functions_triggers.sql), not assumed: start_approval_
-- request() genuinely enforces workflow_definitions.initiation_
-- permission_code (raises WORKFLOW_INITIATION_NOT_AUTHORIZED if the
-- caller lacks it). 004 below sets this to CONTRACT_MANAGE, so the
-- HR/Admin-only restriction is enforced at TWO layers: this RPC's own
-- explicit check (cleaner error, fails before any INSERT happens) and
-- the workflow engine itself (defense-in-depth, not just documentation -
-- verified this actually does something before relying on it).
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

    -- Explicit check here (in addition to the workflow-engine-level one
    -- below) so an ineligible caller gets a clear error immediately,
    -- before any row is written.
    IF NOT core.has_permission(v_actor, 'CONTRACT_MANAGE') THEN
        RAISE EXCEPTION 'CONTRACTS_NOT_AUTHORIZED: CONTRACT_MANAGE required to create a contract';
    END IF;

    IF p_effective_from IS NULL THEN
        RAISE EXCEPTION 'CONTRACTS_EFFECTIVE_FROM_REQUIRED: an effective_from date is required';
    END IF;
    IF p_effective_to IS NOT NULL AND p_effective_to < p_effective_from THEN
        RAISE EXCEPTION 'CONTRACTS_INVALID_DATE_RANGE: effective_to cannot be before effective_from';
    END IF;

    -- Simple placeholder numbering scheme, not a real business numbering
    -- scheme - flagging rather than pretending this is final. Caller can
    -- always supply p_contract_number explicitly instead.
    v_contract_number := COALESCE(
        p_contract_number,
        'CN-' || to_char(now(), 'YYYYMMDD') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)
    );

    INSERT INTO "hr"."contracts" ("employee_id", "contract_number", "contract_type", "status")
    VALUES (p_employee_id, v_contract_number, p_contract_type, 'PENDING_APPROVAL')
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

REVOKE ALL ON FUNCTION "hr"."create_contract"(uuid, "hr"."contract_type", date, date, uuid, text, varchar, varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "hr"."create_contract"(uuid, "hr"."contract_type", date, date, uuid, text, varchar, varchar) TO "authenticated";

-- ------------------------------------------------------------------------
-- React to the workflow reaching a terminal state. Per design notes
-- \u00a74(b) (team-lead-confirmed default): APPROVED flips straight to ACTIVE,
-- no separate manual step - nothing analogous to Assets' "pick a
-- physical unit" blocks a contract from activating automatically.
--
-- IMPORTANT, learned directly from the Assets module's 003 bug: this
-- uses BRANCHED, UNTYPED STRING LITERALS ('ACTIVE'/'REJECTED'), not a
-- cast of NEW."to_status" itself. That's not optional here the way it
-- might look - the workflow's own to_status literal is 'APPROVED', which
-- is NOT the business status we want ('ACTIVE'), so a direct
-- NEW."to_status"::"hr"."contract_status" cast would incorrectly leave
-- the contract sitting at 'APPROVED' forever instead of activating it.
-- Branching per status, same mechanism Leave/Attendance use, is the
-- only correct option here - not just the safer one.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "hr"."_on_contract_workflow_status_change"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "hr", "workflow"
AS $$
BEGIN
    IF NEW."to_status" = 'APPROVED' THEN
        UPDATE "hr"."contracts"
        SET "status" = 'ACTIVE'
        WHERE "id" = (
            SELECT "contract_id" FROM "hr"."contract_requests"
            WHERE "workflow_request_id" = NEW."approval_request_id"
        )
        AND "status" = 'PENDING_APPROVAL';
    ELSIF NEW."to_status" = 'REJECTED' THEN
        UPDATE "hr"."contracts"
        SET "status" = 'REJECTED'
        WHERE "id" = (
            SELECT "contract_id" FROM "hr"."contract_requests"
            WHERE "workflow_request_id" = NEW."approval_request_id"
        )
        AND "status" = 'PENDING_APPROVAL';
    END IF;

    RETURN NEW;
END;
$$;

-- Attaches to the SAME shared workflow.status_history table that
-- Leave/Attendance/Assets each already have their own trigger on - this
-- one just no-ops (0 rows affected) for any status_history insert that
-- isn't a contract request, same coexistence pattern already proven
-- across three prior modules.
DROP TRIGGER IF EXISTS "trg_hr_contracts_on_workflow_status_change" ON "workflow"."status_history";
CREATE TRIGGER "trg_hr_contracts_on_workflow_status_change"
    AFTER INSERT ON "workflow"."status_history"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_on_contract_workflow_status_change"();

-- ========================================================================
-- END 003_contracts_create_and_submit_request.sql
-- ========================================================================
