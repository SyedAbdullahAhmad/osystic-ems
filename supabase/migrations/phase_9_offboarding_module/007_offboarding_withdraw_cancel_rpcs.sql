-- ========================================================================
-- 007_offboarding_withdraw_cancel_rpcs.sql  -  resignation withdrawal and termination cancellation (SEPARATE operations)
--   offboarding.withdraw_resignation(case, reason, key)  RESIGNATION only -> WITHDRAWN; the employee on their own case OR OFFBOARDING_MANAGE
--   offboarding.cancel_termination(case, reason, key)    TERMINATION only -> CANCELLED; OFFBOARDING_MANAGE only, never on your own case
--   offboarding._close_case(...)                         internal shared implementation (no app EXECUTE)
-- Cancellable states: SUBMITTED, APPROVED, IN_CLEARANCE (COMPLETED/REJECTED/WITHDRAWN/CANCELLED are final). A non-blank reason is required.
-- SUBMITTED: the workflow request is still open, so exactly ONE sanction row (authorized_by = the authenticated actor) is written
-- immediately before exactly ONE engine CANCEL. APPROVED / IN_CLEARANCE: the workflow request is already closed -> no sanction, no engine call.
-- A true idempotent replay is detected BEFORE any sanction row or engine cancellation. A rejected action leaves no sanction behind.
-- Pending clearance tasks are left as they were (the case row is the final business record).
-- ATOMIC: one transaction; strict pre-flight; post-check.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regprocedure('offboarding.record_clearance(uuid,character varying,text,character varying)') IS NULL THEN
        RAISE EXCEPTION '007 PRE-FLIGHT: apply 006 first'; END IF;
    IF to_regclass('offboarding._workflow_sanctions') IS NULL THEN RAISE EXCEPTION '007 PRE-FLIGHT: apply the corrected 005 first'; END IF;
    IF to_regprocedure('workflow.process_system_action(uuid,workflow.approval_action_type,uuid,text,jsonb,character varying,integer)') IS NULL THEN
        RAISE EXCEPTION '007 PRE-FLIGHT: workflow.process_system_action signature differs from the reviewed baseline'; END IF;
    IF to_regprocedure('offboarding.withdraw_resignation(uuid,text,character varying)') IS NOT NULL
       OR to_regprocedure('offboarding.cancel_termination(uuid,text,character varying)') IS NOT NULL THEN
        RAISE EXCEPTION '007 PRE-FLIGHT: 007 objects already exist (already applied?)'; END IF;
END;
$$;

CREATE FUNCTION "offboarding"."_close_case"(
    p_actor uuid, p_case_id uuid, p_operation text, p_reason text, p_idempotency_key varchar, p_is_manager boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE
    v_reason text; v_hash text; v_existing record; v_case record; v_is_own boolean;
    v_to text; v_wf_cancelled boolean := false; v_event text;
BEGIN
    IF p_operation NOT IN ('WITHDRAW_RESIGNATION', 'CANCEL_TERMINATION') THEN
        RAISE EXCEPTION 'OFFBOARDING_INVALID_OPERATION: %', p_operation; END IF;
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR length(p_idempotency_key) > 200 THEN
        RAISE EXCEPTION 'OFFBOARDING_IDEMPOTENCY_KEY_REQUIRED: a non-blank idempotency key of at most 200 characters is required';
    END IF;
    v_reason := nullif(btrim(coalesce(p_reason, '')), '');
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'OFFBOARDING_REASON_REQUIRED: a non-blank reason is required';
    END IF;
    v_to := CASE WHEN p_operation = 'WITHDRAW_RESIGNATION' THEN 'WITHDRAWN' ELSE 'CANCELLED' END;
    v_hash := encode("extensions"."digest"(concat_ws('|', p_operation, p_actor::text, p_case_id::text, v_reason), 'sha256'), 'hex');

    PERFORM pg_advisory_xact_lock(hashtext('offboarding_key:' || p_idempotency_key)::bigint);
    -- idempotent replay is detected BEFORE any sanction row or workflow cancellation
    SELECT * INTO v_existing FROM "offboarding"."request_idempotency" WHERE "idempotency_key" = p_idempotency_key;
    IF FOUND THEN
        IF v_existing."payload_hash" <> v_hash THEN
            RAISE EXCEPTION 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH: this idempotency key was used with a different request';
        END IF;
        SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id;
        SELECT coalesce((h."detail"->>'workflow_cancelled')::boolean, false) INTO v_wf_cancelled
          FROM "offboarding"."case_history" h WHERE h."case_id" = p_case_id AND h."event_type" = v_to ORDER BY h."created_at" DESC LIMIT 1;
        RETURN jsonb_build_object('case_id', v_case."id", 'operation', p_operation, 'case_status', v_case."status", 'case_version', v_case."version",
            'workflow_cancelled', coalesce(v_wf_cancelled, false), 'idempotent_replay', true);
    END IF;

    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_FOUND: no such case'; END IF;
    IF (p_operation = 'WITHDRAW_RESIGNATION' AND v_case."case_type" <> 'RESIGNATION')
       OR (p_operation = 'CANCEL_TERMINATION' AND v_case."case_type" <> 'TERMINATION') THEN
        RAISE EXCEPTION 'OFFBOARDING_WRONG_CASE_TYPE: % does not apply to a % case', p_operation, v_case."case_type";
    END IF;
    IF v_case."status" NOT IN ('SUBMITTED', 'APPROVED', 'IN_CLEARANCE') THEN
        RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_CANCELLABLE: case is % (only SUBMITTED, APPROVED or IN_CLEARANCE cases can be closed this way)', v_case."status";
    END IF;

    SELECT EXISTS (SELECT 1 FROM "core"."person_user_links" l JOIN "hr"."employees" e ON e."person_id" = l."person_id"
                    WHERE l."user_id" = p_actor AND l."status" = 'ACTIVE' AND e."id" = v_case."hr_employee_id") INTO v_is_own;
    IF p_operation = 'WITHDRAW_RESIGNATION' THEN
        IF NOT (v_is_own OR p_is_manager) THEN
            RAISE EXCEPTION 'OFFBOARDING_NOT_AUTHORIZED: only the employee on their own case, or OFFBOARDING_MANAGE, may withdraw a resignation';
        END IF;
    ELSE
        IF NOT p_is_manager THEN RAISE EXCEPTION 'OFFBOARDING_NOT_AUTHORIZED: OFFBOARDING_MANAGE required to cancel a termination'; END IF;
        IF v_is_own THEN
            RAISE EXCEPTION 'OFFBOARDING_CANNOT_CANCEL_OWN_TERMINATION: you cannot cancel the termination of your own employment';
        END IF;
    END IF;

    IF v_case."status" = 'SUBMITTED' THEN
        IF v_case."workflow_request_id" IS NULL THEN
            RAISE EXCEPTION 'OFFBOARDING_WORKFLOW_REQUEST_MISSING: submitted case % has no workflow request', v_case."id"; END IF;
        INSERT INTO "offboarding"."_workflow_sanctions" ("case_id", "workflow_request_id", "operation", "authorized_by")
        VALUES (v_case."id", v_case."workflow_request_id", p_operation, p_actor);
        PERFORM "workflow"."process_system_action"(v_case."workflow_request_id", 'CANCEL', NULL, v_reason, NULL,
                'offboarding-' || lower(p_operation) || '-' || v_case."id"::text, NULL);
        v_wf_cancelled := true;
    END IF;

    IF p_operation = 'WITHDRAW_RESIGNATION' THEN
        UPDATE "offboarding"."cases" SET "status" = 'WITHDRAWN', "withdrawn_at" = now(), "withdrawn_by" = p_actor, "withdrawal_reason" = v_reason WHERE "id" = v_case."id";
    ELSE
        UPDATE "offboarding"."cases" SET "status" = 'CANCELLED', "cancelled_at" = now(), "cancelled_by" = p_actor, "cancellation_reason" = v_reason WHERE "id" = v_case."id";
    END IF;
    INSERT INTO "offboarding"."case_history" ("case_id", "event_type", "from_status", "to_status", "actor", "detail")
    VALUES (v_case."id", v_to, v_case."status", v_to::"offboarding"."case_status", p_actor,
            jsonb_build_object('reason', v_reason, 'workflow_cancelled', v_wf_cancelled));
    INSERT INTO "offboarding"."request_idempotency" ("idempotency_key", "operation", "case_id", "payload_hash", "created_by")
    VALUES (p_idempotency_key, p_operation, v_case."id", v_hash, p_actor);

    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id;
    RETURN jsonb_build_object('case_id', v_case."id", 'operation', p_operation, 'case_status', v_case."status", 'case_version', v_case."version",
        'workflow_cancelled', v_wf_cancelled, 'idempotent_replay', false);
END;
$$;

CREATE FUNCTION "offboarding"."withdraw_resignation"(p_case_id uuid, p_reason text, p_idempotency_key varchar)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_actor uuid := auth.uid();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: withdraw_resignation requires an authenticated session'; END IF;
    RETURN "offboarding"."_close_case"(v_actor, p_case_id, 'WITHDRAW_RESIGNATION', p_reason, p_idempotency_key, core.has_permission(v_actor, 'OFFBOARDING_MANAGE'));
END;
$$;

CREATE FUNCTION "offboarding"."cancel_termination"(p_case_id uuid, p_reason text, p_idempotency_key varchar)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_actor uuid := auth.uid();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: cancel_termination requires an authenticated session'; END IF;
    IF NOT core.has_permission(v_actor, 'OFFBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'OFFBOARDING_NOT_AUTHORIZED: OFFBOARDING_MANAGE required to cancel a termination';
    END IF;
    RETURN "offboarding"."_close_case"(v_actor, p_case_id, 'CANCEL_TERMINATION', p_reason, p_idempotency_key, true);
END;
$$;

REVOKE ALL ON FUNCTION "offboarding"."_close_case"(uuid, uuid, text, text, varchar, boolean) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."withdraw_resignation"(uuid, text, varchar) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "offboarding"."cancel_termination"(uuid, text, varchar) FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "offboarding"."withdraw_resignation"(uuid, text, varchar) TO "authenticated";
GRANT EXECUTE ON FUNCTION "offboarding"."cancel_termination"(uuid, text, varchar) TO "authenticated";

DO $$
DECLARE v_sig text; v_oid oid;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY['offboarding.withdraw_resignation(uuid,text,character varying)',
                                 'offboarding.cancel_termination(uuid,text,character varying)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        IF v_oid IS NULL THEN RAISE EXCEPTION '007 POST-CHECK: % missing', v_sig; END IF;
        IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) OR NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND p.proconfig::text LIKE '%search_path%') THEN
            RAISE EXCEPTION '007 POST-CHECK: % must be SECURITY DEFINER with a pinned search_path', v_sig; END IF;
        IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
           OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
            RAISE EXCEPTION '007 POST-CHECK: % must be executable by authenticated only', v_sig; END IF;
    END LOOP;
    v_oid := to_regprocedure('offboarding._close_case(uuid,uuid,text,text,character varying,boolean)')::oid;
    IF v_oid IS NULL OR has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
        RAISE EXCEPTION '007 POST-CHECK: _close_case must exist and be closed to app roles'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 007_offboarding_withdraw_cancel_rpcs.sql
-- ========================================================================
