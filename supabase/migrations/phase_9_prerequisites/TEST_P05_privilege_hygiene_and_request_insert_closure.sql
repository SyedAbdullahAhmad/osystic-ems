-- ========================================================================
-- TEST_P05_privilege_hygiene_and_request_insert_closure.sql  (v2)
-- Run AFTER P05. Changes nothing (denied direct inserts leave no rows).
-- Gate: any FAIL -> RAISE EXCEPTION; zero failures -> RAISE NOTICE and normal
-- completion. The final SELECT lists every check.
-- ========================================================================
DROP TABLE IF EXISTS "_p05_results";
CREATE TEMP TABLE "_p05_results" ("step" text, "result" text);

DO $$
DECLARE
    v_t text; v_priv text; v_bad text; v_uid uuid;
    v_tables text[] := ARRAY['assets.asset_categories','assets.asset_requests','attendance.attendance_days',
        'attendance.correction_requests','core.departments','core.organizations','core.people',
        'core.person_user_links','hr.contract_requests','leave.leave_accruals','leave.leave_adjustments',
        'leave.leave_ledger','leave.leave_requests','leave.leave_types'];
    v_views text[] := ARRAY['leave.v_leave_balances','leave.v_leave_request_approvals',
        'attendance.v_correction_request_approvals','assets.v_asset_request_approvals','hr.v_contract_approvals'];
    v_req text[] := ARRAY['leave.leave_requests','attendance.correction_requests','assets.asset_requests'];
    r_leave text; r_att text; r_asset text;
BEGIN
    v_bad := '';
    FOREACH v_t IN ARRAY v_tables LOOP
        FOREACH v_priv IN ARRAY ARRAY['TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('authenticated', v_t, v_priv) OR has_table_privilege('anon', v_t, v_priv) THEN
                v_bad := v_bad || ' ' || v_priv || '@' || v_t; END IF;
        END LOOP;
    END LOOP;
    INSERT INTO "_p05_results" VALUES ('1-table-hygiene', CASE WHEN v_bad='' THEN 'PASS' ELSE 'FAIL:' || v_bad END);

    v_bad := '';
    FOREACH v_t IN ARRAY v_tables || v_views LOOP
        IF NOT has_table_privilege('authenticated', v_t, 'SELECT') THEN v_bad := v_bad || ' ' || v_t; END IF;
    END LOOP;
    INSERT INTO "_p05_results" VALUES ('2-select-preserved', CASE WHEN v_bad='' THEN 'PASS' ELSE 'FAIL: lost SELECT:' || v_bad END);

    v_bad := '';
    FOREACH v_t IN ARRAY v_views LOOP
        FOREACH v_priv IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('authenticated', v_t, v_priv) OR has_table_privilege('anon', v_t, v_priv) THEN
                v_bad := v_bad || ' ' || v_priv || '@' || v_t; END IF;
        END LOOP;
    END LOOP;
    INSERT INTO "_p05_results" VALUES ('3-views-select-only', CASE WHEN v_bad='' THEN 'PASS' ELSE 'FAIL:' || v_bad END);

    v_bad := '';
    FOREACH v_t IN ARRAY v_req LOOP
        IF has_table_privilege('authenticated', v_t, 'INSERT') THEN v_bad := v_bad || ' grant@' || v_t; END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE cmd IN ('INSERT','ALL')
               AND schemaname||'.'||tablename = ANY (v_req)) THEN v_bad := v_bad || ' policy-still-present'; END IF;
    INSERT INTO "_p05_results" VALUES ('4-request-insert-closed', CASE WHEN v_bad='' THEN 'PASS' ELSE 'FAIL:' || v_bad END);

    SELECT string_agg(x, ' ') INTO v_bad FROM (
        SELECT n.nspname||'.'||c.relname AS x FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
         WHERE n.nspname||'.'||c.relname = ANY (v_req) AND (NOT c.relrowsecurity OR c.relforcerowsecurity)
        UNION ALL
        SELECT t FROM unnest(v_req) t WHERE NOT EXISTS (SELECT 1 FROM pg_policies p
            WHERE p.cmd='SELECT' AND p.schemaname||'.'||p.tablename=t)
    ) q;
    INSERT INTO "_p05_results" VALUES ('5-rls-enabled-not-forced-select-policies-intact',
        CASE WHEN v_bad IS NULL THEN 'PASS' ELSE 'FAIL:' || v_bad END);

    SELECT string_agg(f, ' ') INTO v_bad FROM unnest(ARRAY[
        'leave.submit_leave_request(uuid,date,date,numeric,text,character varying)',
        'attendance.submit_correction_request(date,timestamp with time zone,timestamp with time zone,text,character varying)',
        'assets.submit_asset_request(uuid,text,character varying)']) f
     WHERE to_regprocedure(f) IS NULL
        OR NOT (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = to_regprocedure(f)::oid);
    INSERT INTO "_p05_results" VALUES ('6-exact-submit-rpcs-security-definer',
        CASE WHEN v_bad IS NULL THEN 'PASS' ELSE 'FAIL:' || v_bad END);

    SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        INSERT INTO leave.leave_requests (employee_id, leave_type_id, start_date, end_date, total_days, request_status)
        VALUES (v_uid, gen_random_uuid(), current_date, current_date, 1, 'APPROVED');
        r_leave := 'FAIL: direct insert succeeded';
    EXCEPTION WHEN insufficient_privilege THEN r_leave := 'PASS';
              WHEN OTHERS THEN r_leave := 'FAIL: unexpected error ' || SQLSTATE;
    END;
    BEGIN
        INSERT INTO attendance.correction_requests (attendance_day_id, employee_id, requested_check_in, reason, request_status)
        VALUES (gen_random_uuid(), v_uid, now(), 'p05', 'APPROVED');
        r_att := 'FAIL: direct insert succeeded';
    EXCEPTION WHEN insufficient_privilege THEN r_att := 'PASS';
              WHEN OTHERS THEN r_att := 'FAIL: unexpected error ' || SQLSTATE;
    END;
    BEGIN
        INSERT INTO assets.asset_requests (employee_id, asset_category_id, justification, request_status)
        VALUES (v_uid, gen_random_uuid(), 'p05', 'FULFILLED');
        r_asset := 'FAIL: direct insert succeeded';
    EXCEPTION WHEN insufficient_privilege THEN r_asset := 'PASS';
              WHEN OTHERS THEN r_asset := 'FAIL: unexpected error ' || SQLSTATE;
    END;
    RESET ROLE;
    INSERT INTO "_p05_results" VALUES ('7a-leave-direct-insert-denied', r_leave);
    INSERT INTO "_p05_results" VALUES ('7b-attendance-direct-insert-denied', r_att);
    INSERT INTO "_p05_results" VALUES ('7c-assets-direct-insert-denied', r_asset);
END;
$$;

-- Zero-failure gate: FAIL raises; PASS completes normally.
DO $$
DECLARE v_fail int; v_total int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE result <> 'PASS'), count(*),
           string_agg(step || ' = ' || result, ' | ' ORDER BY step) FILTER (WHERE result <> 'PASS')
      INTO v_fail, v_total, v_list FROM "_p05_results";
    IF v_fail > 0 THEN
        RAISE EXCEPTION 'P05 TEST FAILED (% of % checks): %', v_fail, v_total, v_list;
    END IF;
    RAISE NOTICE 'P05 TEST PASSED: % checks, 0 failures', v_total;
END;
$$;

SELECT step, result FROM "_p05_results" ORDER BY step;
-- ========================================================================
-- END TEST_P05_privilege_hygiene_and_request_insert_closure.sql
-- ========================================================================
