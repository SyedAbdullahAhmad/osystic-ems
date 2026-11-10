-- ========================================================================
-- TEST_offboarding_009_read_projections.sql
-- Run AFTER 001-009 and the seed runner. Everything lives in ONE rolled-back sub-block; nothing persists.
-- Gate: any FAIL raises; all PASS completes with a notice.
-- Viewers: hr1 = MANAGE + every clearance permission; acc = VIEW_ALL; hr2 = workflow approver only (no OFFBOARDING permission);
--          clr = OFFBOARDING_CLEARANCE_ACCESS only; e1u = employee on case 1; oth = employee on case 2.
-- ========================================================================
DROP TABLE IF EXISTS "_off009_results";
CREATE TEMP TABLE "_off009_results" ("step" text, "result" text);

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
CREATE FUNCTION pg_temp._ids(p_j jsonb) RETURNS uuid[] LANGUAGE sql AS $f$
    SELECT coalesce(array_agg((i->>'case_id')::uuid), ARRAY[]::uuid[]) FROM jsonb_array_elements(p_j->'items') i
$f$;
CREATE FUNCTION pg_temp._same(p_a uuid[], p_b uuid[]) RETURNS boolean LANGUAGE sql AS $f$
    SELECT p_a @> p_b AND p_a <@ p_b
$f$;
CREATE FUNCTION pg_temp._mk(p_kind text, p_emp uuid, p_tag text, p_creator uuid, p_approver uuid, p_approve boolean) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_r jsonb; v_case uuid; v_req uuid; v_step uuid; v_ver int;
BEGIN
    PERFORM pg_temp._as(p_creator);
    IF p_kind = 'TERMINATION' THEN
        v_r := offboarding.start_termination(p_emp, 'off009-' || p_tag, current_date, 'CONDUCT', 'termsecret ' || p_tag);
    ELSE
        v_r := offboarding.start_resignation('off009-' || p_tag, current_date, 'PERSONAL', 'ressecret ' || p_tag);
    END IF;
    v_case := (v_r->>'case_id')::uuid; v_req := (v_r->>'workflow_request_id')::uuid;
    IF p_approve THEN
        PERFORM pg_temp._as(p_approver);
        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req;
        PERFORM workflow.process_approval_action(v_req, 'APPROVE', v_step, 'ok', NULL, 'off009-appr-' || p_tag, v_ver);
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
    v_emp1 uuid; v_emp2 uuid; v_emp3 uuid; v_emp4 uuid; v_emp5 uuid; v_emp6 uuid; v_emp7 uuid;
    c_term_own uuid; c_res_own uuid; c_term_appr uuid; c_term_sub uuid; c_term_rej uuid; c_term_can uuid; c_done uuid;
    v_all uuid[]; v_j jsonb; v_j2 jsonb; v_t jsonb; v_h jsonb; v_blob text; v_s text; v_n int; v_id uuid; v_req uuid; v_step uuid; v_ver int; d text;
    v_sig text; v_oid oid; v_k text := 'off009k-' || substr(md5(random()::text), 1, 6) || '-';
    v_today date := current_date; v_big uuid[]; v_ord uuid[]; v_role_appr uuid;
BEGIN
    SELECT id INTO v_org FROM core.organizations WHERE code = 'OSYSTIC';
    SELECT id INTO v_hr1 FROM auth.users WHERE core.has_permission(id, 'WORKFLOW_CONFIG_MANAGE') AND id NOT IN (v_hr2, v_clr, v_acc, v_e1u, v_oth) ORDER BY created_at LIMIT 1;
    IF v_org IS NULL OR v_hr1 IS NULL THEN RAISE EXCEPTION 'SETUP: org=%, hr1=%', v_org, v_hr1; END IF;
    IF (SELECT count(*) FROM auth.users WHERE id IN (v_hr2, v_clr, v_acc, v_e1u, v_oth)) <> 5 THEN RAISE EXCEPTION 'SETUP: fixture users a1/a5/a6/a7/a9 are missing'; END IF;
    IF (SELECT count(*) FROM workflow.workflow_definitions d JOIN workflow.workflow_versions v ON v.workflow_definition_id = d.id WHERE d.module = 'offboarding' AND v.status = 'ACTIVE') <> 2 THEN
        RAISE EXCEPTION 'SETUP: offboarding workflow definitions are not ACTIVE - run the seed runner first'; END IF;
    IF (SELECT count(*) FROM offboarding.cases) <> 0 THEN RAISE EXCEPTION 'SETUP: this test expects an empty offboarding.cases (exact list totals)'; END IF;

    FOREACH v_sig IN ARRAY ARRAY['offboarding.get_case(uuid)', 'offboarding.get_case_tasks(uuid)', 'offboarding.get_case_history(uuid)', 'offboarding.get_case_identities(uuid[])',
                                 'offboarding.list_cases(text,text,date,date,text,boolean,integer,integer)', 'offboarding.get_completion_readiness(uuid)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        v_res := v_res || ARRAY['0a-' || split_part(split_part(v_sig, '(', 1), '.', 2) || '-authenticated-only-definer-pinned-path|' ||
            CASE WHEN v_oid IS NOT NULL AND has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
                  AND (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) AND (SELECT proconfig::text LIKE '%search_path%' FROM pg_proc WHERE oid = v_oid)
                  AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))
                 THEN 'PASS' ELSE 'FAIL: ' || v_sig END];
    END LOOP;
    v_oid := to_regprocedure('offboarding._case_access(uuid,uuid)')::oid;
    v_res := v_res || ARRAY['0b-internal-case-access-closed-to-app-roles|' ||
        CASE WHEN v_oid IS NOT NULL AND NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END];
    v_res := v_res || ARRAY['0c-no-raw-table-select-for-app-roles|' ||
        CASE WHEN NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE table_schema = 'offboarding' AND grantee IN ('anon', 'authenticated') AND privilege_type = 'SELECT')
             THEN 'PASS' ELSE 'FAIL: some offboarding table is selectable' END];

    BEGIN
        PERFORM pg_temp._as(v_hr1);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF009_MGR_' || v_run, 'temp mgr', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code = 'OFFBOARDING_MANAGE' OR code LIKE 'OFFBOARDING\_CLEARANCE\_%';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_hr1, v_role);
        -- both offboarding workflows assign approval to holders of OFFBOARDING_MANAGE, so hr2 needs it to be ASSIGNED and to act;
        -- it is removed again before any read check, leaving hr2 an approver by ASSIGNMENT only (visibility must follow the assignment)
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF009_APPR_' || v_run, 'temp approver', 'temporary') RETURNING id INTO v_role_appr;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role_appr, id FROM core.permissions WHERE code = 'OFFBOARDING_MANAGE';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_hr2, v_role_appr);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF009_VA_' || v_run, 'temp view all', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code = 'OFFBOARDING_VIEW_ALL';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_acc, v_role);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF009_ACC_' || v_run, 'temp access holder', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code = 'OFFBOARDING_CLEARANCE_ACCESS';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_clr, v_role);

        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF009 E1', 'off009-e1-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO core.person_user_links (person_id, user_id) VALUES (v_p, v_e1u);
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF009-1-' || v_run, current_date - 400) RETURNING id INTO v_emp1;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF009 E2', 'off009-e2-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO core.person_user_links (person_id, user_id) VALUES (v_p, v_oth);
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF009-2-' || v_run, current_date - 400) RETURNING id INTO v_emp2;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF009 E3', 'off009-e3-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF009-3-' || v_run, current_date - 400) RETURNING id INTO v_emp3;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF009 E4', 'off009-e4-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF009-4-' || v_run, current_date - 400) RETURNING id INTO v_emp4;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF009 E5', 'off009-e5-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF009-5-' || v_run, current_date - 400) RETURNING id INTO v_emp5;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF009 E6', 'off009-e6-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF009-6-' || v_run, current_date - 400) RETURNING id INTO v_emp6;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF009 E7', 'off009-e7-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF009-7-' || v_run, current_date - 400) RETURNING id INTO v_emp7;

        -- seven cases, one per state (created in this order so created_at ordering is deterministic)
        c_term_own  := pg_temp._mk('TERMINATION', v_emp1, v_run || '-own',  v_hr1, NULL, false);                  -- SUBMITTED, employee e1u
        c_res_own   := pg_temp._mk('RESIGNATION_SELF', NULL, v_run || '-res', v_oth, NULL, false);               -- SUBMITTED -> WITHDRAWN below
        c_term_sub  := pg_temp._mk('TERMINATION', v_emp4, v_run || '-sub',  v_hr1, NULL, false);                  -- SUBMITTED
        c_term_appr := pg_temp._mk('TERMINATION', v_emp3, v_run || '-appr', v_hr1, v_hr2, true);                  -- IN_CLEARANCE
        c_term_rej  := pg_temp._mk('TERMINATION', v_emp5, v_run || '-rej',  v_hr1, NULL, false);                  -- REJECTED below
        c_term_can  := pg_temp._mk('TERMINATION', v_emp6, v_run || '-can',  v_hr1, v_hr2, true);                  -- CANCELLED below
        c_done      := pg_temp._mk('TERMINATION', v_emp7, v_run || '-done', v_hr1, v_hr2, true);                  -- COMPLETED below
        v_all := ARRAY[c_term_own, c_res_own, c_term_sub, c_term_appr, c_term_rej, c_term_can, c_done];

        PERFORM pg_temp._as(v_oth);
        PERFORM offboarding.withdraw_resignation(c_res_own, 'mywithdrawsecret', v_k || 'w1');
        PERFORM pg_temp._as(v_hr1);
        PERFORM offboarding.record_clearance(c_term_appr, 'ACCESS', 'accessnote', v_k || 'a1');
        PERFORM offboarding.waive_clearance(c_term_appr, 'FINANCE', 'waivesecret', v_k || 'a2');
        PERFORM offboarding.cancel_termination(c_term_can, 'cancelsecret', v_k || 'c1');
        FOREACH d IN ARRAY ARRAY['ASSETS', 'ACCESS', 'FINANCE', 'HANDOVER', 'HR'] LOOP PERFORM offboarding.record_clearance(c_done, d, 'ok', v_k || 'd-' || d); END LOOP;
        PERFORM offboarding.complete_offboarding(c_done, v_k || 'done');
        SELECT workflow_request_id INTO v_req FROM offboarding.cases WHERE id = c_term_rej;
        PERFORM pg_temp._as(v_hr2);
        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req;
        PERFORM workflow.process_approval_action(v_req, 'REJECT', v_step, 'rejected in test', NULL, v_k || 'rej', v_ver);

        DELETE FROM core.user_roles WHERE user_id = v_hr2 AND role_id = v_role_appr;
        v_res := v_res || ARRAY['0d-fixture-states-and-viewers|' || CASE WHEN
              (SELECT string_agg(status::text, ',' ORDER BY id) FROM offboarding.cases WHERE id = ANY (v_all)) IS NOT NULL
          AND (SELECT count(*) FROM offboarding.cases WHERE id = c_term_own AND status = 'SUBMITTED') = 1 AND (SELECT count(*) FROM offboarding.cases WHERE id = c_res_own AND status = 'WITHDRAWN') = 1
          AND (SELECT count(*) FROM offboarding.cases WHERE id = c_term_sub AND status = 'SUBMITTED') = 1 AND (SELECT count(*) FROM offboarding.cases WHERE id = c_term_appr AND status = 'IN_CLEARANCE') = 1
          AND (SELECT count(*) FROM offboarding.cases WHERE id = c_term_rej AND status = 'REJECTED') = 1 AND (SELECT count(*) FROM offboarding.cases WHERE id = c_term_can AND status = 'CANCELLED') = 1
          AND (SELECT count(*) FROM offboarding.cases WHERE id = c_done AND status = 'COMPLETED') = 1
          AND NOT core.has_permission(v_hr2, 'OFFBOARDING_MANAGE') AND NOT core.has_permission(v_hr2, 'OFFBOARDING_VIEW_ALL')
          AND EXISTS (SELECT 1 FROM workflow.approval_step_assignees a JOIN workflow.approval_steps s ON s.id = a.approval_step_id JOIN offboarding.cases c ON c.workflow_request_id = s.approval_request_id
                       WHERE c.id = c_term_sub AND a.assignee_user_id = v_hr2) THEN 'PASS' ELSE 'FAIL' END];

        -- the list order is created_at DESC, id DESC; all fixtures share one transaction timestamp, so the id breaks the tie
        SELECT array_agg(id ORDER BY created_at DESC, id DESC) INTO v_ord FROM offboarding.cases WHERE id = ANY (v_all);

        -- 1. authentication
        PERFORM pg_temp._as(NULL);
        v_res := v_res || ARRAY['1a-every-function-rejects-an-unauthenticated-caller|' ||
            CASE WHEN pg_temp._err('SELECT offboarding.list_cases()') LIKE 'OFFBOARDING_UNAUTHENTICATED%'
                  AND pg_temp._err(format('SELECT offboarding.get_case(%L::uuid)', c_term_own)) LIKE 'OFFBOARDING_UNAUTHENTICATED%'
                  AND pg_temp._err(format('SELECT offboarding.get_case_tasks(%L::uuid)', c_term_own)) LIKE 'OFFBOARDING_UNAUTHENTICATED%'
                  AND pg_temp._err(format('SELECT offboarding.get_case_history(%L::uuid)', c_term_own)) LIKE 'OFFBOARDING_UNAUTHENTICATED%'
                  AND pg_temp._err(format('SELECT offboarding.get_case_identities(ARRAY[%L]::uuid[])', c_term_own)) LIKE 'OFFBOARDING_UNAUTHENTICATED%'
                  AND pg_temp._err(format('SELECT offboarding.get_completion_readiness(%L::uuid)', c_term_own)) LIKE 'OFFBOARDING_UNAUTHENTICATED%'
                 THEN 'PASS' ELSE 'FAIL' END];

        -- 2. MANAGE sees everything
        PERFORM pg_temp._as(v_hr1);
        v_j := offboarding.list_cases();
        v_res := v_res || ARRAY['2a-manager-lists-all-seven-cases-default-page-25|' ||
            CASE WHEN (v_j->>'total')::int = 7 AND (v_j->>'limit')::int = 25 AND (v_j->>'offset')::int = 0 AND pg_temp._same(pg_temp._ids(v_j), v_all) THEN 'PASS' ELSE 'FAIL: ' || (v_j->>'total') END];
        v_j := offboarding.get_case(c_term_own);
        v_res := v_res || ARRAY['2b-manager-sees-termination-reason-email-and-null-department-position|' ||
            CASE WHEN v_j->>'reason_category' = 'CONDUCT' AND v_j->>'reason_detail' LIKE 'termsecret%' AND v_j->>'employee_email' LIKE 'off009-e1-%'
                      AND v_j ? 'department' AND v_j ? 'position' AND v_j->'department' = 'null'::jsonb AND v_j->'position' = 'null'::jsonb
                      AND (v_j->'viewer'->>'is_manager')::boolean AND (v_j->'viewer'->>'can_see_reasons')::boolean THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        v_res := v_res || ARRAY['2c-manager-sees-cancellation-and-withdrawal-reasons|' ||
            CASE WHEN offboarding.get_case(c_term_can)->>'cancellation_reason' = 'cancelsecret' AND offboarding.get_case(c_res_own)->>'withdrawal_reason' = 'mywithdrawsecret'
                      AND offboarding.get_case(c_term_rej)->>'reason_detail' LIKE 'termsecret%' THEN 'PASS' ELSE 'FAIL' END];
        v_t := offboarding.get_case_tasks(c_term_appr);
        v_res := v_res || ARRAY['2d-manager-sees-all-five-tasks-with-notes-and-waiver-reason|' ||
            CASE WHEN jsonb_array_length(v_t) = 5 AND v_t @> '[{"domain":"ACCESS","status":"CLEARED","clearance_note":"accessnote"}]'::jsonb
                      AND v_t @> '[{"domain":"FINANCE","status":"WAIVED","waiver_reason":"waivesecret"}]'::jsonb THEN 'PASS' ELSE 'FAIL: ' || v_t::text END];
        v_h := offboarding.get_case_history(c_term_own);
        v_res := v_res || ARRAY['2e-manager-history-has-full-detail-including-reason-category|' ||
            CASE WHEN v_h->0->>'event_type' = 'SUBMITTED' AND v_h->0->'detail'->>'reason_category' = 'CONDUCT' THEN 'PASS' ELSE 'FAIL: ' || v_h::text END];
        v_j := offboarding.get_case(c_done);
        v_res := v_res || ARRAY['2f-completed-case-exposes-integration-event-delivery-state-from-the-delivery-table|' ||
            CASE WHEN jsonb_array_length(v_j->'integration_events') = 2 AND (v_j->'integration_events') @> '[{"event_type":"employee.offboarding.completed","delivery_status":"PENDING"}]'::jsonb
                      AND (v_j->'integration_events') @> '[{"event_type":"ACCESS_REVOCATION_REQUESTED","delivery_status":"PENDING"}]'::jsonb THEN 'PASS' ELSE 'FAIL: ' || (v_j->'integration_events')::text END];

        -- 3. VIEW_ALL: everything non-sensitive, nothing sensitive
        PERFORM pg_temp._as(v_acc);
        v_j := offboarding.list_cases();
        v_res := v_res || ARRAY['3a-view-all-lists-all-cases-with-no-reason-category|' ||
            CASE WHEN (v_j->>'total')::int = 7 AND pg_temp._same(pg_temp._ids(v_j), v_all)
                  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'items') i WHERE i->>'reason_category' IS NOT NULL) THEN 'PASS' ELSE 'FAIL' END];
        v_blob := '';
        FOREACH v_id IN ARRAY v_all LOOP
            v_blob := v_blob || offboarding.get_case(v_id)::text || offboarding.get_case_tasks(v_id)::text || offboarding.get_case_history(v_id)::text;
        END LOOP;
        v_res := v_res || ARRAY['3b-view-all-output-never-contains-any-reason-or-note-text|' ||
            CASE WHEN position('termsecret' IN v_blob) = 0 AND position('ressecret' IN v_blob) = 0 AND position('cancelsecret' IN v_blob) = 0 AND position('waivesecret' IN v_blob) = 0
                      AND position('mywithdrawsecret' IN v_blob) = 0 AND position('accessnote' IN v_blob) = 0 AND position('CONDUCT' IN v_blob) = 0 AND position('PERSONAL' IN v_blob) = 0
                 THEN 'PASS' ELSE 'FAIL: leak' END];
        v_j := offboarding.get_case(c_term_own);
        v_res := v_res || ARRAY['3c-view-all-sees-header-email-and-integration-events-but-not-reasons|' ||
            CASE WHEN v_j->>'employee_name' = 'OFF009 E1' AND v_j->>'employee_email' LIKE 'off009-e1-%' AND v_j->>'reason_category' IS NULL AND v_j->>'reason_detail' IS NULL
                      AND jsonb_typeof(offboarding.get_case(c_done)->'integration_events') = 'array' THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        v_t := offboarding.get_case_tasks(c_term_appr);
        v_res := v_res || ARRAY['3d-view-all-tasks-are-statuses-and-timestamps-only|' ||
            CASE WHEN jsonb_array_length(v_t) = 5 AND v_t @> '[{"domain":"FINANCE","status":"WAIVED"}]'::jsonb
                      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_t) t WHERE t ? 'waiver_reason' OR t ? 'clearance_note' OR t ? 'cleared_by') THEN 'PASS' ELSE 'FAIL: ' || v_t::text END];
        v_h := offboarding.get_case_history(c_term_own);
        v_res := v_res || ARRAY['3e-view-all-history-detail-is-whitelisted|' ||
            CASE WHEN jsonb_array_length(v_h) >= 1 AND NOT (v_h->0->'detail' ? 'reason_category') AND v_h->0->'detail' ? 'case_type' THEN 'PASS' ELSE 'FAIL: ' || v_h::text END];

        -- 4. the employee on their own case
        PERFORM pg_temp._as(v_e1u);
        v_j := offboarding.list_cases();
        v_res := v_res || ARRAY['4a-employee-lists-only-their-own-case-without-termination-reason|' ||
            CASE WHEN (v_j->>'total')::int = 1 AND pg_temp._same(pg_temp._ids(v_j), ARRAY[c_term_own]) AND v_j->'items'->0->>'reason_category' IS NULL
                      AND (v_j->'items'->0->>'is_own')::boolean AND v_j->'items'->0->>'employee_email' LIKE 'off009-e1-%' THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        v_j := offboarding.get_case(c_term_own);
        v_t := offboarding.get_case_tasks(c_term_own);
        v_h := offboarding.get_case_history(c_term_own);
        v_blob := v_j::text || v_t::text || v_h::text;
        v_res := v_res || ARRAY['4b-own-termination-no-reason-statuses-only-and-clean-timeline|' ||
            CASE WHEN v_j->>'reason_category' IS NULL AND v_j->>'reason_detail' IS NULL AND (v_j->'viewer'->>'is_own')::boolean AND NOT (v_j->'viewer'->>'can_see_reasons')::boolean
                      AND jsonb_array_length(v_t) = 5 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_t) t WHERE (SELECT count(*) FROM jsonb_object_keys(t)) <> 2)
                      AND jsonb_array_length(v_h) >= 1 AND position('CONDUCT' IN v_blob) = 0 AND position('termsecret' IN v_blob) = 0 THEN 'PASS' ELSE 'FAIL: ' || v_blob END];
        v_res := v_res || ARRAY['4c-employee-cannot-see-other-cases-and-error-equals-unknown-case|' ||
            CASE WHEN pg_temp._err(format('SELECT offboarding.get_case(%L::uuid)', c_term_sub)) = pg_temp._err(format('SELECT offboarding.get_case(%L::uuid)', gen_random_uuid()))
                  AND pg_temp._err(format('SELECT offboarding.get_case(%L::uuid)', c_res_own)) LIKE 'OFFBOARDING_CASE_NOT_FOUND%'
                  AND pg_temp._err(format('SELECT offboarding.get_case_tasks(%L::uuid)', c_term_sub)) LIKE 'OFFBOARDING_CASE_NOT_FOUND%'
                  AND pg_temp._err(format('SELECT offboarding.get_case_history(%L::uuid)', c_term_sub)) LIKE 'OFFBOARDING_CASE_NOT_FOUND%' THEN 'PASS' ELSE 'FAIL' END];
        PERFORM pg_temp._as(v_oth);
        v_j := offboarding.list_cases();
        v_res := v_res || ARRAY['4d-employee-sees-their-own-resignation-reason-category|' ||
            CASE WHEN (v_j->>'total')::int = 1 AND pg_temp._same(pg_temp._ids(v_j), ARRAY[c_res_own]) AND v_j->'items'->0->>'reason_category' = 'PERSONAL' THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        v_j := offboarding.get_case(c_res_own);
        v_h := offboarding.get_case_history(c_res_own);
        v_res := v_res || ARRAY['4e-employee-sees-own-resignation-reason-and-own-withdrawal-reason|' ||
            CASE WHEN v_j->>'reason_category' = 'PERSONAL' AND v_j->>'reason_detail' LIKE 'ressecret%' AND v_j->>'withdrawal_reason' = 'mywithdrawsecret' AND v_j->>'cancellation_reason' IS NULL
                      AND v_h @> '[{"event_type":"SUBMITTED","detail":{"reason_category":"PERSONAL"}}]'::jsonb AND v_h @> '[{"event_type":"WITHDRAWN","detail":{"reason":"mywithdrawsecret"}}]'::jsonb THEN 'PASS' ELSE 'FAIL: ' || v_j::text || v_h::text END];
        v_res := v_res || ARRAY['4f-employee-cannot-see-the-termination-case-of-a-colleague|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.get_case(%L::uuid)', c_term_own)), 'OFFBOARDING_CASE_NOT_FOUND')];

        -- 5. workflow approver (no OFFBOARDING permission)
        PERFORM pg_temp._as(v_hr2);
        v_j := offboarding.get_case(c_term_sub);
        v_t := offboarding.get_case_tasks(c_term_sub);
        v_h := offboarding.get_case_history(c_term_sub);
        v_res := v_res || ARRAY['5a-approver-sees-header-only-no-reason-no-email-no-tasks-no-history|' ||
            CASE WHEN v_j->>'employee_name' = 'OFF009 E4' AND v_j->>'employee_number' LIKE 'OFF009-4-%' AND v_j->>'employee_email' IS NULL AND v_j->>'reason_category' IS NULL AND v_j->>'reason_detail' IS NULL
                      AND (v_j->'viewer'->>'is_assigned_approver')::boolean AND v_t = '[]'::jsonb AND v_h = '[]'::jsonb AND v_j->'integration_events' = 'null'::jsonb THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        v_j := offboarding.list_cases(NULL, NULL, NULL, NULL, NULL, true);
        v_res := v_res || ARRAY['5b-awaiting-my-approval-returns-the-submitted-cases-assigned-to-me|' ||
            CASE WHEN pg_temp._ids(v_j) @> ARRAY[c_term_own, c_term_sub] AND NOT (pg_temp._ids(v_j) && ARRAY[c_term_appr, c_done, c_term_rej, c_term_can, c_res_own])
                      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'items') i WHERE NOT (i->>'awaiting_my_approval')::boolean OR i->>'status' <> 'SUBMITTED') THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        v_blob := offboarding.list_cases()::text || offboarding.get_case(c_term_own)::text || offboarding.get_case(c_term_appr)::text || offboarding.get_case(c_term_can)::text || offboarding.get_case(c_term_rej)::text;
        v_res := v_res || ARRAY['5c-approver-output-never-contains-reasons-or-email|' ||
            CASE WHEN position('termsecret' IN v_blob) = 0 AND position('cancelsecret' IN v_blob) = 0 AND position('CONDUCT' IN v_blob) = 0 AND position('@example.invalid' IN v_blob) = 0 THEN 'PASS' ELSE 'FAIL: leak' END];

        -- 6. clearance holder (ACCESS only)
        PERFORM pg_temp._as(v_clr);
        v_j := offboarding.list_cases();
        v_res := v_res || ARRAY['6a-clearance-holder-lists-only-cases-in-the-clearance-stage|' ||
            CASE WHEN (v_j->>'total')::int = 1 AND pg_temp._same(pg_temp._ids(v_j), ARRAY[c_term_appr]) THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        v_res := v_res || ARRAY['6b-clearance-holder-cannot-see-a-submitted-case|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.get_case(%L::uuid)', c_term_sub)), 'OFFBOARDING_CASE_NOT_FOUND')];
        v_j := offboarding.get_case(c_term_appr);
        v_t := offboarding.get_case_tasks(c_term_appr);
        v_h := offboarding.get_case_history(c_term_appr);
        v_blob := v_j::text || v_t::text || v_h::text;
        v_res := v_res || ARRAY['6c-holder-sees-case-header-and-only-their-own-domain-task|' ||
            CASE WHEN v_j->>'employee_name' = 'OFF009 E3' AND v_j->>'employee_email' IS NULL AND v_j->>'reason_category' IS NULL AND v_j->>'reason_detail' IS NULL
                      AND jsonb_array_length(v_t) = 1 AND v_t->0->>'domain' = 'ACCESS' AND v_t->0->>'status' = 'CLEARED' AND v_h = '[]'::jsonb
                      AND position('waivesecret' IN v_blob) = 0 AND position('termsecret' IN v_blob) = 0 AND position('CONDUCT' IN v_blob) = 0 THEN 'PASS' ELSE 'FAIL: ' || v_blob END];

        -- 7. list mechanics (as MANAGE; the data set is exactly the seven cases)
        PERFORM pg_temp._as(v_hr1);
        v_j := offboarding.list_cases(NULL, NULL, NULL, NULL, NULL, false, 2, 0);
        v_j2 := offboarding.list_cases(NULL, NULL, NULL, NULL, NULL, false, 2, 2);
        v_res := v_res || ARRAY['7a-paging-is-deterministic-and-newest-first-without-overlap|' ||
            CASE WHEN (v_j->>'total')::int = 7 AND (v_j2->>'total')::int = 7 AND jsonb_array_length(v_j->'items') = 2 AND jsonb_array_length(v_j2->'items') = 2
                      AND NOT (pg_temp._ids(v_j) && pg_temp._ids(v_j2)) AND pg_temp._ids(v_j) = v_ord[1:2] AND pg_temp._ids(v_j2) = v_ord[3:4]
                      AND pg_temp._ids(offboarding.list_cases(NULL, NULL, NULL, NULL, NULL, false, 2, 6)) = v_ord[7:7]
                      AND pg_temp._ids(offboarding.list_cases(NULL, NULL, NULL, NULL, NULL, false, 2, 99)) = ARRAY[]::uuid[] AND (offboarding.list_cases(NULL, NULL, NULL, NULL, NULL, false, 2, 99)->>'total')::int = 7
                 THEN 'PASS' ELSE 'FAIL: ' || pg_temp._ids(v_j)::text END];
        v_res := v_res || ARRAY['7b-page-size-is-clamped-between-1-and-100|' ||
            CASE WHEN (offboarding.list_cases(NULL, NULL, NULL, NULL, NULL, false, 1000, 0)->>'limit')::int = 100 AND (offboarding.list_cases(NULL, NULL, NULL, NULL, NULL, false, 0, 0)->>'limit')::int = 1
                      AND (offboarding.list_cases(NULL, NULL, NULL, NULL, NULL, false, NULL, NULL)->>'limit')::int = 25 THEN 'PASS' ELSE 'FAIL' END];
        v_res := v_res || ARRAY['7c-status-and-case-type-filters|' ||
            CASE WHEN pg_temp._ids(offboarding.list_cases('completed')) = ARRAY[c_done] AND pg_temp._ids(offboarding.list_cases(NULL, 'resignation')) = ARRAY[c_res_own]
                      AND pg_temp._same(pg_temp._ids(offboarding.list_cases('SUBMITTED')), ARRAY[c_term_own, c_term_sub]) AND (offboarding.list_cases(NULL, 'TERMINATION')->>'total')::int = 6 THEN 'PASS' ELSE 'FAIL' END];
        v_res := v_res || ARRAY['7d-last-working-date-range-filter|' ||
            CASE WHEN (offboarding.list_cases(NULL, NULL, v_today, v_today)->>'total')::int = 7 AND (offboarding.list_cases(NULL, NULL, v_today + 1, NULL)->>'total')::int = 0
                      AND (offboarding.list_cases(NULL, NULL, NULL, v_today - 1)->>'total')::int = 0 THEN 'PASS' ELSE 'FAIL' END];
        v_res := v_res || ARRAY['7e-search-by-name-employee-number-and-email-for-a-manager|' ||
            CASE WHEN pg_temp._ids(offboarding.list_cases(NULL, NULL, NULL, NULL, 'off009 e3')) = ARRAY[c_term_appr]
                      AND pg_temp._ids(offboarding.list_cases(NULL, NULL, NULL, NULL, 'OFF009-4-' || v_run)) = ARRAY[c_term_sub]
                      AND pg_temp._ids(offboarding.list_cases(NULL, NULL, NULL, NULL, 'off009-e5-' || v_run)) = ARRAY[c_term_rej] THEN 'PASS' ELSE 'FAIL' END];
        v_res := v_res || ARRAY['7f-search-never-matches-reason-text-and-wildcards-are-literal|' ||
            CASE WHEN (offboarding.list_cases(NULL, NULL, NULL, NULL, 'termsecret')->>'total')::int = 0 AND (offboarding.list_cases(NULL, NULL, NULL, NULL, 'CONDUCT')->>'total')::int = 0
                      AND (offboarding.list_cases(NULL, NULL, NULL, NULL, '%')->>'total')::int = 0 AND (offboarding.list_cases(NULL, NULL, NULL, NULL, '_')->>'total')::int = 0 THEN 'PASS' ELSE 'FAIL' END];
        PERFORM pg_temp._as(v_clr);
        v_res := v_res || ARRAY['7g-email-is-not-searchable-for-a-viewer-who-may-not-see-it|' ||
            CASE WHEN (offboarding.list_cases(NULL, NULL, NULL, NULL, 'off009-e3-' || v_run)->>'total')::int = 0
                      AND pg_temp._ids(offboarding.list_cases(NULL, NULL, NULL, NULL, 'OFF009 E3')) = ARRAY[c_term_appr] THEN 'PASS' ELSE 'FAIL' END];
        PERFORM pg_temp._as(v_hr1);
        v_res := v_res || ARRAY['7h-invalid-filters-are-rejected|' ||
            CASE WHEN pg_temp._err(format('SELECT offboarding.list_cases(%L)', 'BOGUS')) LIKE 'OFFBOARDING_INVALID_FILTER%'
                  AND pg_temp._err(format('SELECT offboarding.list_cases(NULL, %L)', 'BOGUS')) LIKE 'OFFBOARDING_INVALID_FILTER%'
                  AND pg_temp._err(format('SELECT offboarding.list_cases(NULL, NULL, %L::date, %L::date)', v_today + 5, v_today)) LIKE 'OFFBOARDING_INVALID_FILTER%' THEN 'PASS' ELSE 'FAIL' END];

        -- 8. identities
        v_j := offboarding.get_case_identities(v_all || ARRAY[gen_random_uuid()]);
        v_res := v_res || ARRAY['8a-manager-identities-for-all-visible-cases-unknown-ids-ignored|' ||
            CASE WHEN jsonb_array_length(v_j) = 7 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) i WHERE i->>'employee_email' IS NULL OR i->>'employee_name' NOT LIKE 'OFF009 E%') THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        PERFORM pg_temp._as(v_oth);
        v_j := offboarding.get_case_identities(v_all);
        PERFORM pg_temp._as(v_clr);
        v_j2 := offboarding.get_case_identities(v_all);
        v_res := v_res || ARRAY['8b-identities-only-for-visible-cases-and-email-only-where-allowed|' ||
            CASE WHEN jsonb_array_length(v_j) = 1 AND v_j->0->>'case_id' = c_res_own::text AND v_j->0->>'employee_email' LIKE 'off009-e2-%'
                      AND jsonb_array_length(v_j2) = 1 AND v_j2->0->>'case_id' = c_term_appr::text AND v_j2->0->>'employee_email' IS NULL THEN 'PASS' ELSE 'FAIL: ' || v_j::text || v_j2::text END];
        SELECT array_agg(gen_random_uuid()) INTO v_big FROM generate_series(1, 201);
        PERFORM pg_temp._as(v_hr1);
        v_res := v_res || ARRAY['8c-more-than-200-ids-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.get_case_identities(%L::uuid[])', v_big)), 'OFFBOARDING_TOO_MANY_IDS')];

        -- 9. completion readiness (MANAGE only)
        PERFORM pg_temp._as(v_hr2);
        v_res := v_res || ARRAY['9a-readiness-requires-manage|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.get_completion_readiness(%L::uuid)', c_term_appr)), 'OFFBOARDING_NOT_AUTHORIZED')];
        PERFORM pg_temp._as(v_hr1);
        v_j := offboarding.get_completion_readiness(c_term_appr);
        v_res := v_res || ARRAY['9b-readiness-shows-open-clearance-and-cannot-complete-yet|' ||
            CASE WHEN NOT (v_j->>'clearance_ready')::boolean AND NOT (v_j->>'can_complete')::boolean AND (v_j->>'date_reached')::boolean AND v_j->'clearance'->>'FINANCE' = 'WAIVED'
                      AND v_j->'clearance'->>'ACCESS' = 'CLEARED' AND v_j->'clearance'->>'ASSETS' = 'PENDING' AND v_j->'blockers' = '[]'::jsonb THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        FOREACH d IN ARRAY ARRAY['ASSETS', 'HANDOVER', 'HR'] LOOP PERFORM offboarding.record_clearance(c_term_appr, d, 'ok', v_k || 'z-' || d); END LOOP;
        v_j := offboarding.get_completion_readiness(c_term_appr);
        v_res := v_res || ARRAY['9c-readiness-turns-green-once-everything-is-final|' ||
            CASE WHEN (v_j->>'clearance_ready')::boolean AND (v_j->>'can_complete')::boolean AND (v_j->>'assets_outstanding')::int = 0 THEN 'PASS' ELSE 'FAIL: ' || v_j::text END];
        v_j := offboarding.get_completion_readiness(c_done);
        v_res := v_res || ARRAY['9d-a-completed-case-is-not-completable-again|' || CASE WHEN NOT (v_j->>'can_complete')::boolean THEN 'PASS' ELSE 'FAIL' END];
        v_res := v_res || ARRAY['9e-readiness-unknown-case-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.get_completion_readiness(%L::uuid)', gen_random_uuid())), 'OFFBOARDING_CASE_NOT_FOUND')];

        RAISE EXCEPTION 'OFF009_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'OFF009_ROLLBACK' THEN v_res := v_res || ARRAY['9-main-block|FAIL: ' || SQLSTATE || ' ' || SQLERRM]; END IF;
    END;

    INSERT INTO "_off009_results" SELECT split_part(x, '|', 1), substr(x, strpos(x, '|') + 1) FROM unnest(v_res) AS x;
END;
$$;

DO $$
DECLARE v_fail int; v_total int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE result <> 'PASS'), count(*),
           string_agg(step || ' = ' || result, ' | ' ORDER BY step) FILTER (WHERE result <> 'PASS')
      INTO v_fail, v_total, v_list FROM "_off009_results";
    IF v_total = 0 THEN RAISE EXCEPTION 'OFFBOARDING 009 TEST: no results recorded'; END IF;
    IF v_fail > 0 THEN RAISE EXCEPTION 'OFFBOARDING 009 TEST FAILED (% of % checks): %', v_fail, v_total, v_list; END IF;
    RAISE NOTICE 'OFFBOARDING 009 TEST PASSED: % checks, 0 failures', v_total;
END;
$$;

SELECT step, result FROM "_off009_results" ORDER BY step;
-- ========================================================================
-- END TEST_offboarding_009_read_projections.sql
-- ========================================================================
