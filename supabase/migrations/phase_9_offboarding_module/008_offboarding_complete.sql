-- ========================================================================
-- 008_offboarding_complete.sql  -  atomic completion of an offboarding case
--   offboarding.complete_offboarding(case, idempotency_key)   OFFBOARDING_MANAGE; never on your own case
--   offboarding._completion_blockers(hr_employee_id)          internal: employee-scoped unresolved items (jsonb array)
--   offboarding._business_date()                              internal: the business date used for the last-working-date rule
-- Rules (team lead decisions B1-B10):
--   * only an IN_CLEARANCE case can complete; business date must be >= last_working_date (no scheduler)
--   * exactly the five clearance domains, each final: ASSETS = CLEARED only; ACCESS/FINANCE/HANDOVER/HR = CLEARED or WAIVED
--   * zero unreturned asset assignments is re-verified independently
--   * BLOCKS on employee-scoped open items only (never cancels another module's records):
--       leave requests DRAFT/SUBMITTED; APPROVED leave that extends beyond the last working date; attendance correction
--       requests SUBMITTED; asset requests SUBMITTED/APPROVED; contracts PENDING_APPROVAL.  Returned as a structured list [{type, record_id, status}].
--   * terminates EVERY ACTIVE contract of the employee (hr.terminate_contract) and then the employee (hr.terminate_employee),
--     both with effective date = last_working_date. Any failure rolls the whole completion back. No ACTIVE contract does not block.
--   * writes two immutable outbox events carrying the standard envelope (no termination reason, ever):
--       employee.offboarding.completed (schema_version 1) and ACCESS_REVOCATION_REQUESTED. Idempotency keys are derived from the case.
--   * does NOT touch Supabase Auth, does NOT change core.people.person_type, does NOT calculate notice/settlement.
-- ATOMIC: one transaction; strict pre-flight; post-check.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regprocedure('offboarding.withdraw_resignation(uuid,text,character varying)') IS NULL THEN
        RAISE EXCEPTION '008 PRE-FLIGHT: apply 007 first'; END IF;
    IF to_regprocedure('hr.terminate_contract(uuid,date)') IS NULL OR to_regprocedure('hr.terminate_employee(uuid,date)') IS NULL THEN
        RAISE EXCEPTION '008 PRE-FLIGHT: hr.terminate_contract / hr.terminate_employee (P03/P04) are missing'; END IF;
    IF to_regclass('offboarding.outbox_events') IS NULL OR to_regclass('offboarding.outbox_delivery') IS NULL THEN
        RAISE EXCEPTION '008 PRE-FLIGHT: offboarding outbox tables are missing (apply 001)'; END IF;
    IF to_regprocedure('offboarding.complete_offboarding(uuid,character varying)') IS NOT NULL
       OR to_regprocedure('offboarding._completion_blockers(uuid)') IS NOT NULL
       OR to_regprocedure('offboarding._business_date()') IS NOT NULL THEN
        RAISE EXCEPTION '008 PRE-FLIGHT: 008 objects already exist (already applied?)'; END IF;
END;
$$;

-- the business date for the last-working-date rule. ASSUMPTION (to be confirmed): the organisation operates on Pakistan time.
-- Defined in ONE place so it can be changed without touching the completion logic.
CREATE FUNCTION "offboarding"."_business_date"() RETURNS date
LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$ SELECT (now() AT TIME ZONE 'Asia/Karachi')::date $$;

CREATE FUNCTION "offboarding"."_completion_blockers"(p_hr_employee_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "hr", "assets", "leave", "attendance"
AS $$
    SELECT coalesce(jsonb_agg(x.b ORDER BY x.b->>'type', x.b->>'record_id'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('type', 'LEAVE_REQUEST', 'record_id', r."id", 'status', r."request_status") AS b
          FROM "leave"."leave_requests" r WHERE r."hr_employee_id" = p_hr_employee_id AND r."request_status" IN ('DRAFT', 'SUBMITTED')
        UNION ALL
        SELECT jsonb_build_object('type', 'ATTENDANCE_CORRECTION_REQUEST', 'record_id', r."id", 'status', r."request_status")
          FROM "attendance"."correction_requests" r WHERE r."hr_employee_id" = p_hr_employee_id AND r."request_status" = 'SUBMITTED'
        UNION ALL
        SELECT jsonb_build_object('type', 'ASSET_REQUEST', 'record_id', r."id", 'status', r."request_status")
          FROM "assets"."asset_requests" r WHERE r."hr_employee_id" = p_hr_employee_id AND r."request_status" IN ('SUBMITTED', 'APPROVED')
        UNION ALL
        SELECT jsonb_build_object('type', 'CONTRACT_APPROVAL', 'record_id', c."id", 'status', c."status")
          FROM "hr"."contracts" c WHERE c."hr_employee_id" = p_hr_employee_id AND c."status" = 'PENDING_APPROVAL'
        UNION ALL
        -- APPROVED leave that runs PAST the last working date of the employee's open case (leave entirely on/before it does not block)
        SELECT jsonb_build_object('type', 'APPROVED_LEAVE_BEYOND_LAST_WORKING_DATE', 'record_id', r."id", 'status', r."request_status")
          FROM "leave"."leave_requests" r
         WHERE r."hr_employee_id" = p_hr_employee_id AND r."request_status" = 'APPROVED'
           AND r."end_date" > (SELECT oc."last_working_date" FROM "offboarding"."cases" oc
                                WHERE oc."hr_employee_id" = p_hr_employee_id AND oc."status" IN ('SUBMITTED', 'APPROVED', 'IN_CLEARANCE')
                                ORDER BY oc."created_at" DESC LIMIT 1)
    ) x;
$$;

CREATE FUNCTION "offboarding"."complete_offboarding"(p_case_id uuid, p_idempotency_key varchar)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr", "assets", "leave", "attendance"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_hash text; v_existing record; v_case record; v_emp record; v_org uuid; v_hist record;
    v_today date; v_n int; v_n2 int; v_bad text; v_blockers jsonb; v_c uuid;
    v_contracts uuid[] := ARRAY[]::uuid[];
    v_now timestamptz := now(); v_ev uuid; v_payload jsonb;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: complete_offboarding requires an authenticated session'; END IF;
    IF NOT core.has_permission(v_actor, 'OFFBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'OFFBOARDING_NOT_AUTHORIZED: OFFBOARDING_MANAGE required to complete an offboarding case';
    END IF;
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR length(p_idempotency_key) > 200 THEN
        RAISE EXCEPTION 'OFFBOARDING_IDEMPOTENCY_KEY_REQUIRED: a non-blank idempotency key of at most 200 characters is required';
    END IF;
    v_hash := encode("extensions"."digest"(concat_ws('|', 'COMPLETE_OFFBOARDING', v_actor::text, p_case_id::text), 'sha256'), 'hex');

    PERFORM pg_advisory_xact_lock(hashtext('offboarding_key:' || p_idempotency_key)::bigint);
    SELECT * INTO v_existing FROM "offboarding"."request_idempotency" WHERE "idempotency_key" = p_idempotency_key;
    IF FOUND THEN
        IF v_existing."payload_hash" <> v_hash THEN
            RAISE EXCEPTION 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH: this idempotency key was used with a different request';
        END IF;
        SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id;
        SELECT h."detail" INTO v_hist FROM "offboarding"."case_history" h WHERE h."case_id" = p_case_id AND h."event_type" = 'COMPLETED' ORDER BY h."created_at" DESC LIMIT 1;
        RETURN jsonb_build_object('case_id', v_case."id", 'case_status', v_case."status", 'case_version', v_case."version",
            'termination_date', v_case."last_working_date", 'contracts_terminated', coalesce((v_hist."detail"->>'contracts_terminated_count')::int, 0),
            'idempotent_replay', true);
    END IF;

    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_FOUND: no such case'; END IF;
    IF v_case."status" <> 'IN_CLEARANCE' THEN
        RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_COMPLETABLE: case is % (only an IN_CLEARANCE case can be completed)', v_case."status";
    END IF;
    IF EXISTS (SELECT 1 FROM "core"."person_user_links" l JOIN "hr"."employees" e ON e."person_id" = l."person_id"
                WHERE l."user_id" = v_actor AND l."status" = 'ACTIVE' AND e."id" = v_case."hr_employee_id") THEN
        RAISE EXCEPTION 'OFFBOARDING_CANNOT_COMPLETE_OWN_CASE: you cannot complete your own offboarding case';
    END IF;

    v_today := "offboarding"."_business_date"();
    IF v_today < v_case."last_working_date" THEN
        RAISE EXCEPTION 'OFFBOARDING_BEFORE_LAST_WORKING_DATE: last working date % has not arrived (business date is %)', v_case."last_working_date", v_today;
    END IF;

    -- exactly the five domains, each final; ASSETS may only be CLEARED
    PERFORM 1 FROM "offboarding"."clearance_tasks" WHERE "case_id" = v_case."id" FOR UPDATE;
    SELECT count(*), count(DISTINCT "domain") INTO v_n, v_n2 FROM "offboarding"."clearance_tasks" WHERE "case_id" = v_case."id";
    IF v_n <> 5 OR v_n2 <> 5 THEN
        RAISE EXCEPTION 'OFFBOARDING_CLEARANCE_TASKS_INVALID: case % must have exactly five clearance tasks, found % (% distinct domains)', v_case."id", v_n, v_n2;
    END IF;
    SELECT string_agg(t."domain"::text, ',' ORDER BY t."domain"::text) INTO v_bad FROM "offboarding"."clearance_tasks" t
     WHERE t."case_id" = v_case."id" AND NOT (t."status" = 'CLEARED' OR (t."status" = 'WAIVED' AND t."domain" <> 'ASSETS'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'OFFBOARDING_CLEARANCE_INCOMPLETE: these clearances are not finally cleared (ASSETS must be CLEARED, the others CLEARED or WAIVED): %', v_bad;
    END IF;
    -- independent verification, regardless of the recorded ASSETS sign-off
    SELECT count(*) INTO v_n FROM "assets"."asset_assignments" WHERE "hr_employee_id" = v_case."hr_employee_id" AND "returned_at" IS NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'OFFBOARDING_ASSETS_OUTSTANDING: the employee still holds % unreturned asset assignment(s)', v_n;
    END IF;

    v_blockers := "offboarding"."_completion_blockers"(v_case."hr_employee_id");
    IF jsonb_array_length(v_blockers) > 0 THEN
        RAISE EXCEPTION 'OFFBOARDING_OPEN_ITEMS_BLOCK: % unresolved employee-scoped item(s) block completion: %', jsonb_array_length(v_blockers), v_blockers::text
            USING DETAIL = v_blockers::text;
    END IF;

    SELECT * INTO v_emp FROM "hr"."employees" WHERE "id" = v_case."hr_employee_id";
    SELECT "organization_id" INTO v_org FROM "core"."people" WHERE "id" = v_emp."person_id";

    -- terminate every ACTIVE contract through the sanctioned function (any failure rolls everything back), then the employee
    FOR v_c IN SELECT c."id" FROM "hr"."contracts" c WHERE c."hr_employee_id" = v_case."hr_employee_id" AND c."status" = 'ACTIVE' ORDER BY c."id" FOR UPDATE LOOP
        PERFORM "hr"."terminate_contract"(v_c, v_case."last_working_date");
        v_contracts := v_contracts || v_c;
    END LOOP;
    PERFORM "hr"."terminate_employee"(v_case."hr_employee_id", v_case."last_working_date");

    UPDATE "offboarding"."cases" SET "status" = 'COMPLETED', "completed_at" = v_now, "completed_by" = v_actor WHERE "id" = v_case."id";
    INSERT INTO "offboarding"."case_history" ("case_id", "event_type", "from_status", "to_status", "actor", "detail")
    VALUES (v_case."id", 'COMPLETED', 'IN_CLEARANCE', 'COMPLETED', v_actor,
            jsonb_build_object('termination_date', v_case."last_working_date", 'contracts_terminated', to_jsonb(v_contracts),
                               'contracts_terminated_count', coalesce(array_length(v_contracts, 1), 0)));

    -- outbox event 1: employee.offboarding.completed v1 (no termination reason, ever)
    v_ev := gen_random_uuid();
    v_payload := jsonb_build_object('case_id', v_case."id", 'hr_employee_id', v_case."hr_employee_id", 'person_id', v_emp."person_id",
        'case_type', v_case."case_type", 'last_working_date', v_case."last_working_date", 'termination_date', v_case."last_working_date",
        'completed_at', v_now, 'final_settlement_required', true);
    INSERT INTO "offboarding"."outbox_events" ("id", "case_id", "event_type", "payload")
    VALUES (v_ev, v_case."id", 'employee.offboarding.completed', jsonb_build_object(
        'event_id', v_ev, 'schema_version', '1', 'source_module', 'offboarding', 'organization_id', v_org,
        'idempotency_key', 'offboarding:employee.offboarding.completed:' || v_case."id"::text,
        'occurred_at', v_now, 'effective_business_date', v_case."last_working_date", 'actor_id', v_actor, 'correlation_id', v_case."id",
        'payload_hash', encode("extensions"."digest"(v_payload::text, 'sha256'), 'hex'), 'processing_status', 'PENDING', 'payload', v_payload));
    INSERT INTO "offboarding"."outbox_delivery" ("event_id") VALUES (v_ev);

    -- outbox event 2: ACCESS_REVOCATION_REQUESTED (consumed later by NFC / access administration)
    v_ev := gen_random_uuid();
    v_payload := jsonb_build_object('case_id', v_case."id", 'hr_employee_id', v_case."hr_employee_id", 'person_id', v_emp."person_id",
        'last_working_date', v_case."last_working_date", 'requested_at', v_now);
    INSERT INTO "offboarding"."outbox_events" ("id", "case_id", "event_type", "payload")
    VALUES (v_ev, v_case."id", 'ACCESS_REVOCATION_REQUESTED', jsonb_build_object(
        'event_id', v_ev, 'schema_version', '1', 'source_module', 'offboarding', 'organization_id', v_org,
        'idempotency_key', 'offboarding:ACCESS_REVOCATION_REQUESTED:' || v_case."id"::text,
        'occurred_at', v_now, 'effective_business_date', v_case."last_working_date", 'actor_id', v_actor, 'correlation_id', v_case."id",
        'payload_hash', encode("extensions"."digest"(v_payload::text, 'sha256'), 'hex'), 'processing_status', 'PENDING', 'payload', v_payload));
    INSERT INTO "offboarding"."outbox_delivery" ("event_id") VALUES (v_ev);

    INSERT INTO "offboarding"."request_idempotency" ("idempotency_key", "operation", "case_id", "payload_hash", "created_by")
    VALUES (p_idempotency_key, 'COMPLETE_OFFBOARDING', v_case."id", v_hash, v_actor);

    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id;
    RETURN jsonb_build_object('case_id', v_case."id", 'case_status', v_case."status", 'case_version', v_case."version",
        'termination_date', v_case."last_working_date", 'contracts_terminated', coalesce(array_length(v_contracts, 1), 0), 'idempotent_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION "offboarding"."_business_date"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."_completion_blockers"(uuid) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."complete_offboarding"(uuid, varchar) FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "offboarding"."complete_offboarding"(uuid, varchar) TO "authenticated";

DO $$
DECLARE v_oid oid; v_sig text;
BEGIN
    v_oid := to_regprocedure('offboarding.complete_offboarding(uuid,character varying)')::oid;
    IF v_oid IS NULL THEN RAISE EXCEPTION '008 POST-CHECK: complete_offboarding missing'; END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) OR NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND p.proconfig::text LIKE '%search_path%') THEN
        RAISE EXCEPTION '008 POST-CHECK: complete_offboarding must be SECURITY DEFINER with a pinned search_path'; END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
        RAISE EXCEPTION '008 POST-CHECK: complete_offboarding must be executable by authenticated only'; END IF;
    FOREACH v_sig IN ARRAY ARRAY['offboarding._business_date()', 'offboarding._completion_blockers(uuid)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        IF v_oid IS NULL OR has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
           OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
            RAISE EXCEPTION '008 POST-CHECK: % must exist and be closed to app roles', v_sig; END IF;
    END LOOP;
END;
$$;

COMMIT;
-- ========================================================================
-- END 008_offboarding_complete.sql
-- ========================================================================
