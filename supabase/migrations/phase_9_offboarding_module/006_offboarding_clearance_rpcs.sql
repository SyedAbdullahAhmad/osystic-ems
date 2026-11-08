-- ========================================================================
-- 006_offboarding_clearance_rpcs.sql  -  clearance sign-off and waiver
--   offboarding.record_clearance(case, domain, note, key)  sign-off by OFFBOARDING_CLEARANCE_<DOMAIN> holders ONLY
--   offboarding.waive_clearance(case, domain, reason, key) exceptional override by OFFBOARDING_MANAGE; ASSETS never
--   offboarding._clearance_action(...)                     internal shared implementation (no app EXECUTE)
-- Recording the underlying business action stays in its own module: the ASSETS sign-off does NOT return an asset;
-- it independently verifies ZERO unreturned asset assignments for the employee (read directly, never via
-- assets.assets visibility) and then records the sign-off. OFFBOARDING_MANAGE never signs a domain implicitly.
-- The FIRST valid clearance action (sign-off or waiver) moves the case APPROVED -> IN_CLEARANCE (one case UPDATE,
-- version +1); later actions leave the case row untouched. A replay is detected BEFORE any UPDATE.
-- A person cannot clear or waive a clearance on their own offboarding case.
-- Note and waiver text are stored on the task (waiver reason also in the audit history event).
-- ATOMIC: one transaction; strict pre-flight; post-check.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regprocedure('offboarding.start_resignation(character varying,date,character varying,text)') IS NULL
       OR to_regclass('offboarding._workflow_sanctions') IS NULL THEN
        RAISE EXCEPTION '006 PRE-FLIGHT: apply the corrected 005 first'; END IF;
    IF (SELECT count(*) FROM core.permissions WHERE code IN ('OFFBOARDING_MANAGE','OFFBOARDING_CLEARANCE_ASSETS','OFFBOARDING_CLEARANCE_ACCESS',
                                                              'OFFBOARDING_CLEARANCE_FINANCE','OFFBOARDING_CLEARANCE_HANDOVER','OFFBOARDING_CLEARANCE_HR')) <> 6 THEN
        RAISE EXCEPTION '006 PRE-FLIGHT: offboarding permissions missing (apply 003)'; END IF;
    IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'assets' AND table_name = 'asset_assignments'
         AND column_name IN ('hr_employee_id', 'returned_at')) <> 2 THEN
        RAISE EXCEPTION '006 PRE-FLIGHT: assets.asset_assignments lacks hr_employee_id / returned_at'; END IF;
    IF to_regprocedure('offboarding.record_clearance(uuid,character varying,text,character varying)') IS NOT NULL
       OR to_regprocedure('offboarding.waive_clearance(uuid,character varying,text,character varying)') IS NOT NULL THEN
        RAISE EXCEPTION '006 PRE-FLIGHT: 006 objects already exist (already applied?)'; END IF;
END;
$$;

CREATE FUNCTION "offboarding"."_clearance_action"(
    p_actor uuid, p_case_id uuid, p_domain text, p_action text, p_text text, p_idempotency_key varchar
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr", "assets"
AS $$
DECLARE
    v_text text; v_hash text; v_operation text;
    v_existing record; v_case record; v_task record; v_open int;
BEGIN
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR length(p_idempotency_key) > 200 THEN
        RAISE EXCEPTION 'OFFBOARDING_IDEMPOTENCY_KEY_REQUIRED: a non-blank idempotency key of at most 200 characters is required';
    END IF;
    v_text := nullif(btrim(coalesce(p_text, '')), '');
    IF p_action = 'WAIVE' AND v_text IS NULL THEN
        RAISE EXCEPTION 'OFFBOARDING_WAIVER_REASON_REQUIRED: a waiver needs a non-blank reason';
    END IF;
    v_operation := CASE WHEN p_action = 'CLEAR' THEN 'CLEAR_' ELSE 'WAIVE_' END || p_domain;
    v_hash := encode("extensions"."digest"(concat_ws('|', v_operation, p_actor::text, p_case_id::text, coalesce(v_text, '')), 'sha256'), 'hex');

    PERFORM pg_advisory_xact_lock(hashtext('offboarding_key:' || p_idempotency_key)::bigint);
    SELECT * INTO v_existing FROM "offboarding"."request_idempotency" WHERE "idempotency_key" = p_idempotency_key;
    IF FOUND THEN
        IF v_existing."payload_hash" <> v_hash THEN
            RAISE EXCEPTION 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH: this idempotency key was used with a different request';
        END IF;
        SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id;
        SELECT * INTO v_task FROM "offboarding"."clearance_tasks" WHERE "case_id" = p_case_id AND "domain" = p_domain::"offboarding"."clearance_domain";
        RETURN jsonb_build_object('case_id', v_case."id", 'domain', p_domain, 'task_status', v_task."status", 'case_status', v_case."status",
            'case_version', v_case."version", 'task_version', v_task."version", 'idempotent_replay', true);
    END IF;

    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_FOUND: no such case'; END IF;
    IF v_case."status" NOT IN ('APPROVED', 'IN_CLEARANCE') THEN
        RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_IN_CLEARANCE_STAGE: case is % (clearance applies to APPROVED or IN_CLEARANCE cases)', v_case."status";
    END IF;
    IF EXISTS (SELECT 1 FROM "core"."person_user_links" l JOIN "hr"."employees" e ON e."person_id" = l."person_id"
                WHERE l."user_id" = p_actor AND l."status" = 'ACTIVE' AND e."id" = v_case."hr_employee_id") THEN
        RAISE EXCEPTION 'OFFBOARDING_CANNOT_CLEAR_OWN_CASE: you cannot sign off or waive a clearance on your own offboarding case';
    END IF;
    SELECT * INTO v_task FROM "offboarding"."clearance_tasks"
     WHERE "case_id" = p_case_id AND "domain" = p_domain::"offboarding"."clearance_domain" FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OFFBOARDING_CLEARANCE_TASK_MISSING: case % has no % clearance task', p_case_id, p_domain; END IF;
    IF v_task."status" <> 'PENDING' THEN
        RAISE EXCEPTION 'OFFBOARDING_CLEARANCE_ALREADY_FINAL: the % clearance is already %', p_domain, v_task."status";
    END IF;

    IF p_action = 'CLEAR' AND p_domain = 'ASSETS' THEN
        -- independent verification: the employee must hold ZERO unreturned asset assignments
        SELECT count(*) INTO v_open FROM "assets"."asset_assignments" WHERE "hr_employee_id" = v_case."hr_employee_id" AND "returned_at" IS NULL;
        IF v_open > 0 THEN
            RAISE EXCEPTION 'OFFBOARDING_ASSETS_OUTSTANDING: the employee still holds % unreturned asset assignment(s); record the return in Assets first', v_open;
        END IF;
    END IF;

    IF v_case."status" = 'APPROVED' THEN
        UPDATE "offboarding"."cases" SET "status" = 'IN_CLEARANCE', "clearance_started_at" = now() WHERE "id" = v_case."id";
        INSERT INTO "offboarding"."case_history" ("case_id", "event_type", "from_status", "to_status", "actor", "detail")
        VALUES (v_case."id", 'CLEARANCE_STARTED', 'APPROVED', 'IN_CLEARANCE', p_actor, '{}'::jsonb);
    END IF;

    IF p_action = 'CLEAR' THEN
        UPDATE "offboarding"."clearance_tasks"
           SET "status" = 'CLEARED', "cleared_at" = now(), "cleared_by" = p_actor, "clearance_note" = v_text WHERE "id" = v_task."id";
        INSERT INTO "offboarding"."case_history" ("case_id", "event_type", "actor", "detail")
        VALUES (v_case."id", 'CLEARANCE_CLEARED', p_actor, jsonb_build_object('domain', p_domain));
    ELSE
        UPDATE "offboarding"."clearance_tasks"
           SET "status" = 'WAIVED', "waived_at" = now(), "waived_by" = p_actor, "waiver_reason" = v_text WHERE "id" = v_task."id";
        INSERT INTO "offboarding"."case_history" ("case_id", "event_type", "actor", "detail")
        VALUES (v_case."id", 'CLEARANCE_WAIVED', p_actor, jsonb_build_object('domain', p_domain, 'reason', v_text));
    END IF;

    INSERT INTO "offboarding"."request_idempotency" ("idempotency_key", "operation", "case_id", "payload_hash", "created_by")
    VALUES (p_idempotency_key, v_operation, v_case."id", v_hash, p_actor);

    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id;
    SELECT * INTO v_task FROM "offboarding"."clearance_tasks" WHERE "id" = v_task."id";
    RETURN jsonb_build_object('case_id', v_case."id", 'domain', p_domain, 'task_status', v_task."status", 'case_status', v_case."status",
        'case_version', v_case."version", 'task_version', v_task."version", 'idempotent_replay', false);
END;
$$;

CREATE FUNCTION "offboarding"."record_clearance"(p_case_id uuid, p_domain varchar, p_note text, p_idempotency_key varchar)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr", "assets"
AS $$
DECLARE v_actor uuid := auth.uid(); v_domain text := upper(btrim(coalesce(p_domain, '')));
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: record_clearance requires an authenticated session'; END IF;
    IF v_domain NOT IN ('ASSETS', 'ACCESS', 'FINANCE', 'HANDOVER', 'HR') THEN
        RAISE EXCEPTION 'OFFBOARDING_INVALID_DOMAIN: % is not a clearance domain', p_domain;
    END IF;
    -- the domain-specific permission, and ONLY it: OFFBOARDING_MANAGE does not sign off a domain implicitly
    IF NOT core.has_permission(v_actor, 'OFFBOARDING_CLEARANCE_' || v_domain) THEN
        RAISE EXCEPTION 'OFFBOARDING_NOT_AUTHORIZED: OFFBOARDING_CLEARANCE_% required to sign off this clearance', v_domain;
    END IF;
    RETURN "offboarding"."_clearance_action"(v_actor, p_case_id, v_domain, 'CLEAR', p_note, p_idempotency_key);
END;
$$;

CREATE FUNCTION "offboarding"."waive_clearance"(p_case_id uuid, p_domain varchar, p_reason text, p_idempotency_key varchar)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr", "assets"
AS $$
DECLARE v_actor uuid := auth.uid(); v_domain text := upper(btrim(coalesce(p_domain, '')));
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: waive_clearance requires an authenticated session'; END IF;
    IF v_domain NOT IN ('ASSETS', 'ACCESS', 'FINANCE', 'HANDOVER', 'HR') THEN
        RAISE EXCEPTION 'OFFBOARDING_INVALID_DOMAIN: % is not a clearance domain', p_domain;
    END IF;
    IF NOT core.has_permission(v_actor, 'OFFBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'OFFBOARDING_NOT_AUTHORIZED: OFFBOARDING_MANAGE required to waive a clearance';
    END IF;
    IF v_domain = 'ASSETS' THEN
        RAISE EXCEPTION 'OFFBOARDING_ASSETS_CLEARANCE_CANNOT_BE_WAIVED: an outstanding physical asset can never be waived; record the return in Assets';
    END IF;
    RETURN "offboarding"."_clearance_action"(v_actor, p_case_id, v_domain, 'WAIVE', p_reason, p_idempotency_key);
END;
$$;

REVOKE ALL ON FUNCTION "offboarding"."_clearance_action"(uuid, uuid, text, text, text, varchar) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."record_clearance"(uuid, varchar, text, varchar) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "offboarding"."waive_clearance"(uuid, varchar, text, varchar) FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "offboarding"."record_clearance"(uuid, varchar, text, varchar) TO "authenticated";
GRANT EXECUTE ON FUNCTION "offboarding"."waive_clearance"(uuid, varchar, text, varchar) TO "authenticated";

DO $$
DECLARE v_sig text; v_oid oid;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY['offboarding.record_clearance(uuid,character varying,text,character varying)',
                                 'offboarding.waive_clearance(uuid,character varying,text,character varying)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        IF v_oid IS NULL THEN RAISE EXCEPTION '006 POST-CHECK: % missing', v_sig; END IF;
        IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) OR NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND p.proconfig::text LIKE '%search_path%') THEN
            RAISE EXCEPTION '006 POST-CHECK: % must be SECURITY DEFINER with a pinned search_path', v_sig; END IF;
        IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
           OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
            RAISE EXCEPTION '006 POST-CHECK: % must be executable by authenticated only', v_sig; END IF;
    END LOOP;
    v_oid := to_regprocedure('offboarding._clearance_action(uuid,uuid,text,text,text,character varying)')::oid;
    IF v_oid IS NULL OR has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
        RAISE EXCEPTION '006 POST-CHECK: _clearance_action must exist and be closed to app roles'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 006_offboarding_clearance_rpcs.sql
-- ========================================================================
