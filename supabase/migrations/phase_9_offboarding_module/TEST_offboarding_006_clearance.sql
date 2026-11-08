-- ========================================================================
-- TEST_offboarding_006_clearance.sql
-- Run AFTER 001-006 (corrected 005 applied) and the seed runner. Everything lives in ONE rolled-back sub-block;
-- nothing persists. Needs at least one existing assets.asset_assignments row (used as a foreign-key template,
-- same as TEST_P02). Gate: any FAIL raises; all PASS completes with a notice.
-- ========================================================================
DROP TABLE IF EXISTS "_off006_results";
CREATE TEMP TABLE "_off006_results" ("step" text, "result" text);

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
-- start a termination as p_creator and (optionally) approve it as p_approver; returns the case id
CREATE FUNCTION pg_temp._mkcase(p_emp uuid, p_tag text, p_creator uuid, p_approver uuid, p_approve boolean) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_r jsonb; v_case uuid; v_req uuid; v_step uuid; v_ver int;
BEGIN
    PERFORM pg_temp._as(p_creator);
    v_r := offboarding.start_termination(p_emp, 'off006-' || p_tag, current_date + 10, 'CONDUCT', 'detail ' || p_tag);
    v_case := (v_r->>'case_id')::uuid; v_req := (v_r->>'workflow_request_id')::uuid;
    IF p_approve THEN
        PERFORM pg_temp._as(p_approver);
        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req;
        PERFORM workflow.process_approval_action(v_req, 'APPROVE', v_step, 'ok', NULL, 'off006-appr-' || p_tag, v_ver);
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
    v_acc uuid := '00000000-0000-0000-0000-0000000000a9';
    v_e1u uuid := '00000000-0000-0000-0000-0000000000a5';
    v_oth uuid := '00000000-0000-0000-0000-0000000000a7';
    v_emp1 uuid; v_emp2 uuid; v_emp3 uuid; v_emp4 uuid; v_emp5 uuid;
    c_self uuid; c_main uuid; c_waive uuid; c_sub uuid; c_rej uuid;
    v_r jsonb; v_r2 jsonb; v_req uuid; v_step uuid; v_ver int; v_s text; v_err text; v_n int; v_n2 int;
    v_tpl record; v_cat uuid; v_asset uuid := gen_random_uuid(); v_asg uuid := gen_random_uuid();
    v_perm record; v_sig text; v_oid oid; v_k text := 'off006k-' || substr(md5(random()::text), 1, 6) || '-';
    v_hist_before int; v_cv int; v_tv int;
BEGIN
    SELECT id INTO v_org FROM core.organizations WHERE code = 'OSYSTIC';
    SELECT id INTO v_hr1 FROM auth.users WHERE core.has_permission(id, 'WORKFLOW_CONFIG_MANAGE') AND id NOT IN (v_hr2, v_clr, v_acc, v_e1u, v_oth) ORDER BY created_at LIMIT 1;
    IF v_org IS NULL OR v_hr1 IS NULL THEN RAISE EXCEPTION 'SETUP: org=%, hr1=%', v_org, v_hr1; END IF;
    IF (SELECT count(*) FROM auth.users WHERE id IN (v_hr2, v_clr, v_acc, v_e1u, v_oth)) <> 5 THEN RAISE EXCEPTION 'SETUP: fixture users a1/a5/a6/a7/a9 are missing'; END IF;
    IF (SELECT count(*) FROM workflow.workflow_definitions d JOIN workflow.workflow_versions v ON v.workflow_definition_id = d.id WHERE d.module = 'offboarding' AND v.status = 'ACTIVE') <> 2 THEN
        RAISE EXCEPTION 'SETUP: offboarding workflow definitions are not ACTIVE - run the seed runner first'; END IF;
    SELECT * INTO v_tpl FROM assets.asset_assignments ORDER BY assigned_at LIMIT 1;
    IF v_tpl.id IS NULL THEN RAISE EXCEPTION 'SETUP: need at least one existing assets.asset_assignments row as a template'; END IF;
    SELECT asset_category_id INTO v_cat FROM assets.assets WHERE id = v_tpl.asset_id;

    -- 0. privileges and shape
    FOREACH v_sig IN ARRAY ARRAY['offboarding.record_clearance(uuid,character varying,text,character varying)',
                                 'offboarding.waive_clearance(uuid,character varying,text,character varying)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        v_res := v_res || ARRAY['0a-' || split_part(split_part(v_sig, '(', 1), '.', 2) || '-authenticated-only-definer-pinned-path|' ||
            CASE WHEN v_oid IS NOT NULL AND has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
                  AND (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) AND (SELECT proconfig::text LIKE '%search_path%' FROM pg_proc WHERE oid = v_oid)
                  AND NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))
                 THEN 'PASS' ELSE 'FAIL: ' || v_sig END];
    END LOOP;
    v_oid := to_regprocedure('offboarding._clearance_action(uuid,uuid,text,text,text,character varying)')::oid;
    v_res := v_res || ARRAY['0b-internal-clearance-function-closed-to-app-roles|' ||
        CASE WHEN v_oid IS NOT NULL AND NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE') THEN 'PASS' ELSE 'FAIL' END];

    BEGIN
        PERFORM pg_temp._as(v_hr1);
        -- temporary roles (rolled back): managers, access-only, all-clearance
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF006_MGR_' || v_run, 'temp mgr', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code = 'OFFBOARDING_MANAGE';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_hr1, v_role), (v_hr2, v_role);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF006_ACC_' || v_run, 'temp acc', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code = 'OFFBOARDING_CLEARANCE_ACCESS';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_acc, v_role), (v_e1u, v_role);
        INSERT INTO core.roles (name, display_name, description) VALUES ('TEMP_OFF006_ALL_' || v_run, 'temp all clearance', 'temporary') RETURNING id INTO v_role;
        INSERT INTO core.role_permissions (role_id, permission_id) SELECT v_role, id FROM core.permissions WHERE code LIKE 'OFFBOARDING\_CLEARANCE\_%';
        INSERT INTO core.user_roles (user_id, role_id) VALUES (v_clr, v_role);

        -- employees (emp1 is linked to e1u so it can test self-clearance)
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF006 E1', 'off006-e1-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO core.person_user_links (person_id, user_id) VALUES (v_p, v_e1u);
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF006-1-' || v_run, current_date - 400) RETURNING id INTO v_emp1;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF006 E2', 'off006-e2-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF006-2-' || v_run, current_date - 400) RETURNING id INTO v_emp2;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF006 E3', 'off006-e3-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF006-3-' || v_run, current_date - 400) RETURNING id INTO v_emp3;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF006 E4', 'off006-e4-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF006-4-' || v_run, current_date - 400) RETURNING id INTO v_emp4;
        INSERT INTO core.people (organization_id, full_name, primary_email) VALUES (v_org, 'OFF006 E5', 'off006-e5-' || v_run || '@example.invalid') RETURNING id INTO v_p;
        INSERT INTO hr.employees (person_id, employee_number, hire_date) VALUES (v_p, 'OFF006-5-' || v_run, current_date - 400) RETURNING id INTO v_emp5;

        c_self  := pg_temp._mkcase(v_emp1, v_run || '-self',  v_hr1, v_hr2, true);
        c_main  := pg_temp._mkcase(v_emp2, v_run || '-main',  v_hr1, v_hr2, true);
        c_waive := pg_temp._mkcase(v_emp3, v_run || '-waive', v_hr1, v_hr2, true);
        c_sub   := pg_temp._mkcase(v_emp4, v_run || '-sub',   v_hr1, v_hr2, false);
        c_rej   := pg_temp._mkcase(v_emp5, v_run || '-rej',   v_hr1, v_hr2, false);
        -- reject c_rej as the second manager
        SELECT workflow_request_id INTO v_req FROM offboarding.cases WHERE id = c_rej;
        PERFORM pg_temp._as(v_hr2);
        SELECT s.id INTO v_step FROM workflow.approval_steps s WHERE s.approval_request_id = v_req AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
        SELECT version INTO v_ver FROM workflow.approval_requests WHERE id = v_req;
        PERFORM workflow.process_approval_action(v_req, 'REJECT', v_step, 'rejected in test', NULL, v_k || 'rej', v_ver);

        -- 1. authentication, domain, key
        PERFORM pg_temp._as(NULL);
        v_res := v_res || ARRAY['1a-unauthenticated-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_main, 'ACCESS', 'x', v_k || 'u1')), 'OFFBOARDING_UNAUTHENTICATED')];
        PERFORM pg_temp._as(v_clr);
        v_res := v_res || ARRAY['1b-invalid-domain-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_main, 'PAYROLL', 'x', v_k || 'u2')), 'OFFBOARDING_INVALID_DOMAIN')];
        v_res := v_res || ARRAY['1c-blank-idempotency-key-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_main, 'ACCESS', 'x', '   ')), 'OFFBOARDING_IDEMPOTENCY_KEY_REQUIRED')];

        -- 2. permission isolation
        PERFORM pg_temp._as(v_acc);
        v_res := v_res || ARRAY['2a-access-only-user-cannot-sign-off-assets|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_main, 'ASSETS', 'x', v_k || 'p1')), 'OFFBOARDING_NOT_AUTHORIZED')];
        PERFORM pg_temp._as(v_hr1);
        v_res := v_res || ARRAY['2b-offboarding-manage-alone-cannot-sign-off-a-domain|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_main, 'ACCESS', 'x', v_k || 'p2')), 'OFFBOARDING_NOT_AUTHORIZED')];
        PERFORM pg_temp._as(v_oth);
        v_res := v_res || ARRAY['2c-user-without-any-offboarding-permission-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_main, 'ACCESS', 'x', v_k || 'p3')), 'OFFBOARDING_NOT_AUTHORIZED')];
        PERFORM pg_temp._as(v_clr);
        v_res := v_res || ARRAY['2d-clearance-holder-without-manage-cannot-waive|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.waive_clearance(%L::uuid, %L, %L, %L)', c_main, 'FINANCE', 'because', v_k || 'p4')), 'OFFBOARDING_NOT_AUTHORIZED')];

        -- 3. stage and self rules
        v_res := v_res || ARRAY['3a-submitted-case-not-in-clearance-stage|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_sub, 'ACCESS', 'x', v_k || 's1')), 'OFFBOARDING_CASE_NOT_IN_CLEARANCE_STAGE')];
        v_res := v_res || ARRAY['3b-rejected-case-not-in-clearance-stage|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_rej, 'ACCESS', 'x', v_k || 's2')), 'OFFBOARDING_CASE_NOT_IN_CLEARANCE_STAGE')];
        v_res := v_res || ARRAY['3c-unknown-case-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', gen_random_uuid(), 'ACCESS', 'x', v_k || 's3')), 'OFFBOARDING_CASE_NOT_FOUND')];
        PERFORM pg_temp._as(v_e1u);
        v_res := v_res || ARRAY['3d-cannot-sign-off-your-own-offboarding-case|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_self, 'ACCESS', 'x', v_k || 's4')), 'OFFBOARDING_CANNOT_CLEAR_OWN_CASE')];
        SELECT count(*) INTO v_n FROM offboarding.clearance_tasks WHERE case_id IN (c_main, c_sub, c_rej, c_self) AND status <> 'PENDING';
        v_res := v_res || ARRAY['3e-every-rejected-call-changed-nothing|' || CASE WHEN v_n = 0 AND (SELECT status::text FROM offboarding.cases WHERE id = c_main) = 'APPROVED' THEN 'PASS' ELSE 'FAIL: non-pending=' || v_n END];

        -- 4. happy path: first sign-off starts clearance exactly once
        SELECT version INTO v_cv FROM offboarding.cases WHERE id = c_main;
        v_res := v_res || ARRAY['4a-approved-case-starts-at-version-2|' || CASE WHEN v_cv = 2 THEN 'PASS' ELSE 'FAIL: ' || v_cv END];
        PERFORM pg_temp._as(v_acc);
        v_r := offboarding.record_clearance(c_main, 'access', 'access revoked', v_k || 'k1');
        v_res := v_res || ARRAY['4b-first-signoff-clears-task-and-starts-clearance-once|' ||
            CASE WHEN v_r->>'task_status' = 'CLEARED' AND v_r->>'case_status' = 'IN_CLEARANCE' AND (v_r->>'case_version')::int = 3 AND (v_r->>'task_version')::int = 2 AND v_r->>'idempotent_replay' = 'false'
                 THEN 'PASS' ELSE 'FAIL: ' || v_r::text END];
        SELECT cleared_by::text || '|' || coalesce(clearance_note, '') INTO v_s FROM offboarding.clearance_tasks WHERE case_id = c_main AND domain = 'ACCESS';
        SELECT count(*) INTO v_n FROM offboarding.case_history WHERE case_id = c_main;
        v_res := v_res || ARRAY['4c-signoff-recorded-with-actor-note-and-history|' ||
            CASE WHEN v_s = v_acc::text || '|access revoked' AND v_n = 4 AND (SELECT clearance_started_at IS NOT NULL FROM offboarding.cases WHERE id = c_main) THEN 'PASS' ELSE 'FAIL: ' || v_s || ' history=' || v_n END];
        PERFORM pg_temp._as(v_clr);
        v_r2 := offboarding.record_clearance(c_main, 'HR', 'hr done', v_k || 'k2');
        v_res := v_res || ARRAY['4d-later-signoff-does-not-touch-the-case-row|' ||
            CASE WHEN (v_r2->>'case_version')::int = 3 AND (v_r2->>'task_version')::int = 2 AND v_r2->>'case_status' = 'IN_CLEARANCE'
                      AND (SELECT count(*) FROM offboarding.case_history WHERE case_id = c_main) = 5 THEN 'PASS' ELSE 'FAIL: ' || v_r2::text END];

        -- 5. replay, mismatch, final tasks
        PERFORM pg_temp._as(v_acc);
        SELECT count(*) INTO v_hist_before FROM offboarding.case_history WHERE case_id = c_main;
        v_r2 := offboarding.record_clearance(c_main, 'access', 'access revoked', v_k || 'k1');
        v_res := v_res || ARRAY['5a-replay-returns-identical-result|' || CASE WHEN (v_r - 'idempotent_replay') = (v_r2 - 'idempotent_replay') AND v_r2->>'idempotent_replay' = 'true' THEN 'PASS' ELSE 'FAIL: ' || v_r2::text END];
        SELECT version INTO v_cv FROM offboarding.cases WHERE id = c_main;
        SELECT version INTO v_tv FROM offboarding.clearance_tasks WHERE case_id = c_main AND domain = 'ACCESS';
        SELECT count(*) INTO v_n FROM offboarding.request_idempotency WHERE idempotency_key = v_k || 'k1';
        v_res := v_res || ARRAY['5b-replay-changes-nothing-no-new-history-no-version-bump|' ||
            CASE WHEN v_cv = 3 AND v_tv = 2 AND v_n = 1 AND (SELECT count(*) FROM offboarding.case_history WHERE case_id = c_main) = v_hist_before THEN 'PASS' ELSE 'FAIL: case=' || v_cv || ' task=' || v_tv || ' keys=' || v_n END];
        v_res := v_res || ARRAY['5c-same-key-different-note-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_main, 'ACCESS', 'a different note', v_k || 'k1')), 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH')];
        v_res := v_res || ARRAY['5d-new-key-on-an-already-cleared-task-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_main, 'ACCESS', 'again', v_k || 'k1b')), 'OFFBOARDING_CLEARANCE_ALREADY_FINAL')];
        SELECT count(*) INTO v_n FROM offboarding.clearance_tasks WHERE case_id = c_main AND status = 'PENDING';
        v_res := v_res || ARRAY['5e-rejected-calls-left-no-trace|' || CASE WHEN v_n = 3 AND (SELECT count(*) FROM offboarding.case_history WHERE case_id = c_main) = v_hist_before AND NOT EXISTS (SELECT 1 FROM offboarding.request_idempotency WHERE idempotency_key IN (v_k || 'k1b')) THEN 'PASS' ELSE 'FAIL: pending=' || v_n END];

        -- 6. ASSETS: independent verification of zero unreturned assignments (and never waivable)
        PERFORM pg_temp._as(v_hr1);
        INSERT INTO assets.assets (id, asset_category_id, asset_code, asset_name, serial_number, current_status, created_at, updated_at, version)
        VALUES (v_asset, v_cat, 'OFF006-' || v_run, 'off006 asset', 'OFF006' || v_run, 'AVAILABLE', now(), now(), 1);
        INSERT INTO assets.asset_assignments (id, asset_request_id, asset_id, employee_id, hr_employee_id, assigned_by, assigned_at, created_at, version)
        VALUES (v_asg, v_tpl.asset_request_id, v_asset, v_tpl.employee_id, v_emp2, v_tpl.assigned_by, now(), now(), 1);
        PERFORM pg_temp._as(v_clr);
        v_err := pg_temp._err(format('SELECT offboarding.record_clearance(%L::uuid, %L, %L, %L)', c_main, 'ASSETS', 'x', v_k || 'a1'));
        v_res := v_res || ARRAY['6a-assets-signoff-blocked-while-an-assignment-is-unreturned|' || pg_temp._expect(v_err, 'OFFBOARDING_ASSETS_OUTSTANDING')];
        SELECT status::text || '|' || version::text INTO v_s FROM offboarding.clearance_tasks WHERE case_id = c_main AND domain = 'ASSETS';
        v_res := v_res || ARRAY['6b-blocked-assets-task-still-pending-version-unchanged|' || CASE WHEN v_s = 'PENDING|1' THEN 'PASS' ELSE 'FAIL: ' || v_s END];
        PERFORM pg_temp._as(v_hr1);
        v_res := v_res || ARRAY['6c-assets-clearance-can-never-be-waived-even-by-manage|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.waive_clearance(%L::uuid, %L, %L, %L)', c_main, 'ASSETS', 'we will chase the laptop later', v_k || 'a2')), 'OFFBOARDING_ASSETS_CLEARANCE_CANNOT_BE_WAIVED')];
        DELETE FROM assets.asset_assignments WHERE id = v_asg;     -- simulate "no unreturned assignment" for this employee
        PERFORM pg_temp._as(v_clr);
        v_r := offboarding.record_clearance(c_main, 'ASSETS', 'verified: nothing outstanding', v_k || 'a3');
        v_res := v_res || ARRAY['6d-assets-signoff-succeeds-once-nothing-is-outstanding|' || CASE WHEN v_r->>'task_status' = 'CLEARED' AND v_r->>'case_status' = 'IN_CLEARANCE' THEN 'PASS' ELSE 'FAIL: ' || v_r::text END];

        -- 7. waivers (case c_waive, first action is a waiver)
        PERFORM pg_temp._as(v_hr1);
        v_res := v_res || ARRAY['7a-waiver-without-reason-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.waive_clearance(%L::uuid, %L, %L, %L)', c_waive, 'FINANCE', '   ', v_k || 'w1')), 'OFFBOARDING_WAIVER_REASON_REQUIRED')];
        SELECT status::text INTO v_s FROM offboarding.cases WHERE id = c_waive;
        v_res := v_res || ARRAY['7b-rejected-waiver-did-not-start-clearance|' || CASE WHEN v_s = 'APPROVED' THEN 'PASS' ELSE 'FAIL: ' || v_s END];
        v_r := offboarding.waive_clearance(c_waive, 'finance', 'balance settled out of band, approved by CFO', v_k || 'w2');
        v_res := v_res || ARRAY['7c-waiver-recorded-and-starts-clearance-once|' ||
            CASE WHEN v_r->>'task_status' = 'WAIVED' AND v_r->>'case_status' = 'IN_CLEARANCE' AND (v_r->>'case_version')::int = 3 AND (v_r->>'task_version')::int = 2 THEN 'PASS' ELSE 'FAIL: ' || v_r::text END];
        SELECT waived_by::text || '|' || waiver_reason INTO v_s FROM offboarding.clearance_tasks WHERE case_id = c_waive AND domain = 'FINANCE';
        SELECT count(*) INTO v_n FROM offboarding.case_history WHERE case_id = c_waive AND event_type = 'CLEARANCE_WAIVED'
            AND detail->>'domain' = 'FINANCE' AND detail->>'reason' = 'balance settled out of band, approved by CFO' AND actor = v_hr1;
        v_res := v_res || ARRAY['7d-waiver-has-actor-reason-and-audit-history-evidence|' || CASE WHEN v_s = v_hr1::text || '|balance settled out of band, approved by CFO' AND v_n = 1 THEN 'PASS' ELSE 'FAIL: ' || v_s || ' events=' || v_n END];
        SELECT count(*) INTO v_hist_before FROM offboarding.case_history WHERE case_id = c_waive;
        v_r2 := offboarding.waive_clearance(c_waive, 'finance', 'balance settled out of band, approved by CFO', v_k || 'w2');
        SELECT count(*) INTO v_n FROM offboarding.case_history WHERE case_id = c_waive;
        v_res := v_res || ARRAY['7e-waiver-replay-identical-and-adds-nothing|' ||
            CASE WHEN (v_r - 'idempotent_replay') = (v_r2 - 'idempotent_replay') AND v_r2->>'idempotent_replay' = 'true' AND v_n = v_hist_before AND v_n = 4
                      AND (SELECT version FROM offboarding.cases WHERE id = c_waive) = 3 THEN 'PASS' ELSE 'FAIL: ' || v_r2::text || ' history=' || v_n END];
        v_res := v_res || ARRAY['7f-same-key-different-reason-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.waive_clearance(%L::uuid, %L, %L, %L)', c_waive, 'FINANCE', 'a different reason', v_k || 'w2')), 'OFFBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH')];
        v_res := v_res || ARRAY['7g-waiving-an-already-final-task-rejected|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.waive_clearance(%L::uuid, %L, %L, %L)', c_waive, 'FINANCE', 'again', v_k || 'w3')), 'OFFBOARDING_CLEARANCE_ALREADY_FINAL')];
        SELECT count(*) INTO v_n FROM offboarding.clearance_tasks WHERE case_id = c_waive AND status = 'PENDING';
        v_res := v_res || ARRAY['7h-other-four-tasks-still-pending|' || CASE WHEN v_n = 4 THEN 'PASS' ELSE 'FAIL: ' || v_n END];
        -- a signed-off task cannot afterwards be waived (and vice versa)
        PERFORM pg_temp._as(v_hr1);
        v_res := v_res || ARRAY['7i-cleared-task-cannot-be-waived-afterwards|' || pg_temp._expect(pg_temp._err(format('SELECT offboarding.waive_clearance(%L::uuid, %L, %L, %L)', c_main, 'ACCESS', 'override', v_k || 'w4')), 'OFFBOARDING_CLEARANCE_ALREADY_FINAL')];

        RAISE EXCEPTION 'OFF006_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'OFF006_ROLLBACK' THEN v_res := v_res || ARRAY['9-main-block|FAIL: ' || SQLSTATE || ' ' || SQLERRM]; END IF;
    END;

    INSERT INTO "_off006_results" SELECT split_part(x, '|', 1), substr(x, strpos(x, '|') + 1) FROM unnest(v_res) AS x;
END;
$$;

DO $$
DECLARE v_fail int; v_total int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE result <> 'PASS'), count(*),
           string_agg(step || ' = ' || result, ' | ' ORDER BY step) FILTER (WHERE result <> 'PASS')
      INTO v_fail, v_total, v_list FROM "_off006_results";
    IF v_total = 0 THEN RAISE EXCEPTION 'OFFBOARDING 006 TEST: no results recorded'; END IF;
    IF v_fail > 0 THEN RAISE EXCEPTION 'OFFBOARDING 006 TEST FAILED (% of % checks): %', v_fail, v_total, v_list; END IF;
    RAISE NOTICE 'OFFBOARDING 006 TEST PASSED: % checks, 0 failures', v_total;
END;
$$;

SELECT step, result FROM "_off006_results" ORDER BY step;
-- ========================================================================
-- END TEST_offboarding_006_clearance.sql
-- ========================================================================
