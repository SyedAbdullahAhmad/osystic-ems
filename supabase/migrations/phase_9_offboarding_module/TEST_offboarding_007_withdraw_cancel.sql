-- ========================================================================
-- TEST_offboarding_007_withdraw_cancel.sql
-- Run AFTER 001-007 and the seed runner. Everything lives in ONE rolled-back sub-block; nothing persists.
-- Gate: any FAIL raises; all PASS completes with a notice.
-- ========================================================================
DROP TABLE IF EXISTS "_off007_results";
CREATE TEMP TABLE "_off007_results" ("step" text, "result" text);

CREATE FUNCTION pg_temp._as(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
END;
$f$;
CREATE FUNCTION pg_temp._err(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN EXECUTE p_sql; RETURN NULL; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END;
$f$;
CREATE FUNCTION pg_temp._expect(p_err text, p_prefix text) RETURNS text LANGUAGE sql AS $f$
    SELECT CASE WHEN p_err IS NULL THEN 'FAIL: no error raised' WHEN p_err LIKE p_prefix || '%' THEN 'PASS' ELSE 'FAIL: ' || p_err END
$f$;
-- start a case as p_creator and optionally approve it as p_approver; p_kind = TERMINATION | RESIGNATION_OB (on behalf) | RESIGNATION_SELF (creator is the employee)
CREATE FUNCTION pg_temp._mk(p_kind text, p_emp uuid, p_tag text, p_creator uuid, p_approver uuid, p_approve boolean) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_r jsonb; v_case uuid; v_req uuid; v_step uuid; v_ver int;
BEGIN
    PERFORM pg_temp._as(p_creator);
    IF p_kind = 'TERMINATION' THEN
        v_r := offboarding.start_termination(p_emp, 'off007-' || p_tag, current_date + 10, 'CONDUCT', 'detail ' || p_tag);
    ELSIF p_kind = 'RESIGNATION_OB' THEN
        v_r := offboarding.start_resignation_on_behalf(p_emp, 'off007-' || p_tag, current_date + 10, 'PERSONAL', 'detail ' || p_tag);
    ELSE
        v_r := offboarding.start_resignation('off007-' || p_tag, current_date + 10, 'PERSONAL', 'detail ' || p_tag);
    END IF;
    v_case := (v_r->>'case_id')::uuid; v_req := (v_r->>'workflow_request_id')::uuid;
    IF p_approve THEN
        PERFORM pg_temp._as(p_approver);
        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req;
        PERFORM workflow.process_approval_action(v_req, 'APPROVE', v_step, 'ok', NULL, 'off007-appr-' || p_tag, v_ver);
    END IF;
    RETURN v_case;
END;
$f$;

DO $$
DECLARE
    v_res text[] := ARRAY[]::text[];
    v_run text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    v_org uuid; v_hr1 uuid; v_p uuid; v_role uuid;
    v_hr2 uuid := '00000000-0000-0000-0000-0000000000a6';
    v_clr uuid := '00000000-0000-0000-0000-0000000000a1';
    v_e1u uuid := '00000000-0000-0000-0000-0000000000a5';
    v_oth uuid := '00000000-0000-0000-0000-0000000000a7';
    v_acc uuid := '00000000-0000-0000-0000-0000000000a9';
    v_emp1 uuid; v_emp2 uuid; v_emp3 uuid; v_emp4 uuid; v_emp5 uuid; v_emp6 uuid;
    c_a uuid; c_b uuid; c_c uuid; c_d uuid; c_e uuid; c_f uuid; c_g uuid;
    v_r jsonb; v_r2 jsonb; v_req uuid; v_step uuid; v_ver int; v_s text; v_n int; v_n2 int; v_n3 int; v_cv int; v_hist int;
    v_sig text; v_oid oid; v_k text := 'off007k-' || substr(md5(random()::text), 1, 6) || '-';
BEGIN
    SELECT id INTO v_org FROM core.organizations WHERE code = 'OSYSTIC';
    SELECT id INTO v_hr1 FROM auth.users WHERE core.has_permission(id, 'WORKFLOW_CONFIG_MANAGE') AND id NOT IN (v_hr2, v_clr, v_acc, v_e1u, v_oth) ORDER BY created_at LIMIT 1;
    IF v_org IS NULL OR v_hr1 IS NULL THEN RAISE EXCEPTION 'SETUP: org=%, hr1=%', v_org, v_hr1; END IF;
    IF (SELECT count(*) FROM auth.users WHERE id IN (v_hr2, v_clr, v_acc, v_e1u, v_oth)) <> 5 THEN RAISE EXCEPTION 'SETUP: fixture users a1/a5/a6/a7/a9 are missing'; END IF;
    IF (SELECT count(*) FROM workflow.workflow_definitions d JOIN workflow.workflow_versions v ON v.workflow_definition_id = d.id WHERE d.module = 'offboarding' AND v.status = 'ACTIVE') <> 2 THEN
        RAISE EXCEPTION 'SETUP: offboarding workflow definitions are not ACTIVE - run the seed runner first'; END IF;

    -- 0. privileges and shape
    FOREACH v_sig IN ARRAY ARRAY['offboarding.withdraw_resignation(uuid,text,character varying)', 'offboarding.cancel_termination(uuid,text,character varying)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        v_res := v_res || ARRAY['0a-' || split_part(split_part(v_sig, '(', 1), '.', 2) || '-authenticated-only-definer-pinned-path|' ||
            CASE WHEN v_oid IS NOT NULL AND has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
                  AND (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) AND (SELECT proconfig::text LIKE '%search_path%' FROM pg_proc WHERE oid = v_oid)
                  AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))
                 THEN 'PASS' ELSE 'FAIL: ' || v_sig END];
    END LOOP;
    v_oid := to_regprocedure('offboarding._close_case(uuid,uuid,text,text,character varying,boolean)')::oid;
    v_res := v_res || ARRAY['0b-internal-close-function-closed-to-app-roles|' ||
        CASE WHEN v_oid IS NOT NULL AND NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END];

    BEGIN
        PERFORM pg_temp._as(v_hr1);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF007_MGR_' || v_run, 'temp mgr', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code = 'OFFBOARDING_MANAGE';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_hr1, v_role), (v_hr2, v_role);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF007_ALL_' || v_run, 'temp all clearance', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code LIKE 'OFFBOARDING\_CLEARANCE\_%';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_clr, v_role);

        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF007 E1', 'off007-e1-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO core.person_user_links (person_id, user_id) VALUES (v_p, v_e1u);
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF007-1-' || v_run, current_date - 400) RETURNING id INTO v_emp1;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF007 E2', 'off007-e2-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF007-2-' || v_run, current_date - 400) RETURNING id INTO v_emp2;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF007 E3', 'off007-e3-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF007-3-' || v_run, current_date - 400) RETURNING id INTO v_emp3;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF007 E4', 'off007-e4-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF007-4-' || v_run, current_date - 400) RETURNING id INTO v_emp4;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF007 E5', 'off007-e5-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF007-5-' || v_run, current_date - 400) RETURNING id INTO v_emp5;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF007 E6', 'off007-e6-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF007-6-' || v_run, current_date - 400) RETURNING id INTO v_emp6;

        c_a := pg_temp._mk('RESIGNATION_SELF', v_emp1, v_run || '-a', v_e1u, NULL, false);          -- SUBMITTED resignation by the employee
        c_b := pg_temp._mk('RESIGNATION_OB',   v_emp2, v_run || '-b', v_hr1, v_hr2, true);           -- APPROVED resignation (on behalf)
        c_c := pg_temp._mk('TERMINATION',      v_emp3, v_run || '-c', v_hr1, NULL, false);           -- SUBMITTED termination
        c_d := pg_temp._mk('TERMINATION',      v_emp4, v_run || '-d', v_hr1, v_hr2, true);           -- APPROVED termination
        c_e := pg_temp._mk('TERMINATION',      v_emp5, v_run || '-e', v_hr1, v_hr2, true);           -- IN_CLEARANCE termination (below)
        c_f := pg_temp._mk('TERMINATION',      v_emp6, v_run || '-f', v_hr1, NULL, false);           -- REJECTED termination (below)
        SELECT workflow_request_id INTO v_req FROM offboarding.cases WHERE id = c_f;
        PERFORM pg_temp._as(v_hr2);
        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req;
        PERFORM workflow.process_approval_action(v_req, 'REJECT', v_step, 'rejected in test', NULL, v_k || 'rej', v_ver);
        PERFORM pg_temp._as(v_clr);
        PERFORM offboarding.record_clearance(c_e, 'ACCESS', 'access revoked', v_k || 'e-clr');
        SELECT status::text INTO v_s FROM offboarding.cases WHERE id = c_e;
        v_res := v_res || ARRAY['0c-fixture-states-submitted-approved-in-clearance|' || CASE WHEN v_s = 'IN_CLEARANCE'
            AND (SELECT status::text FROM offboarding.cases WHERE id = c_a) = 'SUBMITTED' AND (SELECT status::text FROM offboarding.cases WHERE id = c_b) = 'APPROVED'
            AND (SELECT status::text FROM offboarding.cases WHERE id = c_c) = 'SUBMITTED' AND (SELECT status::text FROM offboarding.cases WHERE id = c_d) = 'APPROVED'
            AND (SELECT status::text FROM offboarding.cases WHERE id = c_f) = 'REJECTED' THEN 'PASS' ELSE 'FAIL: e=' || v_s END];

        -- 1. validation and authentication (nothing may leave a sanction behind)
        PERFORM pg_temp._as(NULL);
        v_res := v_res || ARRAY['1a-unauthenticated-withdraw-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.withdraw_resignation(%L::uuid, %L, %L)', c_a, 'x', v_k || 'u1')), 'OFFBOARDING_UNAUTHENTICATED')];
        v_res := v_res || ARRAY['1b-unauthenticated-cancel-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.cancel_termination(%L::uuid, %L, %L)', c_c, 'x', v_k || 'u2')), 'OFFBOARDING_UNAUTHENTICATED')];
        PERFORM pg_temp._as(v_e1u);
        v_res := v_res || ARRAY['1c-blank-reason-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.withdraw_resignation(%L::uuid, %L, %L)', c_a, '   ', v_k || 'r1')), 'OFFBOARDING_REASON_REQUIRED')];
        v_res := v_res || ARRAY['1d-blank-idempotency-key-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.withdraw_resignation(%L::uuid, %L, %L)', c_a, 'x', '  ')), 'OFFBOARDING_IDEMPOTENCY_KEY_REQUIRED')];
        v_res := v_res || ARRAY['1e-unknown-case-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.withdraw_resignation(%L::uuid, %L, %L)', gen_random_uuid(), 'x', v_k || 'r2')), 'OFFBOARDING_CASE_NOT_FOUND')];

        -- 2. authorization and case type
        PERFORM pg_temp._as(v_oth);
        v_res := v_res || ARRAY['2a-unrelated-user-cannot-withdraw-someone-elses-resignation|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.withdraw_resignation(%L::uuid, %L, %L)', c_a, 'x', v_k || 'p1')), 'OFFBOARDING_NOT_AUTHORIZED')];
        PERFORM pg_temp._as(v_clr);
        v_res := v_res || ARRAY['2b-clearance-holder-without-manage-cannot-cancel-termination|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.cancel_termination(%L::uuid, %L, %L)', c_c, 'x', v_k || 'p2')), 'OFFBOARDING_NOT_AUTHORIZED')];
        PERFORM pg_temp._as(v_hr1);
        v_res := v_res || ARRAY['2c-withdraw-on-a-termination-is-the-wrong-case-type|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.withdraw_resignation(%L::uuid, %L, %L)', c_c, 'x', v_k || 'p3')), 'OFFBOARDING_WRONG_CASE_TYPE')];
        v_res := v_res || ARRAY['2d-cancel-on-a-resignation-is-the-wrong-case-type|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.cancel_termination(%L::uuid, %L, %L)', c_a, 'x', v_k || 'p4')), 'OFFBOARDING_WRONG_CASE_TYPE')];
        v_res := v_res || ARRAY['2e-rejected-case-not-cancellable|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.cancel_termination(%L::uuid, %L, %L)', c_f, 'x', v_k || 'p5')), 'OFFBOARDING_CASE_NOT_CANCELLABLE')];
        SELECT count(*) INTO v_n FROM offboarding._workflow_sanctions WHERE case_id IN (c_a, c_b, c_c, c_d, c_e, c_f);
        SELECT count(*) INTO v_n2 FROM offboarding.cases WHERE id IN (c_a, c_b, c_c, c_d, c_e, c_f) AND status IN ('WITHDRAWN', 'CANCELLED');
        SELECT count(*) INTO v_n3 FROM offboarding.request_idempotency WHERE idempotency_key LIKE v_k || 'p%' OR idempotency_key LIKE v_k || 'r%' OR idempotency_key LIKE v_k || 'u%';
        v_res := v_res || ARRAY['2f-every-rejected-call-left-no-sanction-no-case-change-no-key|' || CASE WHEN v_n = 0 AND v_n2 = 0 AND v_n3 = 0 THEN 'PASS' ELSE 'FAIL: sanctions=' || v_n || ' closed=' || v_n2 || ' keys=' || v_n3 END];

        -- 3. the employee withdraws their own SUBMITTED resignation: one sanction, one engine cancel, one transition
        PERFORM pg_temp._as(v_e1u);
        SELECT version INTO v_cv FROM offboarding.cases WHERE id = c_a;
        SELECT workflow_request_id INTO v_req FROM offboarding.cases WHERE id = c_a;
        v_r := offboarding.withdraw_resignation(c_a, 'found another arrangement', v_k || 'w1');
        v_res := v_res || ARRAY['3a-withdrawn-with-workflow-cancelled-and-version-bumped-once|' ||
            CASE WHEN v_r->>'case_status' = 'WITHDRAWN' AND (v_r->>'workflow_cancelled')::boolean AND (v_r->>'case_version')::int = v_cv + 1 AND v_r->>'idempotent_replay' = 'false' AND v_r->>'operation' = 'WITHDRAW_RESIGNATION'
                 THEN 'PASS' ELSE 'FAIL: ' || v_r::text END];
        SELECT count(*) INTO v_n FROM offboarding._workflow_sanctions WHERE case_id = c_a AND workflow_request_id = v_req AND operation = 'WITHDRAW_RESIGNATION' AND target_status = 'CANCELLED' AND authorized_by = v_e1u AND txid = txid_current();
        SELECT count(*) INTO v_n2 FROM offboarding._workflow_sanctions WHERE case_id = c_a;
        v_res := v_res || ARRAY['3b-exactly-one-sanction-bound-to-case-request-operation-and-actor|' || CASE WHEN v_n = 1 AND v_n2 = 1 THEN 'PASS' ELSE 'FAIL: matching=' || v_n || ' total=' || v_n2 END];
        SELECT (SELECT current_status FROM workflow.approval_requests WHERE id = v_req) || '|' || (SELECT is_open::text FROM workflow.approval_requests WHERE id = v_req)
               || '|' || (SELECT count(*) FROM workflow.approval_actions WHERE approval_request_id = v_req AND action = 'CANCEL' AND actor_type = 'SYSTEM') INTO v_s;
        v_res := v_res || ARRAY['3c-workflow-request-cancelled-and-closed-by-exactly-one-system-action|' || CASE WHEN v_s LIKE 'CANCELLED|false|1' THEN 'PASS' ELSE 'FAIL: ' || v_s END];
        SELECT withdrawn_by::text || '|' || withdrawal_reason INTO v_s FROM offboarding.cases WHERE id = c_a;
        SELECT count(*) INTO v_n FROM offboarding.case_history WHERE case_id = c_a AND event_type = 'WITHDRAWN' AND from_status = 'SUBMITTED' AND to_status = 'WITHDRAWN' AND actor = v_e1u
            AND detail->>'reason' = 'found another arrangement' AND (detail->>'workflow_cancelled')::boolean;
        v_res := v_res || ARRAY['3d-case-and-history-record-actor-reason-and-workflow-flag|' || CASE WHEN v_s = v_e1u::text || '|found another arrangement' AND v_n = 1 THEN 'PASS' ELSE 'FAIL: ' || v_s || ' events=' || v_n END];

        -- 4. replay, mismatch, terminal
        SELECT version INTO v_cv FROM offboarding.cases WHERE id = c_a;
        SELECT count(*) INTO v_hist FROM offboarding.case_history WHERE case_id = c_a;
        v_r2 := offboarding.withdraw_resignation(c_a, 'found another arrangement', v_k || 'w1');
        SELECT count(*) INTO v_n FROM offboarding._workflow_sanctions WHERE case_id = c_a;
        SELECT count(*) INTO v_n2 FROM workflow.approval_actions WHERE approval_request_id = v_req AND action = 'CANCEL';
        v_res := v_res || ARRAY['4a-replay-returns-identical-result|' || CASE WHEN (v_r - 'idempotent_replay') = (v_r2 - 'idempotent_replay') AND v_r2->>'idempotent_replay' = 'true' THEN 'PASS' ELSE 'FAIL: ' || v_r2::text END];
        v_res := v_res || ARRAY['4b-replay-adds-no-sanction-no-engine-cancel-no-history-no-version-bump|' ||
            CASE WHEN v_n = 1 AND v_n2 = 1 AND (SELECT version FROM offboarding.cases WHERE id = c_a) = v_cv AND (SELECT count(*) FROM offboarding.case_history WHERE case_id = c_a) = v_hist THEN 'PASS'
                 ELSE 'FAIL: sanctions=' || v_n || ' cancels=' || v_n2 END];
        v_res := v_res || ARRAY['4c-same-key-different-reason-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.withdraw_resignation(%L::uuid, %L, %L)', c_a, 'a different reason', v_k || 'w1')), 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH')];
        v_res := v_res || ARRAY['4d-new-key-on-a-withdrawn-case-rejected-as-final|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.withdraw_resignation(%L::uuid, %L, %L)', c_a, 'again', v_k || 'w1b')), 'OFFBOARDING_CASE_NOT_CANCELLABLE')];
        v_res := v_res || ARRAY['4e-terminal-case-cannot-be-updated-afterwards|' || pg_temp._expect(pg_temp._err(format('UPDATE offboarding.cases SET reason_detail = %L WHERE id = %L', 'tamper', c_a)), 'OFFBOARDING_TERMINAL_STATUS')];
        SELECT count(*) INTO v_n FROM offboarding._workflow_sanctions WHERE case_id = c_a;
        v_res := v_res || ARRAY['4f-rejected-calls-left-no-extra-sanction|' || CASE WHEN v_n = 1 THEN 'PASS' ELSE 'FAIL: ' || v_n END];

        -- 5. HR (OFFBOARDING_MANAGE) withdraws an APPROVED resignation: workflow already closed -> no sanction, no engine call
        PERFORM pg_temp._as(v_hr1);
        SELECT workflow_request_id INTO v_req FROM offboarding.cases WHERE id = c_b;
        SELECT count(*) INTO v_n FROM workflow.approval_actions WHERE approval_request_id = v_req;
        v_r := offboarding.withdraw_resignation(c_b, 'employee asked HR to withdraw', v_k || 'w2');
        SELECT count(*) INTO v_n2 FROM workflow.approval_actions WHERE approval_request_id = v_req;
        SELECT count(*) INTO v_n3 FROM offboarding._workflow_sanctions WHERE case_id = c_b;
        v_res := v_res || ARRAY['5a-manager-withdraws-an-approved-resignation-without-touching-the-closed-workflow|' ||
            CASE WHEN v_r->>'case_status' = 'WITHDRAWN' AND NOT (v_r->>'workflow_cancelled')::boolean AND v_n = v_n2 AND v_n3 = 0 THEN 'PASS' ELSE 'FAIL: ' || v_r::text || ' actions ' || v_n || '->' || v_n2 || ' sanctions=' || v_n3 END];
        SELECT count(*) INTO v_n FROM offboarding.case_history WHERE case_id = c_b AND event_type = 'WITHDRAWN' AND from_status = 'APPROVED' AND actor = v_hr1 AND NOT (detail->>'workflow_cancelled')::boolean;
        v_res := v_res || ARRAY['5b-history-shows-from-approved-by-the-manager|' || CASE WHEN v_n = 1 THEN 'PASS' ELSE 'FAIL: ' || v_n END];
        v_r2 := offboarding.withdraw_resignation(c_b, 'employee asked HR to withdraw', v_k || 'w2');
        v_res := v_res || ARRAY['5c-replay-identical-including-workflow-flag|' || CASE WHEN (v_r - 'idempotent_replay') = (v_r2 - 'idempotent_replay') AND v_r2->>'idempotent_replay' = 'true' THEN 'PASS' ELSE 'FAIL: ' || v_r2::text END];

        -- 6. termination cancellation, SUBMITTED: sanction + engine cancel; authorized_by is the actor
        SELECT workflow_request_id INTO v_req FROM offboarding.cases WHERE id = c_c;
        SELECT version INTO v_cv FROM offboarding.cases WHERE id = c_c;
        v_r := offboarding.cancel_termination(c_c, 'decision reversed by the board', v_k || 'c1');
        v_res := v_res || ARRAY['6a-submitted-termination-cancelled-with-workflow-cancelled|' ||
            CASE WHEN v_r->>'case_status' = 'CANCELLED' AND (v_r->>'workflow_cancelled')::boolean AND (v_r->>'case_version')::int = v_cv + 1 AND v_r->>'operation' = 'CANCEL_TERMINATION' THEN 'PASS' ELSE 'FAIL: ' || v_r::text END];
        SELECT count(*) INTO v_n FROM offboarding._workflow_sanctions WHERE case_id = c_c AND workflow_request_id = v_req AND operation = 'CANCEL_TERMINATION' AND authorized_by = v_hr1 AND txid = txid_current();
        SELECT cancelled_by::text || '|' || cancellation_reason INTO v_s FROM offboarding.cases WHERE id = c_c;
        v_res := v_res || ARRAY['6b-one-sanction-with-actor-and-case-records-cancelled-by-and-reason|' || CASE WHEN v_n = 1 AND v_s = v_hr1::text || '|decision reversed by the board' THEN 'PASS' ELSE 'FAIL: ' || v_n || ' ' || v_s END];
        SELECT (SELECT current_status FROM workflow.approval_requests WHERE id = v_req) || '|' || (SELECT is_open::text FROM workflow.approval_requests WHERE id = v_req) INTO v_s;
        v_res := v_res || ARRAY['6c-workflow-request-cancelled-and-closed|' || CASE WHEN v_s = 'CANCELLED|false' THEN 'PASS' ELSE 'FAIL: ' || v_s END];
        SELECT version INTO v_cv FROM offboarding.cases WHERE id = c_c;
        v_r2 := offboarding.cancel_termination(c_c, 'decision reversed by the board', v_k || 'c1');
        SELECT count(*) INTO v_n FROM offboarding._workflow_sanctions WHERE case_id = c_c;
        v_res := v_res || ARRAY['6d-replay-identical-and-no-new-sanction-or-version|' ||
            CASE WHEN (v_r - 'idempotent_replay') = (v_r2 - 'idempotent_replay') AND v_r2->>'idempotent_replay' = 'true' AND v_n = 1 AND (SELECT version FROM offboarding.cases WHERE id = c_c) = v_cv THEN 'PASS' ELSE 'FAIL: ' || v_r2::text || ' sanctions=' || v_n END];
        v_res := v_res || ARRAY['6e-same-key-different-reason-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.cancel_termination(%L::uuid, %L, %L)', c_c, 'other reason', v_k || 'c1')), 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH')];

        -- 7. APPROVED and IN_CLEARANCE terminations: no sanction, no engine call; clearance tasks are left as they were
        SELECT workflow_request_id INTO v_req FROM offboarding.cases WHERE id = c_d;
        SELECT count(*) INTO v_n FROM workflow.approval_actions WHERE approval_request_id = v_req;
        v_r := offboarding.cancel_termination(c_d, 'cancelled after approval', v_k || 'c2');
        SELECT count(*) INTO v_n2 FROM workflow.approval_actions WHERE approval_request_id = v_req;
        SELECT count(*) INTO v_n3 FROM offboarding._workflow_sanctions WHERE case_id = c_d;
        v_res := v_res || ARRAY['7a-approved-termination-cancelled-without-sanction-or-engine-call|' ||
            CASE WHEN v_r->>'case_status' = 'CANCELLED' AND NOT (v_r->>'workflow_cancelled')::boolean AND v_n = v_n2 AND v_n3 = 0 THEN 'PASS' ELSE 'FAIL: ' || v_r::text END];
        v_r := offboarding.cancel_termination(c_e, 'cancelled during clearance', v_k || 'c3');
        SELECT count(*) INTO v_n FROM offboarding.clearance_tasks WHERE case_id = c_e AND status = 'PENDING';
        SELECT count(*) INTO v_n2 FROM offboarding.clearance_tasks WHERE case_id = c_e AND status = 'CLEARED';
        SELECT count(*) INTO v_n3 FROM offboarding._workflow_sanctions WHERE case_id = c_e;
        v_res := v_res || ARRAY['7b-in-clearance-termination-cancelled-tasks-left-as-they-were|' ||
            CASE WHEN v_r->>'case_status' = 'CANCELLED' AND NOT (v_r->>'workflow_cancelled')::boolean AND v_n = 4 AND v_n2 = 1 AND v_n3 = 0
                      AND (SELECT count(*) FROM offboarding.case_history WHERE case_id = c_e AND event_type = 'CANCELLED' AND from_status = 'IN_CLEARANCE') = 1 THEN 'PASS' ELSE 'FAIL: ' || v_r::text || ' pending=' || v_n || ' cleared=' || v_n2 END];
        PERFORM pg_temp._as(v_clr);
        v_res := v_res || ARRAY['7c-clearance-on-a-cancelled-case-is-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_e, 'HR', 'x', v_k || 'c4')), 'OFFBOARDING_CASE_NOT_IN_CLEARANCE_STAGE')];

        RAISE EXCEPTION 'OFF007_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'OFF007_ROLLBACK' THEN v_res := v_res || ARRAY['9-main-block|FAIL: ' || SQLSTATE || ' ' || SQLERRM]; END IF;
    END;

    INSERT INTO "_off007_results" SELECT split_part(x, '|', 1), substr(x, strpos(x, '|') + 1) FROM unnest(v_res) AS x;
END;
$$;

DO $$
DECLARE v_fail int; v_total int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE result <> 'PASS'), count(*),
           string_agg(step || ' = ' || result, ' | ' ORDER BY step) FILTER (WHERE result <> 'PASS')
      INTO v_fail, v_total, v_list FROM "_off007_results";
    IF v_total = 0 THEN RAISE EXCEPTION 'OFFBOARDING 007 TEST: no results recorded'; END IF;
    IF v_fail > 0 THEN RAISE EXCEPTION 'OFFBOARDING 007 TEST FAILED (% of % checks): %', v_fail, v_total, v_list; END IF;
    RAISE NOTICE 'OFFBOARDING 007 TEST PASSED: % checks, 0 failures', v_total;
END;
$$;

SELECT step, result FROM "_off007_results" ORDER BY step;
-- ========================================================================
-- END TEST_offboarding_007_withdraw_cancel.sql
-- ========================================================================
