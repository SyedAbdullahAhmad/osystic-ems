-- ========================================================================
-- TEST_offboarding_008_complete.sql
-- Run AFTER 001-008 and the seed runner. Everything lives in ONE rolled-back sub-block; nothing persists.
-- Gate: any FAIL raises; all PASS completes with a notice.
-- ========================================================================
DROP TABLE IF EXISTS "_off008_results";
CREATE TEMP TABLE "_off008_results" ("step" text, "result" text);

CREATE FUNCTION pg_temp._as(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
END;
$f$;
CREATE FUNCTION pg_temp._err(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN EXECUTE p_sql; RETURN NULL; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END;
$f$;
CREATE FUNCTION pg_temp._errd(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_d text;
BEGIN EXECUTE p_sql; RETURN NULL; EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_d = PG_EXCEPTION_DETAIL; RETURN coalesce(v_d, ''); END;
$f$;
CREATE FUNCTION pg_temp._expect(p_err text, p_prefix text) RETURNS text LANGUAGE sql AS $f$
    SELECT CASE WHEN p_err IS NULL THEN 'FAIL: no error raised' WHEN p_err LIKE p_prefix || '%' THEN 'PASS' ELSE 'FAIL: ' || p_err END
$f$;
CREATE FUNCTION pg_temp._mk(p_kind text, p_emp uuid, p_tag text, p_creator uuid, p_approver uuid, p_approve boolean, p_lwd date) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_r jsonb; v_case uuid; v_req uuid; v_step uuid; v_ver int;
BEGIN
    PERFORM pg_temp._as(p_creator);
    IF p_kind = 'TERMINATION' THEN
        v_r := offboarding.start_termination(p_emp, 'off008-' || p_tag, p_lwd, 'CONDUCT', 'secretdetail ' || p_tag);
    ELSE
        v_r := offboarding.start_resignation_on_behalf(p_emp, 'off008-' || p_tag, p_lwd, 'PERSONAL', 'secretdetail ' || p_tag);
    END IF;
    v_case := (v_r->>'case_id')::uuid; v_req := (v_r->>'workflow_request_id')::uuid;
    IF p_approve THEN
        PERFORM pg_temp._as(p_approver);
        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req;
        PERFORM workflow.process_approval_action(v_req, 'APPROVE', v_step, 'ok', NULL, 'off008-appr-' || p_tag, v_ver);
    END IF;
    RETURN v_case;
END;
$f$;
-- sign off / waive: p_clear domains are CLEARED by the clearance holder, p_waive domains are WAIVED by the manager
CREATE FUNCTION pg_temp._clear(p_case uuid, p_clear text[], p_waive text[], p_tag text, p_clr uuid, p_mgr uuid) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE d text;
BEGIN
    PERFORM pg_temp._as(p_clr);
    FOREACH d IN ARRAY p_clear LOOP PERFORM offboarding.record_clearance(p_case, d, 'ok ' || d, 'off008c-' || p_tag || '-' || d); END LOOP;
    PERFORM pg_temp._as(p_mgr);
    FOREACH d IN ARRAY p_waive LOOP PERFORM offboarding.waive_clearance(p_case, d, 'waived ' || d, 'off008w-' || p_tag || '-' || d); END LOOP;
END;
$f$;
CREATE FUNCTION pg_temp._mkctr(p_id uuid, p_tag text, p_emp uuid, p_status text, p_from date, p_to date) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_ver uuid;
BEGIN
    INSERT INTO hr.contracts (id, employee_id, contract_number, contract_type, status, hr_employee_id, created_at, updated_at, version)
    SELECT p_id, c.employee_id, 'OFF008-' || p_tag, c.contract_type, p_status::hr.contract_status, p_emp, now(), now(), 1 FROM hr.contracts c ORDER BY c.created_at LIMIT 1;
    INSERT INTO hr.contract_versions (id, contract_id, version_no, effective_from, effective_to, created_at, version)
    VALUES (gen_random_uuid(), p_id, 1, p_from, p_to, now(), 1) RETURNING id INTO v_ver;
    UPDATE hr.contracts SET current_version_id = v_ver WHERE id = p_id;
    RETURN p_id;
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
    v_c_good uuid := '00000000-0000-0000-0000-00000000c001';
    v_c_bad  uuid := '00000000-0000-0000-0000-00000000c002';
    v_emp1 uuid; v_emp2 uuid; v_emp3 uuid; v_emp4 uuid; v_emp5 uuid; v_emp6 uuid; v_emp7 uuid; v_emp8 uuid; v_emp9 uuid;
    c_self uuid; c_main uuid; c_block uuid; c_early uuid; c_incomp uuid; c_asset uuid; c_res uuid; c_atomic uuid; c_appr uuid;
    v_r jsonb; v_r2 jsonb; v_s text; v_n int; v_n2 int; v_n3 int; v_err text; v_det text; v_cv int; v_hist int;
    v_sig text; v_oid oid; v_k text := 'off008k-' || substr(md5(random()::text), 1, 6) || '-';
    v_today date := current_date;
    t_lv_emp uuid; t_lv_type uuid; t_c_emp uuid; t_c_day uuid; t_a_emp uuid; t_a_cat uuid;
    v_lv uuid := gen_random_uuid(); v_co uuid := gen_random_uuid(); v_ar uuid := gen_random_uuid(); v_ct uuid := gen_random_uuid();
    v_lv_ok uuid := gen_random_uuid(); v_ar_ok uuid := gen_random_uuid(); v_co_ok uuid := gen_random_uuid();
    v_tpl record; v_cat uuid; v_asset uuid := gen_random_uuid(); v_asg uuid := gen_random_uuid();
    v_ev1 record; v_ev2 record;
BEGIN
    SELECT id INTO v_org FROM core.organizations WHERE code = 'OSYSTIC';
    SELECT id INTO v_hr1 FROM auth.users WHERE core.has_permission(id, 'WORKFLOW_CONFIG_MANAGE') AND id NOT IN (v_hr2, v_clr, v_acc, v_e1u, v_oth) ORDER BY created_at LIMIT 1;
    IF v_org IS NULL OR v_hr1 IS NULL THEN RAISE EXCEPTION 'SETUP: org=%, hr1=%', v_org, v_hr1; END IF;
    IF (SELECT count(*) FROM auth.users WHERE id IN (v_hr2, v_clr, v_acc, v_e1u, v_oth)) <> 5 THEN RAISE EXCEPTION 'SETUP: fixture users a1/a5/a6/a7/a9 are missing'; END IF;
    IF (SELECT count(*) FROM workflow.workflow_definitions d JOIN workflow.workflow_versions v ON v.workflow_definition_id = d.id WHERE d.module = 'offboarding' AND v.status = 'ACTIVE') <> 2 THEN
        RAISE EXCEPTION 'SETUP: offboarding workflow definitions are not ACTIVE - run the seed runner first'; END IF;
    SELECT * INTO v_tpl FROM assets.asset_assignments ORDER BY assigned_at LIMIT 1;
    IF v_tpl.id IS NULL THEN RAISE EXCEPTION 'SETUP: need an existing assets.asset_assignments row as a template'; END IF;
    SELECT asset_category_id INTO v_cat FROM assets.assets WHERE id = v_tpl.asset_id;
    SELECT employee_id, leave_type_id INTO t_lv_emp, t_lv_type FROM leave.leave_requests ORDER BY created_at LIMIT 1;
    SELECT employee_id, attendance_day_id INTO t_c_emp, t_c_day FROM attendance.correction_requests ORDER BY created_at LIMIT 1;
    SELECT employee_id, asset_category_id INTO t_a_emp, t_a_cat FROM assets.asset_requests ORDER BY created_at LIMIT 1;
    IF t_lv_emp IS NULL OR t_c_emp IS NULL OR t_a_emp IS NULL OR (SELECT count(*) FROM hr.contracts) = 0 THEN RAISE EXCEPTION 'SETUP: need template rows in leave, attendance corrections, asset requests and contracts'; END IF;

    -- 0. privileges
    v_oid := to_regprocedure('offboarding.complete_offboarding(uuid,character varying)')::oid;
    v_res := v_res || ARRAY['0a-complete-offboarding-authenticated-only-definer-pinned-path|' ||
        CASE WHEN v_oid IS NOT NULL AND has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
              AND (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) AND (SELECT proconfig::text LIKE '%search_path%' FROM pg_proc WHERE oid = v_oid)
              AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))
             THEN 'PASS' ELSE 'FAIL' END];
    FOREACH v_sig IN ARRAY ARRAY['offboarding._business_date()', 'offboarding._completion_blockers(uuid)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        v_res := v_res || ARRAY['0b-' || split_part(split_part(v_sig, '(', 1), '.', 2) || '-closed-to-app-roles|' ||
            CASE WHEN v_oid IS NOT NULL AND NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END];
    END LOOP;
    v_res := v_res || ARRAY['0c-business-date-is-not-before-the-server-date|' || CASE WHEN offboarding._business_date() >= v_today THEN 'PASS' ELSE 'FAIL: ' || offboarding._business_date() END];

    BEGIN
        PERFORM pg_temp._as(v_hr1);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF008_MGR_' || v_run, 'temp mgr', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code = 'OFFBOARDING_MANAGE';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_hr1, v_role), (v_hr2, v_role), (v_e1u, v_role);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF008_ALL_' || v_run, 'temp all clearance', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code LIKE 'OFFBOARDING\_CLEARANCE\_%';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_clr, v_role);

        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF008 E1', 'off008-e1-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO core.person_user_links (person_id, user_id) VALUES (v_p, v_e1u);
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF008-1-' || v_run, current_date - 400) RETURNING id INTO v_emp1;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF008 E2', 'off008-e2-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF008-2-' || v_run, current_date - 400) RETURNING id INTO v_emp2;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF008 E3', 'off008-e3-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF008-3-' || v_run, current_date - 400) RETURNING id INTO v_emp3;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF008 E4', 'off008-e4-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF008-4-' || v_run, current_date - 400) RETURNING id INTO v_emp4;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF008 E5', 'off008-e5-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF008-5-' || v_run, current_date - 400) RETURNING id INTO v_emp5;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF008 E6', 'off008-e6-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF008-6-' || v_run, current_date - 400) RETURNING id INTO v_emp6;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF008 E7', 'off008-e7-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF008-7-' || v_run, current_date - 400) RETURNING id INTO v_emp7;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF008 E8', 'off008-e8-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF008-8-' || v_run, current_date - 400) RETURNING id INTO v_emp8;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF008 E9', 'off008-e9-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF008-9-' || v_run, current_date - 400) RETURNING id INTO v_emp9;

        -- cases. LWD = today lets a case complete; LWD = today + 10 is "not yet"
        c_self   := pg_temp._mk('TERMINATION', v_emp1, v_run || '-self',   v_hr1, v_hr2, true, v_today);
        c_main   := pg_temp._mk('TERMINATION', v_emp2, v_run || '-main',   v_hr1, v_hr2, true, v_today);
        c_block  := pg_temp._mk('TERMINATION', v_emp3, v_run || '-block',  v_hr1, v_hr2, true, v_today);
        c_early  := pg_temp._mk('TERMINATION', v_emp4, v_run || '-early',  v_hr1, v_hr2, true, v_today + 10);
        c_incomp := pg_temp._mk('TERMINATION', v_emp5, v_run || '-incomp', v_hr1, v_hr2, true, v_today);
        c_asset  := pg_temp._mk('TERMINATION', v_emp6, v_run || '-asset',  v_hr1, v_hr2, true, v_today);
        c_res    := pg_temp._mk('RESIGNATION', v_emp7, v_run || '-res',    v_hr1, v_hr2, true, v_today);
        c_atomic := pg_temp._mk('TERMINATION', v_emp8, v_run || '-atomic', v_hr1, v_hr2, true, v_today);
        c_appr   := pg_temp._mk('TERMINATION', v_emp9, v_run || '-appr',   v_hr1, v_hr2, true, v_today);

        PERFORM pg_temp._clear(c_self,   ARRAY['ASSETS','ACCESS','FINANCE','HANDOVER','HR'], ARRAY[]::text[], v_run || 'self',  v_clr, v_hr1);
        PERFORM pg_temp._clear(c_main,   ARRAY['ASSETS','ACCESS','HR'], ARRAY['FINANCE','HANDOVER'], v_run || 'main', v_clr, v_hr1);
        PERFORM pg_temp._clear(c_block,  ARRAY['ASSETS','ACCESS','FINANCE','HANDOVER','HR'], ARRAY[]::text[], v_run || 'block', v_clr, v_hr1);
        PERFORM pg_temp._clear(c_early,  ARRAY['ASSETS','ACCESS','FINANCE','HANDOVER','HR'], ARRAY[]::text[], v_run || 'early', v_clr, v_hr1);
        PERFORM pg_temp._clear(c_incomp, ARRAY['ACCESS'], ARRAY[]::text[], v_run || 'incomp', v_clr, v_hr1);
        PERFORM pg_temp._clear(c_asset,  ARRAY['ASSETS','ACCESS','FINANCE','HANDOVER','HR'], ARRAY[]::text[], v_run || 'asset', v_clr, v_hr1);
        PERFORM pg_temp._clear(c_res,    ARRAY['ASSETS','ACCESS','FINANCE','HANDOVER','HR'], ARRAY[]::text[], v_run || 'res', v_clr, v_hr1);
        PERFORM pg_temp._clear(c_atomic, ARRAY['ASSETS','ACCESS','FINANCE','HANDOVER','HR'], ARRAY[]::text[], v_run || 'atomic', v_clr, v_hr1);

        -- fixtures (as the manager so the audit triggers have an actor)
        PERFORM pg_temp._as(v_hr1);
        -- E2 (completes): two ACTIVE contracts, plus items in TERMINAL states which must NOT block
        PERFORM pg_temp._mkctr(gen_random_uuid(), v_run || '-m1', v_emp2, 'ACTIVE', current_date - 100, NULL);
        PERFORM pg_temp._mkctr(gen_random_uuid(), v_run || '-m2', v_emp2, 'ACTIVE', current_date - 50, current_date + 365);
        INSERT INTO leave.leave_requests (id, employee_id, leave_type_id, start_date, end_date, total_days, request_status, submitted_at, hr_employee_id, created_at, updated_at, version)
        VALUES (v_lv_ok, t_lv_emp, t_lv_type, date '2099-04-01', date '2099-04-02', 2, 'APPROVED', now(), v_emp2, now(), now(), 1);
        INSERT INTO assets.asset_requests (id, employee_id, asset_category_id, justification, request_status, submitted_at, hr_employee_id, created_at, updated_at, version)
        VALUES (v_ar_ok, t_a_emp, t_a_cat, 'off008 terminal', 'CANCELLED', now(), v_emp2, now(), now(), 1);
        INSERT INTO attendance.correction_requests (id, attendance_day_id, employee_id, requested_check_in, reason, request_status, submitted_at, hr_employee_id, created_at, updated_at, version)
        VALUES (v_co_ok, t_c_day, t_c_emp, now(), 'off008 terminal', 'APPROVED', now(), v_emp2, now(), now(), 1);
        -- E3 (blocked): one open item of each blocker type
        INSERT INTO leave.leave_requests (id, employee_id, leave_type_id, start_date, end_date, total_days, request_status, submitted_at, hr_employee_id, created_at, updated_at, version)
        VALUES (v_lv, t_lv_emp, t_lv_type, date '2099-03-02', date '2099-03-03', 2, 'SUBMITTED', now(), v_emp3, now(), now(), 1);
        INSERT INTO attendance.correction_requests (id, attendance_day_id, employee_id, requested_check_in, reason, request_status, submitted_at, hr_employee_id, created_at, updated_at, version)
        VALUES (v_co, t_c_day, t_c_emp, now(), 'off008 open', 'SUBMITTED', now(), v_emp3, now(), now(), 1);
        INSERT INTO assets.asset_requests (id, employee_id, asset_category_id, justification, request_status, submitted_at, hr_employee_id, created_at, updated_at, version)
        VALUES (v_ar, t_a_emp, t_a_cat, 'off008 open', 'APPROVED', now(), v_emp3, now(), now(), 1);
        PERFORM pg_temp._mkctr(v_ct, v_run || '-pend', v_emp3, 'PENDING_APPROVAL', current_date, NULL);
        -- E8 (atomicity): the first contract (lower id) terminates fine, the second starts in the future -> the sanctioned function refuses
        PERFORM pg_temp._mkctr(v_c_good, v_run || '-g', v_emp8, 'ACTIVE', current_date - 100, NULL);
        PERFORM pg_temp._mkctr(v_c_bad,  v_run || '-b', v_emp8, 'ACTIVE', current_date + 30, NULL);
        -- E6: an unreturned asset assignment appears AFTER the ASSETS sign-off
        INSERT INTO assets.assets (id, asset_category_id, asset_code, asset_name, serial_number, current_status, created_at, updated_at, version)
        VALUES (v_asset, v_cat, 'OFF008-' || v_run, 'off008 asset', 'OFF008' || v_run, 'AVAILABLE', now(), now(), 1);
        INSERT INTO assets.asset_assignments (id, asset_request_id, asset_id, employee_id, hr_employee_id, assigned_by, assigned_at, created_at, version)
        VALUES (v_asg, v_tpl.asset_request_id, v_asset, v_tpl.employee_id, v_emp6, v_tpl.assigned_by, now(), now(), 1);

        v_res := v_res || ARRAY['0d-fixture-states|' || CASE WHEN
              (SELECT count(*) FROM offboarding.cases WHERE id IN (c_self, c_main, c_block, c_early, c_incomp, c_asset, c_res, c_atomic) AND status = 'IN_CLEARANCE') = 8
          AND (SELECT status::text FROM offboarding.cases WHERE id = c_appr) = 'APPROVED' THEN 'PASS' ELSE 'FAIL' END];

        -- 1. authentication, authorization, stage
        PERFORM pg_temp._as(NULL);
        v_res := v_res || ARRAY['1a-unauthenticated-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_main, v_k || 'u1')), 'OFFBOARDING_UNAUTHENTICATED')];
        PERFORM pg_temp._as(v_clr);
        v_res := v_res || ARRAY['1b-clearance-holder-without-manage-cannot-complete|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_main, v_k || 'u2')), 'OFFBOARDING_NOT_AUTHORIZED')];
        PERFORM pg_temp._as(v_hr1);
        v_res := v_res || ARRAY['1c-blank-idempotency-key-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_main, '  ')), 'OFFBOARDING_IDEMPOTENCY_KEY_REQUIRED')];
        v_res := v_res || ARRAY['1d-unknown-case-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', gen_random_uuid(), v_k || 'u3')), 'OFFBOARDING_CASE_NOT_FOUND')];
        v_res := v_res || ARRAY['1e-approved-but-not-in-clearance-case-not-completable|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_appr, v_k || 'u4')), 'OFFBOARDING_CASE_NOT_COMPLETABLE')];
        PERFORM pg_temp._as(v_e1u);
        v_res := v_res || ARRAY['1f-manager-cannot-complete-their-own-case|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_self, v_k || 'u5')), 'OFFBOARDING_CANNOT_COMPLETE_OWN_CASE')];

        -- 2. date, clearance, assets, open items
        PERFORM pg_temp._as(v_hr1);
        v_err := pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_early, v_k || 'd1'));
        v_res := v_res || ARRAY['2a-before-last-working-date-rejected-even-when-fully-cleared|' || pg_temp._expect(v_err, 'OFFBOARDING_BEFORE_LAST_WORKING_DATE')];
        v_err := pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_incomp, v_k || 'd2'));
        v_res := v_res || ARRAY['2b-incomplete-clearance-lists-the-open-domains|' ||
            CASE WHEN v_err LIKE 'OFFBOARDING_CLEARANCE_INCOMPLETE%' AND v_err LIKE '%ASSETS%' AND v_err LIKE '%FINANCE%' AND v_err LIKE '%HANDOVER%' AND v_err LIKE '%HR%' AND v_err NOT LIKE '%ACCESS,%' THEN 'PASS' ELSE 'FAIL: ' || coalesce(v_err, 'no error') END];
        v_err := pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_asset, v_k || 'd3'));
        v_res := v_res || ARRAY['2c-assets-rechecked-independently-of-the-signoff|' || pg_temp._expect(v_err, 'OFFBOARDING_ASSETS_OUTSTANDING')];
        v_err := pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_block, v_k || 'd4'));
        v_det := pg_temp._errd(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_block, v_k || 'd4'));
        v_res := v_res || ARRAY['2d-open-items-block-with-a-structured-list-of-type-and-id|' ||
            CASE WHEN v_err LIKE 'OFFBOARDING_OPEN_ITEMS_BLOCK: 4 %'
                  AND v_det::jsonb @> jsonb_build_array(jsonb_build_object('type', 'LEAVE_REQUEST', 'record_id', v_lv))
                  AND v_det::jsonb @> jsonb_build_array(jsonb_build_object('type', 'ATTENDANCE_CORRECTION_REQUEST', 'record_id', v_co))
                  AND v_det::jsonb @> jsonb_build_array(jsonb_build_object('type', 'ASSET_REQUEST', 'record_id', v_ar))
                  AND v_det::jsonb @> jsonb_build_array(jsonb_build_object('type', 'CONTRACT_APPROVAL', 'record_id', v_ct))
                  AND jsonb_array_length(v_det::jsonb) = 4 THEN 'PASS' ELSE 'FAIL: ' || coalesce(v_err, 'no error') || ' detail=' || coalesce(v_det, '') END];
        v_res := v_res || ARRAY['2e-only-employee-scoped-items-block-terminal-states-and-other-employees-do-not|' ||
            CASE WHEN offboarding._completion_blockers(v_emp2) = '[]'::jsonb AND jsonb_array_length(offboarding._completion_blockers(v_emp3)) = 4 THEN 'PASS'
                 ELSE 'FAIL: emp2=' || offboarding._completion_blockers(v_emp2)::text END];

        -- 3. atomicity: the second contract cannot be terminated, so NOTHING of the completion may remain
        v_err := pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_atomic, v_k || 'a1'));
        v_res := v_res || ARRAY['3a-failed-contract-termination-aborts-the-completion|' || pg_temp._expect(v_err, 'HR_TERMINATION_BEFORE_EFFECTIVE_FROM')];
        v_res := v_res || ARRAY['3b-nothing-persisted-contracts-employee-case-events-key|' ||
            CASE WHEN (SELECT count(*) FROM hr.contracts WHERE id IN (v_c_good, v_c_bad) AND status = 'ACTIVE') = 2
                  AND (SELECT employment_status::text || '|' || coalesce(termination_date::text, 'null') FROM hr.employees WHERE id = v_emp8) = 'ACTIVE|null'
                  AND (SELECT status::text FROM offboarding.cases WHERE id = c_atomic) = 'IN_CLEARANCE'
                  AND (SELECT count(*) FROM offboarding.outbox_events WHERE case_id = c_atomic) = 0
                  AND (SELECT count(*) FROM offboarding.case_history WHERE case_id = c_atomic AND event_type = 'COMPLETED') = 0
                  AND (SELECT count(*) FROM hr.employee_status_history WHERE employee_id = v_emp8 AND source = 'SANCTIONED_TERMINATION') = 0
                  AND NOT EXISTS (SELECT 1 FROM offboarding.request_idempotency WHERE idempotency_key = v_k || 'a1')
                 THEN 'PASS' ELSE 'FAIL' END];
        SELECT count(*) INTO v_n FROM offboarding.outbox_events WHERE case_id IN (c_self, c_early, c_incomp, c_asset, c_block, c_appr, c_atomic);
        SELECT count(*) INTO v_n2 FROM offboarding.request_idempotency WHERE idempotency_key LIKE v_k || 'u%' OR idempotency_key LIKE v_k || 'd%';
        SELECT count(*) INTO v_n3 FROM hr.employees WHERE id IN (v_emp1, v_emp3, v_emp4, v_emp5, v_emp6, v_emp8, v_emp9) AND employment_status = 'TERMINATED';
        v_res := v_res || ARRAY['3c-every-rejected-call-changed-nothing|' || CASE WHEN v_n = 0 AND v_n2 = 0 AND v_n3 = 0 THEN 'PASS' ELSE 'FAIL: events=' || v_n || ' keys=' || v_n2 || ' terminated=' || v_n3 END];

        -- 4. happy path: five domains (two waived), two ACTIVE contracts, terminal-state items present
        PERFORM pg_temp._as(v_hr1);
        SELECT version INTO v_cv FROM offboarding.cases WHERE id = c_main;
        v_r := offboarding.complete_offboarding(c_main, v_k || 'ok1');
        v_res := v_res || ARRAY['4a-completed-result-two-contracts-version-bumped-once|' ||
            CASE WHEN v_r->>'case_status' = 'COMPLETED' AND (v_r->>'contracts_terminated')::int = 2 AND (v_r->>'case_version')::int = v_cv + 1
                      AND (v_r->>'termination_date')::date = v_today AND v_r->>'idempotent_replay' = 'false' THEN 'PASS' ELSE 'FAIL: ' || v_r::text END];
        v_res := v_res || ARRAY['4b-employee-terminated-with-last-working-date-and-status-history|' ||
            CASE WHEN (SELECT employment_status::text || '|' || termination_date::text FROM hr.employees WHERE id = v_emp2) = 'TERMINATED|' || v_today::text
                  AND (SELECT count(*) FROM hr.employee_status_history WHERE employee_id = v_emp2 AND new_status = 'TERMINATED' AND source = 'SANCTIONED_TERMINATION' AND effective_date = v_today AND changed_by = v_hr1) = 1
                 THEN 'PASS' ELSE 'FAIL' END];
        v_res := v_res || ARRAY['4c-all-active-contracts-terminated-with-effective-date-equal-last-working-date|' ||
            CASE WHEN (SELECT count(*) FROM hr.contracts c JOIN hr.contract_versions v ON v.id = c.current_version_id
                        WHERE c.hr_employee_id = v_emp2 AND c.status = 'TERMINATED' AND v.effective_to = v_today) = 2
                  AND (SELECT count(*) FROM hr.contracts WHERE hr_employee_id = v_emp2 AND status = 'ACTIVE') = 0 THEN 'PASS' ELSE 'FAIL' END];
        v_res := v_res || ARRAY['4d-case-records-completer-time-and-history-event|' ||
            CASE WHEN (SELECT completed_by FROM offboarding.cases WHERE id = c_main) = v_hr1 AND (SELECT completed_at IS NOT NULL FROM offboarding.cases WHERE id = c_main)
                  AND (SELECT count(*) FROM offboarding.case_history WHERE case_id = c_main AND event_type = 'COMPLETED' AND from_status = 'IN_CLEARANCE' AND to_status = 'COMPLETED' AND actor = v_hr1
                        AND (detail->>'contracts_terminated_count')::int = 2) = 1 THEN 'PASS' ELSE 'FAIL' END];

        -- 5. outbox: two events, the standard envelope, deterministic idempotency keys, no sensitive reason
        SELECT * INTO v_ev1 FROM offboarding.outbox_events WHERE case_id = c_main AND event_type = 'employee.offboarding.completed';
        SELECT * INTO v_ev2 FROM offboarding.outbox_events WHERE case_id = c_main AND event_type = 'ACCESS_REVOCATION_REQUESTED';
        v_res := v_res || ARRAY['5a-exactly-two-events-and-two-pending-deliveries|' ||
            CASE WHEN (SELECT count(*) FROM offboarding.outbox_events WHERE case_id = c_main) = 2 AND v_ev1.id IS NOT NULL AND v_ev2.id IS NOT NULL
                  AND (SELECT count(*) FROM offboarding.outbox_delivery WHERE event_id IN (v_ev1.id, v_ev2.id) AND delivery_status = 'PENDING') = 2 THEN 'PASS' ELSE 'FAIL' END];
        v_res := v_res || ARRAY['5b-finance-event-envelope-complete-and-correct|' ||
            CASE WHEN (v_ev1.payload->>'event_id')::uuid = v_ev1.id AND v_ev1.payload->>'schema_version' = '1' AND v_ev1.payload->>'source_module' = 'offboarding'
                  AND (v_ev1.payload->>'organization_id')::uuid = v_org AND v_ev1.payload->>'idempotency_key' = 'offboarding:employee.offboarding.completed:' || c_main::text
                  AND v_ev1.payload ? 'occurred_at' AND (v_ev1.payload->>'effective_business_date')::date = v_today AND (v_ev1.payload->>'actor_id')::uuid = v_hr1
                  AND (v_ev1.payload->>'correlation_id')::uuid = c_main AND v_ev1.payload->>'processing_status' = 'PENDING'
                  AND v_ev1.payload->>'payload_hash' = encode(extensions.digest((v_ev1.payload->'payload')::text, 'sha256'), 'hex')
                 THEN 'PASS' ELSE 'FAIL: ' || v_ev1.payload::text END];
        v_res := v_res || ARRAY['5c-finance-payload-v1-fields-exact|' ||
            CASE WHEN (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_ev1.payload->'payload') k) =
                      ARRAY['case_id','case_type','completed_at','final_settlement_required','hr_employee_id','last_working_date','person_id','termination_date']
                  AND (v_ev1.payload->'payload'->>'final_settlement_required')::boolean AND v_ev1.payload->'payload'->>'case_type' = 'TERMINATION'
                  AND (v_ev1.payload->'payload'->>'case_id')::uuid = c_main AND (v_ev1.payload->'payload'->>'termination_date')::date = v_today THEN 'PASS' ELSE 'FAIL: ' || (v_ev1.payload->'payload')::text END];
        v_res := v_res || ARRAY['5d-no-termination-reason-in-either-event|' ||
            CASE WHEN position('secretdetail' IN v_ev1.payload::text) = 0 AND position('secretdetail' IN v_ev2.payload::text) = 0
                  AND position('CONDUCT' IN v_ev1.payload::text) = 0 AND position('CONDUCT' IN v_ev2.payload::text) = 0
                  AND position('reason' IN v_ev1.payload::text) = 0 AND position('reason' IN v_ev2.payload::text) = 0 THEN 'PASS' ELSE 'FAIL' END];
        v_res := v_res || ARRAY['5e-access-revocation-event-envelope-and-payload|' ||
            CASE WHEN v_ev2.payload->>'idempotency_key' = 'offboarding:ACCESS_REVOCATION_REQUESTED:' || c_main::text AND v_ev2.payload->>'schema_version' = '1'
                  AND (v_ev2.payload->>'event_id')::uuid = v_ev2.id AND (v_ev2.payload->'payload'->>'hr_employee_id')::uuid = v_emp2
                  AND v_ev2.payload->>'payload_hash' = encode(extensions.digest((v_ev2.payload->'payload')::text, 'sha256'), 'hex') THEN 'PASS' ELSE 'FAIL: ' || v_ev2.payload::text END];
        v_res := v_res || ARRAY['5f-events-are-immutable|' || pg_temp._expect(pg_temp._err(format('UPDATE offboarding.outbox_events SET event_type = %L WHERE id = %L', 'x', v_ev1.id)), 'OFFBOARDING_')];

        -- 6. replay, mismatch, terminal
        SELECT version INTO v_cv FROM offboarding.cases WHERE id = c_main;
        SELECT count(*) INTO v_hist FROM offboarding.case_history WHERE case_id = c_main;
        v_r2 := offboarding.complete_offboarding(c_main, v_k || 'ok1');
        v_res := v_res || ARRAY['6a-replay-returns-identical-result|' || CASE WHEN (v_r - 'idempotent_replay') = (v_r2 - 'idempotent_replay') AND v_r2->>'idempotent_replay' = 'true' THEN 'PASS' ELSE 'FAIL: ' || v_r2::text END];
        v_res := v_res || ARRAY['6b-replay-adds-no-event-no-history-no-version-bump|' ||
            CASE WHEN (SELECT count(*) FROM offboarding.outbox_events WHERE case_id = c_main) = 2 AND (SELECT count(*) FROM offboarding.case_history WHERE case_id = c_main) = v_hist
                  AND (SELECT version FROM offboarding.cases WHERE id = c_main) = v_cv THEN 'PASS' ELSE 'FAIL' END];
        PERFORM pg_temp._as(v_hr2);
        v_res := v_res || ARRAY['6c-same-key-by-another-actor-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_main, v_k || 'ok1')), 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH')];
        v_res := v_res || ARRAY['6d-new-key-on-a-completed-case-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.complete_offboarding(%L::uuid, %L)', c_main, v_k || 'ok1b')), 'OFFBOARDING_CASE_NOT_COMPLETABLE')];
        v_res := v_res || ARRAY['6e-completed-case-cannot-be-cancelled-or-updated|' ||
            CASE WHEN pg_temp._err(format('SELECT offboarding.cancel_termination(%L::uuid, %L, %L)', c_main, 'late', v_k || 'ok2')) LIKE 'OFFBOARDING_CASE_NOT_CANCELLABLE%'
                  AND pg_temp._err(format('UPDATE offboarding.cases SET reason_detail = %L WHERE id = %L', 'tamper', c_main)) LIKE 'OFFBOARDING_TERMINAL_STATUS%' THEN 'PASS' ELSE 'FAIL' END];

        -- 7. a resignation with NO contract completes (a missing ACTIVE contract does not block)
        PERFORM pg_temp._as(v_hr2);
        v_r := offboarding.complete_offboarding(c_res, v_k || 'res1');
        SELECT * INTO v_ev1 FROM offboarding.outbox_events WHERE case_id = c_res AND event_type = 'employee.offboarding.completed';
        v_res := v_res || ARRAY['7a-resignation-without-contracts-completes-and-terminates-the-employee|' ||
            CASE WHEN v_r->>'case_status' = 'COMPLETED' AND (v_r->>'contracts_terminated')::int = 0
                  AND (SELECT employment_status::text FROM hr.employees WHERE id = v_emp7) = 'TERMINATED'
                  AND v_ev1.payload->'payload'->>'case_type' = 'RESIGNATION' THEN 'PASS' ELSE 'FAIL: ' || v_r::text END];

        RAISE EXCEPTION 'OFF008_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'OFF008_ROLLBACK' THEN v_res := v_res || ARRAY['9-main-block|FAIL: ' || SQLSTATE || ' ' || SQLERRM]; END IF;
    END;

    INSERT INTO "_off008_results" SELECT split_part(x, '|', 1), substr(x, strpos(x, '|') + 1) FROM unnest(v_res) AS x;
END;
$$;

DO $$
DECLARE v_fail int; v_total int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE result <> 'PASS'), count(*),
           string_agg(step || ' = ' || result, ' | ' ORDER BY step) FILTER (WHERE result <> 'PASS')
      INTO v_fail, v_total, v_list FROM "_off008_results";
    IF v_total = 0 THEN RAISE EXCEPTION 'OFFBOARDING 008 TEST: no results recorded'; END IF;
    IF v_fail > 0 THEN RAISE EXCEPTION 'OFFBOARDING 008 TEST FAILED (% of % checks): %', v_fail, v_total, v_list; END IF;
    RAISE NOTICE 'OFFBOARDING 008 TEST PASSED: % checks, 0 failures', v_total;
END;
$$;

SELECT step, result FROM "_off008_results" ORDER BY step;
-- ========================================================================
-- END TEST_offboarding_008_complete.sql
-- ========================================================================
