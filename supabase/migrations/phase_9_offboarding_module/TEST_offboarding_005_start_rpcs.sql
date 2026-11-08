-- ========================================================================
-- TEST_offboarding_005_start_rpcs.sql
-- Run AFTER 001-005 and after RUN_seed_offboarding_workflow_definitions.sql (Track B only).
-- Everything (temporary role, people, employees, links, cases, workflow requests) lives in ONE rolled-back
-- sub-block: nothing persists. Fixture users: existing test accounts ...a5, ...a6, ...a7, ...a9 plus the first
-- WORKFLOW_CONFIG_MANAGE admin (acts as HR1). Gate: any FAIL raises; all PASS completes with a notice.
-- Also proves: workflow CANCEL needs a transaction-bound Offboarding sanction (none / stale / other case / other
-- request / wrong operation all rejected, exact message asserted); a normal user cannot start an Offboarding
-- workflow request directly (engine grants + real attempt as authenticated); the 200/201 idempotency key boundary.
-- NOT covered here (separate scripts): real two-session concurrency, clearance/withdraw/cancel/complete (006-008).
-- ========================================================================
DROP TABLE IF EXISTS "_off005_results";
CREATE TEMP TABLE "_off005_results" ("step" text, "result" text);

CREATE FUNCTION pg_temp._as(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
END;
$f$;
CREATE FUNCTION pg_temp._err(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END;
$f$;
CREATE FUNCTION pg_temp._expect(p_err text, p_prefix text) RETURNS text LANGUAGE sql AS $f$
    SELECT CASE WHEN p_err IS NULL THEN 'FAIL: no error raised'
                WHEN p_err LIKE p_prefix || '%' THEN 'PASS'
                ELSE 'FAIL: ' || p_err END
$f$;

DO $$
DECLARE
    v_res text[] := ARRAY[]::text[];
    v_run text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    v_k text := 'off005-' || substr(md5(random()::text), 1, 6) || '-';
    v_org uuid; v_hr1 uuid; v_perm uuid; v_role uuid; v_p uuid;
    v_hr2 uuid := '00000000-0000-0000-0000-0000000000a6';
    v_e1u uuid := '00000000-0000-0000-0000-0000000000a5';
    v_e2u uuid := '00000000-0000-0000-0000-0000000000a7';
    v_un  uuid := '00000000-0000-0000-0000-0000000000a9';
    v_emp1 uuid; v_emp2 uuid; v_emp3 uuid; v_emp4 uuid; v_emp5 uuid; v_emp6 uuid;
    v_case6 uuid; v_case7 uuid; v_req6 uuid; v_req7 uuid; v_key200 text; v_def_id uuid; v_cnt int;
    v_r jsonb; v_r2 jsonb; v_case1 uuid; v_case2 uuid; v_case3 uuid; v_case5 uuid;
    v_req1 uuid; v_req2 uuid; v_req3 uuid; v_req5 uuid; v_step uuid;
    v_ver int; v_err text; v_n int; v_n2 int; v_s text; v_arr text[]; v_def text; v_wf1 bigint; v_wf2 bigint;
    v_sig text; v_oid oid;
BEGIN
    SELECT id INTO v_org FROM core.organizations WHERE code = 'OSYSTIC';
    SELECT id INTO v_hr1 FROM auth.users WHERE core.has_permission(id, 'WORKFLOW_CONFIG_MANAGE') AND id NOT IN (v_hr2, v_e1u, v_e2u, v_un) ORDER BY created_at LIMIT 1;
    SELECT id INTO v_perm FROM core.permissions WHERE code = 'OFFBOARDING_MANAGE';
    IF v_org IS NULL OR v_hr1 IS NULL OR v_perm IS NULL THEN RAISE EXCEPTION 'SETUP: org=%, hr1=%, permission=%', v_org, v_hr1, v_perm; END IF;
    IF (SELECT count(*) FROM auth.users WHERE id IN (v_hr2, v_e1u, v_e2u, v_un)) <> 4 THEN RAISE EXCEPTION 'SETUP: fixture users a5/a6/a7/a9 are missing'; END IF;
    IF (SELECT count(*) FROM workflow.workflow_definitions d JOIN workflow.workflow_versions v ON v.workflow_definition_id = d.id
         WHERE d.module = 'offboarding' AND v.status = 'ACTIVE') <> 2 THEN
        RAISE EXCEPTION 'SETUP: the two Offboarding workflow definitions are not ACTIVE - run RUN_seed_offboarding_workflow_definitions.sql first'; END IF;

    ------------------------------------------------------------ 0. static privilege and shape checks
    FOREACH v_sig IN ARRAY ARRAY[
        'offboarding.start_resignation(character varying,date,character varying,text)',
        'offboarding.start_resignation_on_behalf(uuid,character varying,date,character varying,text)',
        'offboarding.start_termination(uuid,character varying,date,character varying,text)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        v_s := CASE WHEN v_oid IS NOT NULL AND has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
                     AND (SELECT prosecdef FROM pg_proc WHERE oid = v_oid)
                     AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))
                    THEN 'PASS' ELSE 'FAIL: ' || v_sig END;
        v_res := v_res || ARRAY['0a-' || split_part(split_part(v_sig, '(', 1), '.', 2) || '-executable-by-authenticated-only|' || v_s];
    END LOOP;
    v_res := v_res || ARRAY['0b-internal-functions-closed-to-app-roles|' ||
        CASE WHEN NOT has_function_privilege('authenticated', to_regprocedure('offboarding._start_case(uuid,uuid,text,character varying,character varying,date,character varying,text,boolean)')::oid, 'EXECUTE')
              AND NOT has_function_privilege('authenticated', to_regprocedure('offboarding._on_workflow_status_change()')::oid, 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END];

    -- direct workflow START is closed by the shared engine itself: documented AND tested, not assumed
    v_oid := to_regprocedure('workflow.start_approval_request(uuid,character varying,uuid,jsonb,character varying)')::oid;
    v_res := v_res || ARRAY['0c-engine-start-not-executable-by-authenticated-anon-or-public|' ||
        CASE WHEN v_oid IS NOT NULL AND NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
              AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))
             THEN 'PASS' ELSE 'FAIL' END];
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_s FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'workflow' AND p.prosrc ILIKE '%insert into "workflow"."approval_requests"%'
       AND (has_function_privilege('authenticated', p.oid, 'EXECUTE') OR has_function_privilege('anon', p.oid, 'EXECUTE'));
    v_res := v_res || ARRAY['0d-no-app-executable-function-creates-approval-requests|' || CASE WHEN v_s IS NULL THEN 'PASS' ELSE 'FAIL: ' || v_s END];
    v_res := v_res || ARRAY['0e-engine-system-cancel-not-executable-by-app-roles|' ||
        CASE WHEN NOT has_function_privilege('authenticated', to_regprocedure('workflow.process_system_action(uuid,workflow.approval_action_type,uuid,text,jsonb,character varying,integer)')::oid, 'EXECUTE')
              AND NOT has_function_privilege('anon', to_regprocedure('workflow.process_system_action(uuid,workflow.approval_action_type,uuid,text,jsonb,character varying,integer)')::oid, 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END];
    v_res := v_res || ARRAY['0f-sanction-table-closed-to-app-roles-and-rls-on|' ||
        CASE WHEN to_regclass('offboarding._workflow_sanctions') IS NOT NULL
              AND NOT has_table_privilege('authenticated', 'offboarding._workflow_sanctions', 'INSERT') AND NOT has_table_privilege('authenticated', 'offboarding._workflow_sanctions', 'SELECT')
              AND NOT has_table_privilege('anon', 'offboarding._workflow_sanctions', 'INSERT')
              AND EXISTS (SELECT 1 FROM pg_class WHERE oid = 'offboarding._workflow_sanctions'::regclass AND relrowsecurity) THEN 'PASS' ELSE 'FAIL' END];

    BEGIN
        PERFORM pg_temp._as(v_hr1);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_TEST_OFF005_' || v_run, 'temp off005', 'temporary, rolled back') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) VALUES (v_role, v_perm);
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_hr1, v_role), (v_hr2, v_role);

        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF005 E1', 'off005-e1-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO core.person_user_links (person_id, user_id) VALUES (v_p, v_e1u);
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF005-1-' || v_run, current_date - 400) RETURNING id INTO v_emp1;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF005 E2', 'off005-e2-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO core.person_user_links (person_id, user_id) VALUES (v_p, v_e2u);
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF005-2-' || v_run, current_date - 400) RETURNING id INTO v_emp2;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF005 E3', 'off005-e3-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF005-3-' || v_run, current_date - 400) RETURNING id INTO v_emp3;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF005 E4 (HR2)', 'off005-e4-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO core.person_user_links (person_id, user_id) VALUES (v_p, v_hr2);
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF005-4-' || v_run, current_date - 400) RETURNING id INTO v_emp4;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF005 E5', 'off005-e5-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF005-5-' || v_run, current_date - 400) RETURNING id INTO v_emp5;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF005 E6', 'off005-e6-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF005-6-' || v_run, current_date - 400) RETURNING id INTO v_emp6;

        ------------------------------------------------------------ 1. authentication and authorization
        PERFORM pg_temp._as(NULL);
        v_res := v_res || ARRAY['1a-unauthenticated-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_resignation(%L, %L::date, %L, %L)', v_k || 'x1', current_date + 30, 'PERSONAL', 'x')), 'OFFBOARDING_UNAUTHENTICATED')];
        PERFORM pg_temp._as(v_un);
        v_res := v_res || ARRAY['1b-self-service-without-employee-link-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_resignation(%L, %L::date, %L, %L)', v_k || 'x2', current_date + 30, 'PERSONAL', 'x')), 'OFFBOARDING_NO_ACTIVE_EMPLOYEE_FOR_USER')];
        v_res := v_res || ARRAY['1c-on-behalf-without-manage-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_resignation_on_behalf(%L::uuid, %L, %L::date, %L, %L)', v_emp2, v_k || 'x3', current_date + 30, 'CAREER', 'x')), 'OFFBOARDING_NOT_AUTHORIZED')];
        v_res := v_res || ARRAY['1d-termination-without-manage-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_termination(%L::uuid, %L, %L::date, %L, %L)', v_emp3, v_k || 'x4', current_date + 30, 'CONDUCT', 'x')), 'OFFBOARDING_NOT_AUTHORIZED')];

        ------------------------------------------------------------ 2. self-service resignation: employee derived from auth.uid()
        PERFORM pg_temp._as(v_e1u);
        SELECT count(*) INTO v_wf1 FROM workflow.approval_requests;
        v_r := offboarding.start_resignation(v_k || 'res1', current_date + 30, 'personal', '  moving on  ');
        v_case1 := (v_r->>'case_id')::uuid;
        v_req1  := (v_r->>'workflow_request_id')::uuid;
        SELECT hr_employee_id::text || '|' || status::text || '|' || case_type::text || '|' || on_behalf::text || '|' || initiated_by::text || '|' || version::text || '|' || reason_category || '|' || coalesce(reason_detail, '')
          INTO v_s FROM offboarding.cases WHERE id = v_case1;
        v_res := v_res || ARRAY['2a-self-service-derives-employee-and-creates-submitted-case|' ||
            CASE WHEN v_s = v_emp1::text || '|SUBMITTED|RESIGNATION|false|' || v_e1u::text || '|1|PERSONAL|moving on' AND (v_r->>'idempotent_replay') = 'false' THEN 'PASS' ELSE 'FAIL: ' || coalesce(v_s, 'no row') END];
        SELECT array_agg(domain::text ORDER BY domain::text), count(*) FILTER (WHERE status = 'PENDING') INTO v_arr, v_n FROM offboarding.clearance_tasks WHERE case_id = v_case1;
        v_res := v_res || ARRAY['2b-exactly-five-tasks-one-per-domain-all-pending|' ||
            CASE WHEN v_arr = ARRAY['ACCESS','ASSETS','FINANCE','HANDOVER','HR'] AND v_n = 5 THEN 'PASS' ELSE 'FAIL: ' || coalesce(v_arr::text, 'none') || ' pending=' || v_n END];
        SELECT d.code, r.current_status INTO v_def, v_s FROM workflow.approval_requests r JOIN workflow.workflow_definitions d ON d.id = r.workflow_definition_id WHERE r.id = v_req1;
        v_res := v_res || ARRAY['2c-resignation-uses-the-resignation-definition-and-starts-pending|' || CASE WHEN v_def = 'OFFBOARDING_RESIGNATION_APPROVAL' AND v_s = 'PENDING' THEN 'PASS' ELSE 'FAIL: ' || coalesce(v_def, '?') || '/' || coalesce(v_s, '?') END];
        SELECT count(*) INTO v_n FROM offboarding.case_history WHERE case_id = v_case1;
        SELECT count(*) INTO v_n2 FROM offboarding.case_history WHERE case_id = v_case1 AND event_type = 'SUBMITTED' AND detail::text NOT LIKE '%moving on%';
        v_res := v_res || ARRAY['2d-one-submitted-history-event-without-reason-detail|' || CASE WHEN v_n = 1 AND v_n2 = 1 THEN 'PASS' ELSE 'FAIL: events=' || v_n || ' clean=' || v_n2 END];

        ------------------------------------------------------------ 3. replay: fresh-vs-replay equality, nothing changes
        v_r2 := offboarding.start_resignation(v_k || 'res1', current_date + 30, 'personal', '  moving on  ');
        SELECT count(*) INTO v_wf2 FROM workflow.approval_requests;
        SELECT version INTO v_ver FROM offboarding.cases WHERE id = v_case1;
        v_res := v_res || ARRAY['3a-replay-returns-identical-result|' || CASE WHEN (v_r - 'idempotent_replay') = (v_r2 - 'idempotent_replay') AND (v_r2->>'idempotent_replay') = 'true' THEN 'PASS' ELSE 'FAIL: ' || v_r::text || ' vs ' || v_r2::text END];
        SELECT count(*) INTO v_n FROM offboarding.cases WHERE hr_employee_id = v_emp1;
        SELECT count(*) INTO v_n2 FROM offboarding.clearance_tasks WHERE case_id = v_case1;
        v_res := v_res || ARRAY['3b-replay-creates-nothing-and-keeps-version|' ||
            CASE WHEN v_n = 1 AND v_n2 = 5 AND v_ver = 1 AND v_wf2 = v_wf1 + 1 AND (SELECT count(*) FROM offboarding.case_history WHERE case_id = v_case1) = 1 THEN 'PASS'
                 ELSE 'FAIL: cases=' || v_n || ' tasks=' || v_n2 || ' version=' || v_ver || ' wf_requests_delta=' || (v_wf2 - v_wf1) END];

        ------------------------------------------------------------ 4. payload mismatch and open-case rule (state unchanged)
        v_res := v_res || ARRAY['4a-same-key-different-payload-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_resignation(%L, %L::date, %L, %L)', v_k || 'res1', current_date + 45, 'personal', 'moving on')), 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH')];
        v_res := v_res || ARRAY['4b-second-open-case-for-same-employee-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_resignation(%L, %L::date, %L, %L)', v_k || 'res1b', current_date + 30, 'PERSONAL', 'again')), 'OFFBOARDING_OPEN_CASE_EXISTS')];
        SELECT count(*) INTO v_n FROM offboarding.cases WHERE hr_employee_id = v_emp1;
        SELECT count(*) INTO v_wf2 FROM workflow.approval_requests;
        v_res := v_res || ARRAY['4c-rejected-calls-changed-nothing|' || CASE WHEN v_n = 1 AND v_wf2 = v_wf1 + 1 AND (SELECT version FROM offboarding.cases WHERE id = v_case1) = 1 THEN 'PASS' ELSE 'FAIL: cases=' || v_n || ' wf_delta=' || (v_wf2 - v_wf1) END];

        ------------------------------------------------------------ 5. input validation (HR1 / HR2)
        PERFORM pg_temp._as(v_hr1);
        v_res := v_res || ARRAY['5a-termination-requires-reason-detail|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_termination(%L::uuid, %L, %L::date, %L, NULL)', v_emp3, v_k || 'v1', current_date + 30, 'CONDUCT')), 'OFFBOARDING_REASON_DETAIL_REQUIRED')];
        v_res := v_res || ARRAY['5b-termination-category-must-be-a-termination-category|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_termination(%L::uuid, %L, %L::date, %L, %L)', v_emp3, v_k || 'v2', current_date + 30, 'PERSONAL', 'x')), 'OFFBOARDING_INVALID_REASON_CATEGORY')];
        v_res := v_res || ARRAY['5c-resignation-category-must-be-a-resignation-category|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_resignation_on_behalf(%L::uuid, %L, %L::date, %L, %L)', v_emp3, v_k || 'v3', current_date + 30, 'CONDUCT', 'x')), 'OFFBOARDING_INVALID_REASON_CATEGORY')];
        v_res := v_res || ARRAY['5d-last-working-date-in-the-past-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_termination(%L::uuid, %L, %L::date, %L, %L)', v_emp3, v_k || 'v4', current_date - 1, 'CONDUCT', 'x')), 'OFFBOARDING_LAST_WORKING_DATE_IN_PAST')];
        v_res := v_res || ARRAY['5e-last-working-date-required|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_termination(%L::uuid, %L, NULL::date, %L, %L)', v_emp3, v_k || 'v5', 'CONDUCT', 'x')), 'OFFBOARDING_LAST_WORKING_DATE_REQUIRED')];
        v_res := v_res || ARRAY['5f-blank-idempotency-key-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_termination(%L::uuid, %L, %L::date, %L, %L)', v_emp3, '   ', current_date + 30, 'CONDUCT', 'x')), 'OFFBOARDING_IDEMPOTENCY_KEY_REQUIRED')];
        v_res := v_res || ARRAY['5g-unknown-employee-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_termination(%L::uuid, %L, %L::date, %L, %L)', gen_random_uuid(), v_k || 'v6', current_date + 30, 'CONDUCT', 'x')), 'OFFBOARDING_EMPLOYEE_NOT_FOUND')];
        PERFORM pg_temp._as(v_hr2);
        v_res := v_res || ARRAY['5h-cannot-terminate-yourself|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_termination(%L::uuid, %L, %L::date, %L, %L)', v_emp4, v_k || 'v7', current_date + 30, 'CONDUCT', 'x')), 'OFFBOARDING_CANNOT_TERMINATE_SELF')];
        v_res := v_res || ARRAY['5i-on-behalf-for-yourself-must-use-self-service|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_resignation_on_behalf(%L::uuid, %L, %L::date, %L, %L)', v_emp4, v_k || 'v8', current_date + 30, 'CAREER', 'x')), 'OFFBOARDING_USE_SELF_SERVICE')];

        ------------------------------------------------------------ 6. HR on behalf (resignation) and termination
        PERFORM pg_temp._as(v_hr1);
        v_r := offboarding.start_resignation_on_behalf(v_emp2, v_k || 'ob1', current_date + 20, 'CAREER', 'entered by HR');
        v_case2 := (v_r->>'case_id')::uuid; v_req2 := (v_r->>'workflow_request_id')::uuid;
        SELECT on_behalf::text || '|' || initiated_by::text || '|' || version::text || '|' || status::text INTO v_s FROM offboarding.cases WHERE id = v_case2;
        SELECT count(*) INTO v_n FROM offboarding.clearance_tasks WHERE case_id = v_case2;
        SELECT d.code INTO v_def FROM workflow.approval_requests r JOIN workflow.workflow_definitions d ON d.id = r.workflow_definition_id WHERE r.id = v_req2;
        v_res := v_res || ARRAY['6a-hr-on-behalf-resignation-recorded|' || CASE WHEN v_s = 'true|' || v_hr1::text || '|1|SUBMITTED' AND v_n = 5 AND v_def = 'OFFBOARDING_RESIGNATION_APPROVAL' THEN 'PASS' ELSE 'FAIL: ' || v_s || ' tasks=' || v_n || ' def=' || coalesce(v_def, '?') END];

        v_r := offboarding.start_termination(v_emp3, v_k || 'term1', current_date + 10, 'conduct', 'sensitive termination detail');
        v_case3 := (v_r->>'case_id')::uuid; v_req3 := (v_r->>'workflow_request_id')::uuid;
        SELECT case_type::text || '|' || on_behalf::text || '|' || initiated_by::text || '|' || version::text || '|' || status::text || '|' || reason_detail INTO v_s FROM offboarding.cases WHERE id = v_case3;
        SELECT count(*) INTO v_n FROM offboarding.clearance_tasks WHERE case_id = v_case3;
        SELECT d.code INTO v_def FROM workflow.approval_requests r JOIN workflow.workflow_definitions d ON d.id = r.workflow_definition_id WHERE r.id = v_req3;
        SELECT count(*) INTO v_n2 FROM offboarding.case_history WHERE case_id = v_case3 AND detail::text LIKE '%sensitive%';
        v_res := v_res || ARRAY['6b-termination-recorded-with-five-tasks-and-its-own-definition|' ||
            CASE WHEN v_s = 'TERMINATION|false|' || v_hr1::text || '|1|SUBMITTED|sensitive termination detail' AND v_n = 5 AND v_def = 'OFFBOARDING_TERMINATION_APPROVAL' THEN 'PASS' ELSE 'FAIL: ' || v_s || ' tasks=' || v_n || ' def=' || coalesce(v_def, '?') END];
        v_res := v_res || ARRAY['6c-termination-reason-detail-not-copied-into-history|' || CASE WHEN v_n2 = 0 THEN 'PASS' ELSE 'FAIL: leaked into ' || v_n2 || ' history row(s)' END];

        ------------------------------------------------------------ 7. maker-checker and approval synchronisation
        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req3 AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req3;
        v_err := pg_temp._err(format('SELECT workflow.process_approval_action(%L::uuid, ''APPROVE'', %L::uuid, ''self approval'', NULL, %L, %s)', v_req3, v_step, v_k || 'selfappr', v_ver));
        v_res := v_res || ARRAY['7a-initiator-cannot-approve-own-termination|' ||
            CASE WHEN v_err IS NOT NULL AND (SELECT status::text FROM offboarding.cases WHERE id = v_case3) = 'SUBMITTED'
                      AND (SELECT current_status FROM workflow.approval_requests WHERE id = v_req3) = 'PENDING' THEN 'PASS' ELSE 'FAIL: err=' || coalesce(v_err, 'none') END];
        PERFORM pg_temp._as(v_hr2);
        PERFORM workflow.process_approval_action(v_req3, 'APPROVE', v_step, 'approved by second manager', NULL, v_k || 'appr3', v_ver);
        SELECT status::text || '|' || (approved_at IS NOT NULL)::text || '|' || version::text INTO v_s FROM offboarding.cases WHERE id = v_case3;
        SELECT count(*) INTO v_n FROM offboarding.case_history WHERE case_id = v_case3;
        SELECT count(*) INTO v_n2 FROM offboarding.clearance_tasks WHERE case_id = v_case3 AND status = 'PENDING';
        v_res := v_res || ARRAY['7b-approval-by-a-different-manager-moves-case-to-approved-once|' ||
            CASE WHEN v_s = 'APPROVED|true|2' AND v_n = 2 AND v_n2 = 5 THEN 'PASS' ELSE 'FAIL: ' || v_s || ' history=' || v_n || ' pending_tasks=' || v_n2 END];

        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req1 AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req1;
        PERFORM workflow.process_approval_action(v_req1, 'APPROVE', v_step, 'approve resignation', NULL, v_k || 'appr1', v_ver);
        v_res := v_res || ARRAY['7c-self-service-resignation-approved|' || CASE WHEN (SELECT status::text FROM offboarding.cases WHERE id = v_case1) = 'APPROVED' THEN 'PASS' ELSE 'FAIL' END];

        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req2 AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req2;
        PERFORM workflow.process_approval_action(v_req2, 'REJECT', v_step, 'rejected in test', NULL, v_k || 'rej2', v_ver);
        SELECT status::text || '|' || version::text INTO v_s FROM offboarding.cases WHERE id = v_case2;
        v_res := v_res || ARRAY['7d-rejection-moves-case-to-rejected-once|' || CASE WHEN v_s = 'REJECTED|2' THEN 'PASS' ELSE 'FAIL: ' || v_s END];
        v_res := v_res || ARRAY['7e-rejected-case-is-final|' || pg_temp._expect(pg_temp._err(format('UPDATE offboarding.cases SET reason_detail = ''x'' WHERE id = %L', v_case2)), 'OFFBOARDING_TERMINAL_STATUS')];

        ------------------------------------------------------------ 8. new case after a rejected one; 200/201 idempotency key boundary
        PERFORM pg_temp._as(v_hr1);
        v_r := offboarding.start_resignation_on_behalf(v_emp2, v_k || 'ob2', current_date + 20, 'OTHER', 'second attempt');
        v_case5 := (v_r->>'case_id')::uuid; v_req5 := (v_r->>'workflow_request_id')::uuid;
        v_res := v_res || ARRAY['8a-new-case-allowed-after-a-rejected-one|' || CASE WHEN (SELECT status::text FROM offboarding.cases WHERE id = v_case5) = 'SUBMITTED' THEN 'PASS' ELSE 'FAIL' END];

        v_key200 := substr(v_run || repeat('k', 200), 1, 200);
        v_r := offboarding.start_resignation_on_behalf(v_emp5, v_key200, current_date + 20, 'OTHER', 'boundary test');
        v_case6 := (v_r->>'case_id')::uuid; v_req6 := (v_r->>'workflow_request_id')::uuid;
        v_res := v_res || ARRAY['8b-idempotency-key-of-exactly-200-characters-accepted-end-to-end|' ||
            CASE WHEN length(v_key200) = 200 AND (SELECT status::text FROM offboarding.cases WHERE id = v_case6) = 'SUBMITTED'
                      AND (SELECT current_status FROM workflow.approval_requests WHERE id = v_req6) = 'PENDING' THEN 'PASS' ELSE 'FAIL: len=' || length(v_key200) END];
        v_res := v_res || ARRAY['8c-idempotency-key-of-201-characters-rejected|' ||
            pg_temp._expect(pg_temp._err(format('SELECT offboarding.start_resignation_on_behalf(%L::uuid, %L, %L::date, %L, %L)', v_emp6, v_key200 || 'x', current_date + 20, 'OTHER', 'x')), 'OFFBOARDING_IDEMPOTENCY_KEY_REQUIRED')];
        SELECT count(*) INTO v_n FROM offboarding.cases WHERE hr_employee_id = v_emp6;
        v_res := v_res || ARRAY['8d-rejected-201-key-created-nothing|' || CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL: ' || v_n END];
        v_r := offboarding.start_termination(v_emp6, v_k || 'term2', current_date + 10, 'REDUNDANCY', 'restructuring');
        v_case7 := (v_r->>'case_id')::uuid; v_req7 := (v_r->>'workflow_request_id')::uuid;

        ------------------------------------------------------------ 9. workflow CANCEL needs a transaction-bound Offboarding sanction
        -- (owner session calling the service_role-only system cancel, exactly as the 007 RPCs will)
        -- 9a no sanction
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req5;
        v_err := pg_temp._err(format('SELECT workflow.process_system_action(%L::uuid, ''CANCEL'', NULL, ''t'', NULL, %L, %s)', v_req5, v_k || 'c9a', v_ver));
        v_res := v_res || ARRAY['9a-cancel-without-sanction-rejected-by-the-offboarding-guard|' || pg_temp._expect(v_err, 'OFFBOARDING_WORKFLOW_CANCEL_NOT_SANCTIONED')];
        -- 9b stale sanction (another transaction)
        INSERT INTO offboarding._workflow_sanctions (txid, case_id, workflow_request_id, operation, authorized_by) VALUES (txid_current() - 1, v_case5, v_req5, 'WITHDRAW_RESIGNATION', v_hr1);
        v_err := pg_temp._err(format('SELECT workflow.process_system_action(%L::uuid, ''CANCEL'', NULL, ''t'', NULL, %L, %s)', v_req5, v_k || 'c9b', v_ver));
        v_res := v_res || ARRAY['9b-stale-sanction-from-another-transaction-rejected|' || pg_temp._expect(v_err, 'OFFBOARDING_WORKFLOW_CANCEL_NOT_SANCTIONED')];
        -- 9c another case's sanction
        INSERT INTO offboarding._workflow_sanctions (case_id, workflow_request_id, operation, authorized_by) VALUES (v_case6, v_req6, 'WITHDRAW_RESIGNATION', v_hr1);
        v_err := pg_temp._err(format('SELECT workflow.process_system_action(%L::uuid, ''CANCEL'', NULL, ''t'', NULL, %L, %s)', v_req5, v_k || 'c9c', v_ver));
        v_res := v_res || ARRAY['9c-another-cases-sanction-rejected|' || pg_temp._expect(v_err, 'OFFBOARDING_WORKFLOW_CANCEL_NOT_SANCTIONED')];
        -- 9d right case, another request
        INSERT INTO offboarding._workflow_sanctions (case_id, workflow_request_id, operation, authorized_by) VALUES (v_case5, v_req6, 'WITHDRAW_RESIGNATION', v_hr1);
        v_err := pg_temp._err(format('SELECT workflow.process_system_action(%L::uuid, ''CANCEL'', NULL, ''t'', NULL, %L, %s)', v_req5, v_k || 'c9d', v_ver));
        v_res := v_res || ARRAY['9d-another-requests-sanction-rejected|' || pg_temp._expect(v_err, 'OFFBOARDING_WORKFLOW_CANCEL_NOT_SANCTIONED')];
        -- 9e wrong operation for a resignation
        INSERT INTO offboarding._workflow_sanctions (case_id, workflow_request_id, operation, authorized_by) VALUES (v_case5, v_req5, 'CANCEL_TERMINATION', v_hr1);
        v_err := pg_temp._err(format('SELECT workflow.process_system_action(%L::uuid, ''CANCEL'', NULL, ''t'', NULL, %L, %s)', v_req5, v_k || 'c9e', v_ver));
        v_res := v_res || ARRAY['9e-wrong-operation-for-a-resignation-rejected|' || pg_temp._expect(v_err, 'OFFBOARDING_WORKFLOW_CANCEL_NOT_SANCTIONED')];
        -- 9f wrong operation for a termination
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req7;
        INSERT INTO offboarding._workflow_sanctions (case_id, workflow_request_id, operation, authorized_by) VALUES (v_case7, v_req7, 'WITHDRAW_RESIGNATION', v_hr1);
        v_err := pg_temp._err(format('SELECT workflow.process_system_action(%L::uuid, ''CANCEL'', NULL, ''t'', NULL, %L, %s)', v_req7, v_k || 'c9f', v_ver));
        v_res := v_res || ARRAY['9f-wrong-operation-for-a-termination-rejected|' || pg_temp._expect(v_err, 'OFFBOARDING_WORKFLOW_CANCEL_NOT_SANCTIONED')];
        v_res := v_res || ARRAY['9g-every-rejected-cancel-left-both-requests-and-cases-untouched|' ||
            CASE WHEN (SELECT current_status FROM workflow.approval_requests WHERE id = v_req5) = 'PENDING'
                      AND (SELECT current_status FROM workflow.approval_requests WHERE id = v_req7) = 'PENDING'
                      AND (SELECT status::text FROM offboarding.cases WHERE id = v_case5) = 'SUBMITTED'
                      AND (SELECT status::text FROM offboarding.cases WHERE id = v_case7) = 'SUBMITTED' THEN 'PASS' ELSE 'FAIL' END];
        -- 9h / 9i exact, current-transaction sanctions are accepted
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req5;
        INSERT INTO offboarding._workflow_sanctions (case_id, workflow_request_id, operation, authorized_by) VALUES (v_case5, v_req5, 'WITHDRAW_RESIGNATION', v_hr1);
        v_err := pg_temp._err(format('SELECT workflow.process_system_action(%L::uuid, ''CANCEL'', NULL, ''t'', NULL, %L, %s)', v_req5, v_k || 'c9h', v_ver));
        v_res := v_res || ARRAY['9h-exact-sanction-accepted-for-a-resignation|' ||
            CASE WHEN v_err IS NULL AND (SELECT current_status FROM workflow.approval_requests WHERE id = v_req5) = 'CANCELLED' THEN 'PASS' ELSE 'FAIL: ' || coalesce(v_err, 'request not CANCELLED') END];
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req7;
        INSERT INTO offboarding._workflow_sanctions (case_id, workflow_request_id, operation, authorized_by) VALUES (v_case7, v_req7, 'CANCEL_TERMINATION', v_hr1);
        v_err := pg_temp._err(format('SELECT workflow.process_system_action(%L::uuid, ''CANCEL'', NULL, ''t'', NULL, %L, %s)', v_req7, v_k || 'c9i', v_ver));
        v_res := v_res || ARRAY['9i-exact-sanction-accepted-for-a-termination|' ||
            CASE WHEN v_err IS NULL AND (SELECT current_status FROM workflow.approval_requests WHERE id = v_req7) = 'CANCELLED' THEN 'PASS' ELSE 'FAIL: ' || coalesce(v_err, 'request not CANCELLED') END];
        -- 9j sanctions are immutable
        v_res := v_res || ARRAY['9j-sanction-update-rejected|' || pg_temp._expect(pg_temp._err(format('UPDATE offboarding._workflow_sanctions SET operation = ''CANCEL_TERMINATION'' WHERE case_id = %L', v_case5)), 'OFFBOARDING_APPEND_ONLY')];
        v_res := v_res || ARRAY['9k-sanction-delete-rejected|' || pg_temp._expect(pg_temp._err(format('DELETE FROM offboarding._workflow_sanctions WHERE case_id = %L', v_case5)), 'OFFBOARDING_APPEND_ONLY')];

        ------------------------------------------------------------ 10. a user-level engine cancel cannot strand a case
        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req6 AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req6;
        v_err := pg_temp._err(format('SELECT workflow.process_approval_action(%L::uuid, ''CANCEL'', %L::uuid, ''direct cancel'', NULL, %L, %s)', v_req6, v_step, v_k || 'dcancel', v_ver));
        RAISE NOTICE 'info: a direct user-level workflow cancel was refused by: %', coalesce(v_err, '(NOT refused)');
        v_res := v_res || ARRAY['10-direct-user-level-workflow-cancel-leaves-case-and-request-untouched|' ||
            CASE WHEN v_err IS NOT NULL AND (SELECT status::text FROM offboarding.cases WHERE id = v_case6) = 'SUBMITTED'
                      AND (SELECT current_status FROM workflow.approval_requests WHERE id = v_req6) = 'PENDING' THEN 'PASS' ELSE 'FAIL: err=' || coalesce(v_err, 'none') END];

        ------------------------------------------------------------ 11. direct workflow START and direct writes as an ordinary authenticated user
        SELECT id INTO v_def_id FROM workflow.workflow_definitions WHERE module = 'offboarding' AND code = 'OFFBOARDING_RESIGNATION_APPROVAL';
        PERFORM pg_temp._as(v_e1u);
        SET LOCAL ROLE authenticated;
        BEGIN PERFORM workflow.start_approval_request(v_def_id, 'offboarding_case', gen_random_uuid(), NULL, v_k || 'direct-start'); v_s := 'FAIL: direct engine start accepted';
        EXCEPTION WHEN insufficient_privilege THEN v_s := 'PASS'; WHEN OTHERS THEN v_s := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['11a-direct-engine-start-as-authenticated-denied|' || v_s];
        BEGIN INSERT INTO workflow.approval_requests (id) VALUES (gen_random_uuid()); v_s := 'FAIL: direct approval_requests INSERT accepted';
        EXCEPTION WHEN insufficient_privilege THEN v_s := 'PASS'; WHEN OTHERS THEN v_s := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['11b-direct-approval-requests-insert-as-authenticated-denied|' || v_s];
        BEGIN INSERT INTO offboarding._workflow_sanctions (case_id, workflow_request_id, operation) VALUES (v_case6, v_req6, 'WITHDRAW_RESIGNATION'); v_s := 'FAIL: app role created a sanction';
        EXCEPTION WHEN insufficient_privilege THEN v_s := 'PASS'; WHEN OTHERS THEN v_s := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['11c-app-role-cannot-create-a-sanction|' || v_s];
        BEGIN PERFORM workflow.process_system_action(v_req6, 'CANCEL', NULL, 'x', NULL, v_k || 'sys', 1); v_s := 'FAIL: app role called the system cancel';
        EXCEPTION WHEN insufficient_privilege THEN v_s := 'PASS'; WHEN OTHERS THEN v_s := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['11d-app-role-cannot-call-the-system-cancel|' || v_s];
        RESET ROLE;

        RAISE EXCEPTION 'OFF005_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'OFF005_ROLLBACK' THEN v_res := v_res || ARRAY['9-main-block|FAIL: ' || SQLSTATE || ' ' || SQLERRM]; END IF;
    END;

    INSERT INTO "_off005_results" SELECT split_part(x, '|', 1), substr(x, strpos(x, '|') + 1) FROM unnest(v_res) AS x;
END;
$$;

DO $$
DECLARE v_fail int; v_total int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE result <> 'PASS'), count(*),
           string_agg(step || ' = ' || result, ' | ' ORDER BY step) FILTER (WHERE result <> 'PASS')
      INTO v_fail, v_total, v_list FROM "_off005_results";
    IF v_total = 0 THEN RAISE EXCEPTION 'OFFBOARDING 005 TEST: no results recorded'; END IF;
    IF v_fail > 0 THEN RAISE EXCEPTION 'OFFBOARDING 005 TEST FAILED (% of % checks): %', v_fail, v_total, v_list; END IF;
    RAISE NOTICE 'OFFBOARDING 005 TEST PASSED: % checks, 0 failures', v_total;
END;
$$;

SELECT step, result FROM "_off005_results" ORDER BY step;
-- ========================================================================
-- END TEST_offboarding_005_start_rpcs.sql
-- ========================================================================
