-- ========================================================================
-- 005_offboarding_start_rpcs_and_workflow_sync.sql
-- Initiation RPCs + workflow-to-case synchronisation.
--   offboarding.start_resignation(...)            self-service: employee derived from auth.uid() + ACTIVE person link
--   offboarding.start_resignation_on_behalf(...)  HR (OFFBOARDING_MANAGE), employee id supplied
--   offboarding.start_termination(...)            HR (OFFBOARDING_MANAGE), employee id supplied
--   offboarding._start_case(...)                  internal shared implementation (no EXECUTE for app roles)
--   offboarding._on_workflow_status_change()      AFTER INSERT trigger on workflow.status_history
-- Every case is created with EXACTLY five clearance tasks (ASSETS, ACCESS, FINANCE, HANDOVER, HR) in the
-- same transaction. The workflow request is started BEFORE the case row, so the case is inserted with its
-- workflow_request_id already set (no follow-up UPDATE, so version stays 1 on creation).
-- Reason detail is never copied into workflow metadata or case history.
-- WORKFLOW CANCELLATION is authorised by an Offboarding-owned, TRANSACTION-BOUND sanction row
-- (offboarding._workflow_sanctions: txid + case + workflow request + operation + target CANCELLED), not by a
-- session setting. App roles hold no privilege on that table; the 007 RPCs write the row immediately before
-- cancelling. WORKFLOW START needs no sanction: workflow.start_approval_request() is REVOKEd from PUBLIC and
-- authenticated (Phase 2, 004) and granted to service_role only, so a normal user cannot start an
-- Offboarding workflow request without going through these RPCs (proved in TEST_offboarding_005).
-- ATOMIC: one transaction; strict pre-flight; post-check.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regclass('offboarding.cases') IS NULL THEN RAISE EXCEPTION '005 PRE-FLIGHT: apply 001-004 first'; END IF;
    IF to_regprocedure('offboarding.seed_offboarding_workflow_definitions()') IS NULL THEN RAISE EXCEPTION '005 PRE-FLIGHT: apply 004 first'; END IF;
    IF to_regprocedure('workflow.start_approval_request(uuid,character varying,uuid,jsonb,character varying)') IS NULL THEN
        RAISE EXCEPTION '005 PRE-FLIGHT: workflow.start_approval_request signature differs from the reviewed baseline'; END IF;
    IF to_regprocedure('extensions.digest(text,text)') IS NULL THEN RAISE EXCEPTION '005 PRE-FLIGHT: extensions.digest(text,text) (pgcrypto) not found'; END IF;
    IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'workflow' AND table_name = 'status_history' AND column_name IN ('approval_request_id', 'to_status')) <> 2 THEN
        RAISE EXCEPTION '005 PRE-FLIGHT: workflow.status_history lacks approval_request_id / to_status'; END IF;
    IF to_regprocedure('offboarding._start_case(uuid,uuid,text,character varying,character varying,date,character varying,text,boolean)') IS NOT NULL
       OR to_regprocedure('offboarding.start_resignation(character varying,date,character varying,text)') IS NOT NULL
       OR to_regclass('offboarding._workflow_sanctions') IS NOT NULL
       OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_offboarding_on_workflow_status_change') THEN
        RAISE EXCEPTION '005 PRE-FLIGHT: 005 objects already exist (already applied?)'; END IF;
END;
$$;

-- ---------------- transaction-bound workflow sanctions (internal; no app privileges; immutable) ----------------
CREATE TABLE "offboarding"."_workflow_sanctions" (
    "id"                  uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "txid"                bigint NOT NULL DEFAULT txid_current(),
    "case_id"             uuid NOT NULL REFERENCES "offboarding"."cases"("id"),
    "workflow_request_id" uuid NOT NULL REFERENCES "workflow"."approval_requests"("id"),
    "operation"           varchar(30) NOT NULL CHECK ("operation" IN ('WITHDRAW_RESIGNATION', 'CANCEL_TERMINATION')),
    "target_status"       varchar(20) NOT NULL DEFAULT 'CANCELLED' CHECK ("target_status" = 'CANCELLED'),
    "authorized_by"       uuid REFERENCES "auth"."users"("id"),
    "created_at"          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX "idx_offboarding_workflow_sanctions_lookup" ON "offboarding"."_workflow_sanctions" ("case_id", "txid");
ALTER TABLE "offboarding"."_workflow_sanctions" ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE "offboarding"."_workflow_sanctions" FROM PUBLIC, "anon", "authenticated";
CREATE TRIGGER "trg_workflow_sanctions_immutable"
    BEFORE UPDATE OR DELETE ON "offboarding"."_workflow_sanctions"
    FOR EACH ROW EXECUTE FUNCTION "offboarding"."_prevent_mutation"();

-- ---------------- internal shared implementation ----------------
CREATE FUNCTION "offboarding"."_start_case"(
    p_actor uuid, p_hr_employee_id uuid, p_case_type text, p_operation varchar,
    p_idempotency_key varchar, p_last_working_date date, p_reason_category varchar, p_reason_detail text, p_on_behalf boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE
    v_category varchar; v_detail text; v_hash text;
    v_existing record; v_emp record; v_case record;
    v_org uuid; v_def_id uuid; v_code text;
    v_case_id uuid := gen_random_uuid();
    v_start jsonb; v_req uuid; v_wf_status text;
BEGIN
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR length(p_idempotency_key) > 200 THEN
        RAISE EXCEPTION 'OFFBOARDING_IDEMPOTENCY_KEY_REQUIRED: a non-blank idempotency key of at most 200 characters is required';
    END IF;
    v_category := upper(btrim(coalesce(p_reason_category, '')));
    v_detail   := nullif(btrim(coalesce(p_reason_detail, '')), '');
    IF p_case_type = 'RESIGNATION' AND v_category NOT IN ('PERSONAL', 'CAREER', 'RELOCATION', 'OTHER') THEN
        RAISE EXCEPTION 'OFFBOARDING_INVALID_REASON_CATEGORY: % is not valid for a resignation', v_category;
    END IF;
    IF p_case_type = 'TERMINATION' AND v_category NOT IN ('PERFORMANCE', 'CONDUCT', 'REDUNDANCY', 'CONTRACT_END', 'OTHER') THEN
        RAISE EXCEPTION 'OFFBOARDING_INVALID_REASON_CATEGORY: % is not valid for a termination', v_category;
    END IF;
    IF p_case_type = 'TERMINATION' AND v_detail IS NULL THEN
        RAISE EXCEPTION 'OFFBOARDING_REASON_DETAIL_REQUIRED: a termination requires a reason detail';
    END IF;
    IF p_last_working_date IS NULL THEN
        RAISE EXCEPTION 'OFFBOARDING_LAST_WORKING_DATE_REQUIRED: last working date is required';
    END IF;

    SELECT e."id", e."employment_status" INTO v_emp FROM "hr"."employees" e WHERE e."id" = p_hr_employee_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'OFFBOARDING_EMPLOYEE_NOT_FOUND: no such employee'; END IF;

    v_hash := encode("extensions"."digest"(concat_ws('|', p_operation, p_actor::text, p_hr_employee_id::text, p_case_type,
                v_category, coalesce(v_detail, ''), p_last_working_date::text, p_on_behalf::text), 'sha256'), 'hex');

    -- serialise concurrent calls with the same key BEFORE the lookup (replay-safe)
    PERFORM pg_advisory_xact_lock(hashtext('offboarding_key:' || p_idempotency_key)::bigint);
    SELECT * INTO v_existing FROM "offboarding"."request_idempotency" WHERE "idempotency_key" = p_idempotency_key;
    IF FOUND THEN
        IF v_existing."payload_hash" <> v_hash THEN
            RAISE EXCEPTION 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH: this idempotency key was used with a different request';
        END IF;
        SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = v_existing."case_id";
        SELECT "current_status" INTO v_wf_status FROM "workflow"."approval_requests" WHERE "id" = v_case."workflow_request_id";
        RETURN jsonb_build_object('case_id', v_case."id", 'case_type', v_case."case_type", 'status', v_case."status",
            'workflow_request_id', v_case."workflow_request_id", 'workflow_status', v_wf_status,
            'clearance_task_count', (SELECT count(*) FROM "offboarding"."clearance_tasks" WHERE "case_id" = v_case."id"),
            'version', v_case."version", 'idempotent_replay', true);
    END IF;

    IF v_emp."employment_status" NOT IN ('ACTIVE', 'ON_LEAVE') THEN
        RAISE EXCEPTION 'OFFBOARDING_EMPLOYEE_NOT_ACTIVE: employee is %', v_emp."employment_status";
    END IF;
    IF p_last_working_date < current_date THEN
        RAISE EXCEPTION 'OFFBOARDING_LAST_WORKING_DATE_IN_PAST: last working date % is before today', p_last_working_date;
    END IF;

    -- serialise cases per employee; the partial unique index remains the last line of defence
    PERFORM pg_advisory_xact_lock(hashtext('offboarding_employee:' || p_hr_employee_id::text)::bigint);
    IF EXISTS (SELECT 1 FROM "offboarding"."cases" WHERE "hr_employee_id" = p_hr_employee_id AND "status" IN ('SUBMITTED', 'APPROVED', 'IN_CLEARANCE')) THEN
        RAISE EXCEPTION 'OFFBOARDING_OPEN_CASE_EXISTS: this employee already has an open offboarding case';
    END IF;

    SELECT "id" INTO v_org FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    v_code := CASE WHEN p_case_type = 'RESIGNATION' THEN 'OFFBOARDING_RESIGNATION_APPROVAL' ELSE 'OFFBOARDING_TERMINATION_APPROVAL' END;
    SELECT "id" INTO v_def_id FROM "workflow"."workflow_definitions"
     WHERE "module" = 'offboarding' AND "code" = v_code AND "organization_id" IS NOT DISTINCT FROM v_org;
    IF v_def_id IS NULL THEN
        RAISE EXCEPTION 'OFFBOARDING_WORKFLOW_NOT_CONFIGURED: no % definition found - run the 004 seed function first', v_code;
    END IF;

    -- workflow request first, with the (pre-generated) case id as entity; no reason detail in the metadata
    v_start := "workflow"."start_approval_request"(v_def_id, 'offboarding_case', v_case_id,
        jsonb_build_object('case_type', p_case_type, 'hr_employee_id', p_hr_employee_id,
                           'last_working_date', p_last_working_date, 'reason_category', v_category),
        ('off:' || p_idempotency_key)::varchar);
    v_req := (v_start->>'approval_request_id')::uuid;

    INSERT INTO "offboarding"."cases" ("id", "hr_employee_id", "case_type", "reason_category", "reason_detail",
        "last_working_date", "initiated_by", "on_behalf", "workflow_request_id")
    VALUES (v_case_id, p_hr_employee_id, p_case_type::"offboarding"."case_type", v_category, v_detail,
        p_last_working_date, p_actor, p_on_behalf, v_req);

    -- exactly five clearance tasks, one per mandatory domain, same transaction
    INSERT INTO "offboarding"."clearance_tasks" ("case_id", "domain") VALUES
        (v_case_id, 'ASSETS'), (v_case_id, 'ACCESS'), (v_case_id, 'FINANCE'), (v_case_id, 'HANDOVER'), (v_case_id, 'HR');
    IF (SELECT count(*) FROM "offboarding"."clearance_tasks" WHERE "case_id" = v_case_id) <> 5 THEN
        RAISE EXCEPTION 'OFFBOARDING_INTERNAL_ERROR: expected exactly 5 clearance tasks for case %', v_case_id;
    END IF;

    INSERT INTO "offboarding"."case_history" ("case_id", "event_type", "from_status", "to_status", "actor", "detail")
    VALUES (v_case_id, 'SUBMITTED', NULL, 'SUBMITTED', p_actor,
        jsonb_build_object('case_type', p_case_type, 'reason_category', v_category,
                           'last_working_date', p_last_working_date, 'on_behalf', p_on_behalf));

    INSERT INTO "offboarding"."request_idempotency" ("idempotency_key", "operation", "case_id", "payload_hash", "created_by")
    VALUES (p_idempotency_key, p_operation, v_case_id, v_hash, p_actor);

    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = v_case_id;
    SELECT "current_status" INTO v_wf_status FROM "workflow"."approval_requests" WHERE "id" = v_req;
    RETURN jsonb_build_object('case_id', v_case."id", 'case_type', v_case."case_type", 'status', v_case."status",
        'workflow_request_id', v_req, 'workflow_status', v_wf_status, 'clearance_task_count', 5,
        'version', v_case."version", 'idempotent_replay', false);
END;
$$;

-- ---------------- public RPCs ----------------
CREATE FUNCTION "offboarding"."start_resignation"(
    p_idempotency_key varchar, p_last_working_date date, p_reason_category varchar, p_reason_detail text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_actor uuid := auth.uid(); v_emps uuid[];
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: start_resignation requires an authenticated session'; END IF;
    -- employee is DERIVED from the caller's ACTIVE person link; no employee id is accepted
    SELECT array_agg(DISTINCT e."id") INTO v_emps
      FROM "core"."person_user_links" l JOIN "hr"."employees" e ON e."person_id" = l."person_id"
     WHERE l."user_id" = v_actor AND l."status" = 'ACTIVE';
    IF v_emps IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_NO_ACTIVE_EMPLOYEE_FOR_USER: the signed-in user is not linked to an employee'; END IF;
    IF cardinality(v_emps) <> 1 THEN RAISE EXCEPTION 'OFFBOARDING_AMBIGUOUS_EMPLOYEE_FOR_USER: the signed-in user maps to % employees', cardinality(v_emps); END IF;
    RETURN "offboarding"."_start_case"(v_actor, v_emps[1], 'RESIGNATION', 'START_RESIGNATION',
        p_idempotency_key, p_last_working_date, p_reason_category, p_reason_detail, false);
END;
$$;

CREATE FUNCTION "offboarding"."start_resignation_on_behalf"(
    p_hr_employee_id uuid, p_idempotency_key varchar, p_last_working_date date, p_reason_category varchar, p_reason_detail text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_actor uuid := auth.uid();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: start_resignation_on_behalf requires an authenticated session'; END IF;
    IF NOT core.has_permission(v_actor, 'OFFBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'OFFBOARDING_NOT_AUTHORIZED: OFFBOARDING_MANAGE required to record a resignation on behalf of an employee';
    END IF;
    IF EXISTS (SELECT 1 FROM "core"."person_user_links" l JOIN "hr"."employees" e ON e."person_id" = l."person_id"
                WHERE l."user_id" = v_actor AND l."status" = 'ACTIVE' AND e."id" = p_hr_employee_id) THEN
        RAISE EXCEPTION 'OFFBOARDING_USE_SELF_SERVICE: use start_resignation for your own resignation';
    END IF;
    RETURN "offboarding"."_start_case"(v_actor, p_hr_employee_id, 'RESIGNATION', 'START_RESIGNATION_ON_BEHALF',
        p_idempotency_key, p_last_working_date, p_reason_category, p_reason_detail, true);
END;
$$;

CREATE FUNCTION "offboarding"."start_termination"(
    p_hr_employee_id uuid, p_idempotency_key varchar, p_last_working_date date, p_reason_category varchar, p_reason_detail text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_actor uuid := auth.uid();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: start_termination requires an authenticated session'; END IF;
    IF NOT core.has_permission(v_actor, 'OFFBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'OFFBOARDING_NOT_AUTHORIZED: OFFBOARDING_MANAGE required to start a termination';
    END IF;
    IF EXISTS (SELECT 1 FROM "core"."person_user_links" l JOIN "hr"."employees" e ON e."person_id" = l."person_id"
                WHERE l."user_id" = v_actor AND l."status" = 'ACTIVE' AND e."id" = p_hr_employee_id) THEN
        RAISE EXCEPTION 'OFFBOARDING_CANNOT_TERMINATE_SELF: you cannot start a termination of your own employment';
    END IF;
    RETURN "offboarding"."_start_case"(v_actor, p_hr_employee_id, 'TERMINATION', 'START_TERMINATION',
        p_idempotency_key, p_last_working_date, p_reason_category, p_reason_detail, false);
END;
$$;

-- ---------------- workflow -> case synchronisation ----------------
CREATE FUNCTION "offboarding"."_on_workflow_status_change"() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow"
AS $$
DECLARE v_case record;
BEGIN
    IF NEW."to_status" NOT IN ('APPROVED', 'REJECTED', 'CANCELLED') THEN RETURN NEW; END IF;
    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "workflow_request_id" = NEW."approval_request_id" FOR UPDATE;
    IF NOT FOUND THEN RETURN NEW; END IF;

    IF NEW."to_status" = 'CANCELLED' THEN
        -- Accepted ONLY with a sanction row bound to THIS transaction, THIS case, THIS workflow request, the
        -- operation that matches the case type, and target CANCELLED. A stale row (other transaction), another
        -- case's or request's row, or the other operation does not authorise it. A direct engine cancellation
        -- would otherwise strand the case in SUBMITTED.
        IF NOT EXISTS (SELECT 1 FROM "offboarding"."_workflow_sanctions" s
                        WHERE s."txid" = txid_current()
                          AND s."case_id" = v_case."id"
                          AND s."workflow_request_id" = NEW."approval_request_id"
                          AND s."target_status" = 'CANCELLED'
                          AND s."operation" = CASE WHEN v_case."case_type" = 'RESIGNATION' THEN 'WITHDRAW_RESIGNATION' ELSE 'CANCEL_TERMINATION' END) THEN
            RAISE EXCEPTION 'OFFBOARDING_WORKFLOW_CANCEL_NOT_SANCTIONED: use withdraw_resignation or cancel_termination for case %', v_case."id";
        END IF;
        RETURN NEW;
    END IF;

    IF v_case."status" <> 'SUBMITTED' THEN RETURN NEW; END IF;
    IF NEW."to_status" = 'APPROVED' THEN
        UPDATE "offboarding"."cases" SET "status" = 'APPROVED', "approved_at" = now() WHERE "id" = v_case."id";
        INSERT INTO "offboarding"."case_history" ("case_id", "event_type", "from_status", "to_status", "actor", "detail")
        VALUES (v_case."id", 'APPROVED', 'SUBMITTED', 'APPROVED', auth.uid(), '{}'::jsonb);
    ELSE
        UPDATE "offboarding"."cases" SET "status" = 'REJECTED' WHERE "id" = v_case."id";
        INSERT INTO "offboarding"."case_history" ("case_id", "event_type", "from_status", "to_status", "actor", "detail")
        VALUES (v_case."id", 'REJECTED', 'SUBMITTED', 'REJECTED', auth.uid(), '{}'::jsonb);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER "trg_offboarding_on_workflow_status_change"
    AFTER INSERT ON "workflow"."status_history"
    FOR EACH ROW EXECUTE FUNCTION "offboarding"."_on_workflow_status_change"();

-- ---------------- privileges: minimum EXECUTE ----------------
REVOKE ALL ON FUNCTION "offboarding"."_start_case"(uuid, uuid, text, varchar, varchar, date, varchar, text, boolean) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."_on_workflow_status_change"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."start_resignation"(varchar, date, varchar, text) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "offboarding"."start_resignation_on_behalf"(uuid, varchar, date, varchar, text) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "offboarding"."start_termination"(uuid, varchar, date, varchar, text) FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "offboarding"."start_resignation"(varchar, date, varchar, text) TO "authenticated";
GRANT EXECUTE ON FUNCTION "offboarding"."start_resignation_on_behalf"(uuid, varchar, date, varchar, text) TO "authenticated";
GRANT EXECUTE ON FUNCTION "offboarding"."start_termination"(uuid, varchar, date, varchar, text) TO "authenticated";

DO $$
DECLARE v_sig text; v_oid oid;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY[
        'offboarding.start_resignation(character varying,date,character varying,text)',
        'offboarding.start_resignation_on_behalf(uuid,character varying,date,character varying,text)',
        'offboarding.start_termination(uuid,character varying,date,character varying,text)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        IF v_oid IS NULL THEN RAISE EXCEPTION '005 POST-CHECK: % missing', v_sig; END IF;
        IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN RAISE EXCEPTION '005 POST-CHECK: % is not SECURITY DEFINER', v_sig; END IF;
        IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
           OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
            RAISE EXCEPTION '005 POST-CHECK: % must be executable by authenticated only', v_sig; END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND p.proconfig::text LIKE '%search_path%') THEN
            RAISE EXCEPTION '005 POST-CHECK: % has no pinned search_path', v_sig; END IF;
    END LOOP;
    FOREACH v_sig IN ARRAY ARRAY[
        'offboarding._start_case(uuid,uuid,text,character varying,character varying,date,character varying,text,boolean)',
        'offboarding._on_workflow_status_change()'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        IF v_oid IS NULL THEN RAISE EXCEPTION '005 POST-CHECK: % missing', v_sig; END IF;
        IF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
           OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
            RAISE EXCEPTION '005 POST-CHECK: internal function % is executable by an app role or PUBLIC', v_sig; END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_offboarding_on_workflow_status_change' AND tgrelid = 'workflow.status_history'::regclass AND tgenabled <> 'D') THEN
        RAISE EXCEPTION '005 POST-CHECK: workflow sync trigger missing'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'offboarding._workflow_sanctions'::regclass AND relrowsecurity AND NOT relforcerowsecurity)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'offboarding._workflow_sanctions'::regclass AND tgname = 'trg_workflow_sanctions_immutable') THEN
        RAISE EXCEPTION '005 POST-CHECK: sanction table is not RLS-enabled/immutable'; END IF;
    FOREACH v_sig IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
        IF has_table_privilege('authenticated', 'offboarding._workflow_sanctions', v_sig) OR has_table_privilege('anon', 'offboarding._workflow_sanctions', v_sig)
           OR EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid = 'offboarding._workflow_sanctions'::regclass AND a.grantee = 0 AND a.privilege_type = v_sig) THEN
            RAISE EXCEPTION '005 POST-CHECK: an app role or PUBLIC holds % on the sanction table', v_sig; END IF;
    END LOOP;
END;
$$;

COMMIT;
-- ========================================================================
-- END 005_offboarding_start_rpcs_and_workflow_sync.sql
-- ========================================================================
