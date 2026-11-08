-- ========================================================================
-- TEST_offboarding_001_003_foundation.sql  (v2 - lead review applied)
-- Run AFTER 001, 002, 003. Persists nothing (every fixture is in a rolled-back sub-block).
-- Needs: one ACTIVE hr.employees row and one auth user; otherwise independent of scratch data.
-- Constraint tests assert the SPECIFIC constraint that fired (never "any violation").
-- Gate: any FAIL raises; all PASS completes with a notice and the result table.
-- ========================================================================
DROP TABLE IF EXISTS "_off_foundation_results";
CREATE TEMP TABLE "_off_foundation_results" ("step" text, "result" text);

DO $$
DECLARE
    v_res text[] := ARRAY[]::text[];
    v_uid uuid; v_emp uuid; v_case uuid; v_task uuid; v_task2 uuid; v_ev uuid;
    v_t text; v_priv text; v_bad text; r text; v_ver int; v_n int; v_cname text; v_term text;
    v_type text;
    v_tables text[] := ARRAY['cases','clearance_tasks','request_idempotency','case_history','outbox_events','outbox_delivery'];
BEGIN
    SELECT id INTO v_uid FROM auth.users ORDER BY created_at LIMIT 1;
    SELECT id INTO v_emp FROM hr.employees WHERE employment_status = 'ACTIVE' ORDER BY created_at LIMIT 1;
    IF v_uid IS NULL OR v_emp IS NULL THEN RAISE EXCEPTION 'SETUP: need an auth user (%) and an ACTIVE employee (%)', v_uid, v_emp; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);

    ---------------------------------------------------------------- 1. structure
    v_bad := '';
    FOREACH v_t IN ARRAY v_tables LOOP IF to_regclass('offboarding.' || v_t) IS NULL THEN v_bad := v_bad || ' ' || v_t; END IF; END LOOP;
    v_res := v_res || ARRAY['1a-six-tables-exist|' || CASE WHEN v_bad = '' THEN 'PASS' ELSE 'FAIL: missing' || v_bad END];
    v_res := v_res || ARRAY['1b-four-enums-exist|' || CASE WHEN to_regtype('offboarding.case_type') IS NOT NULL AND to_regtype('offboarding.case_status') IS NOT NULL
                                                           AND to_regtype('offboarding.clearance_domain') IS NOT NULL AND to_regtype('offboarding.clearance_status') IS NOT NULL
                                                      THEN 'PASS' ELSE 'FAIL' END];
    SELECT count(*) INTO v_n FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'offboarding' AND NOT t.tgisinternal AND c.relname = ANY (v_tables);
    v_res := v_res || ARRAY['1c-eight-triggers-on-the-six-core-tables|' || CASE WHEN v_n = 8 THEN 'PASS' ELSE 'FAIL: ' || v_n END];
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'offboarding' AND p.proname IN ('_force_created_by','_force_updated_by','_enforce_case_status_transition','_enforce_clearance_transition','_prevent_mutation');
    v_res := v_res || ARRAY['1d-the-five-001-trigger-functions-exist|' || CASE WHEN v_n = 5 THEN 'PASS' ELSE 'FAIL: ' || v_n END];

    ---------------------------------------------------------------- 2. default-deny boundary
    v_bad := '';
    FOREACH v_t IN ARRAY v_tables LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = ('offboarding.' || v_t)::regclass AND relrowsecurity AND NOT relforcerowsecurity) THEN v_bad := v_bad || ' rls@' || v_t; END IF;
        IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'offboarding' AND tablename = v_t) THEN v_bad := v_bad || ' policy@' || v_t; END IF;
        FOREACH v_priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('authenticated', 'offboarding.' || v_t, v_priv) OR has_table_privilege('anon', 'offboarding.' || v_t, v_priv)
               OR EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid = ('offboarding.' || v_t)::regclass AND a.grantee = 0 AND a.privilege_type = v_priv) THEN
                v_bad := v_bad || ' ' || v_priv || '@' || v_t; END IF;
        END LOOP;
    END LOOP;
    v_res := v_res || ARRAY['2a-rls-on-no-policies-no-app-grants|' || CASE WHEN v_bad = '' THEN 'PASS' ELSE 'FAIL:' || v_bad END];
    v_res := v_res || ARRAY['2b-schema-usage-authenticated-only|' || CASE WHEN has_schema_privilege('authenticated','offboarding','USAGE')
        AND NOT has_schema_privilege('anon','offboarding','USAGE') AND NOT has_schema_privilege('authenticated','offboarding','CREATE') THEN 'PASS' ELSE 'FAIL' END];
    SELECT string_agg(p.proname, ' ') INTO v_bad FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'offboarding' AND p.proname IN ('_force_created_by','_force_updated_by','_enforce_case_status_transition','_enforce_clearance_transition','_prevent_mutation')
       AND (p.proacl IS NULL
            OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
            OR has_function_privilege('authenticated', p.oid, 'EXECUTE') OR has_function_privilege('anon', p.oid, 'EXECUTE'));
    v_res := v_res || ARRAY['2c-internal-functions-closed-to-PUBLIC-anon-authenticated|' || CASE WHEN v_bad IS NULL THEN 'PASS' ELSE 'FAIL: ' || v_bad END];

    SET LOCAL ROLE authenticated;
    BEGIN PERFORM count(*) FROM offboarding.cases; r := 'FAIL: SELECT allowed'; EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2d-direct-select-denied|' || r];
    BEGIN INSERT INTO offboarding.cases (hr_employee_id, case_type, reason_category, last_working_date, initiated_by) VALUES (v_emp, 'RESIGNATION', 'PERSONAL', current_date + 30, v_uid); r := 'FAIL: INSERT allowed';
    EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2e-direct-insert-denied|' || r];
    BEGIN UPDATE offboarding.cases SET reason_detail = 'x' WHERE id = gen_random_uuid(); r := 'FAIL: UPDATE allowed'; EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2f-direct-update-denied|' || r];
    BEGIN DELETE FROM offboarding.case_history WHERE id = gen_random_uuid(); r := 'FAIL: DELETE allowed'; EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2g-direct-delete-denied|' || r];
    RESET ROLE;

    ---------------------------------------------------------------- 3. permissions seed
    SELECT count(*) INTO v_n FROM core.permissions WHERE module = 'offboarding'
       AND code IN ('OFFBOARDING_MANAGE','OFFBOARDING_VIEW_ALL','OFFBOARDING_CLEARANCE_ASSETS','OFFBOARDING_CLEARANCE_ACCESS','OFFBOARDING_CLEARANCE_FINANCE','OFFBOARDING_CLEARANCE_HANDOVER','OFFBOARDING_CLEARANCE_HR');
    v_res := v_res || ARRAY['3a-seven-permission-codes|' || CASE WHEN v_n = 7 THEN 'PASS' ELSE 'FAIL: ' || v_n END];
    SELECT count(*) INTO v_n FROM core.role_permissions rp JOIN core.permissions p ON p.id = rp.permission_id WHERE p.code LIKE 'OFFBOARDING\_%';
    v_res := v_res || ARRAY['3b-no-role-mappings-guessed|' || CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL: ' || v_n || ' mapping(s) exist' END];

    ---------------------------------------------------------------- 4. isolated CHECK constraints (no open case exists; the SPECIFIC constraint must fire)
    BEGIN
        INSERT INTO offboarding.cases (hr_employee_id, case_type, reason_category, last_working_date, initiated_by) VALUES (v_emp, 'TERMINATION', 'PERSONAL', current_date + 30, v_uid);
        r := 'FAIL: mismatched category accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
        r := CASE WHEN v_cname = 'chk_cases_reason_category' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
    WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
    v_res := v_res || ARRAY['4a-category-must-match-case-type|' || r];

    BEGIN
        INSERT INTO offboarding.cases (hr_employee_id, case_type, reason_category, last_working_date, initiated_by, on_behalf) VALUES (v_emp, 'TERMINATION', 'CONDUCT', current_date + 30, v_uid, true);
        r := 'FAIL: on_behalf termination accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
        r := CASE WHEN v_cname = 'chk_cases_on_behalf_resignation_only' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
    WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
    v_res := v_res || ARRAY['4b-on-behalf-is-resignation-only-check-fires|' || r];

    ---------------------------------------------------------------- 5. case lifecycle (owner session, rolled back)
    BEGIN
        INSERT INTO offboarding.cases (hr_employee_id, case_type, reason_category, last_working_date, initiated_by) VALUES (v_emp, 'RESIGNATION', 'PERSONAL', current_date + 30, v_uid) RETURNING id INTO v_case;
        v_res := v_res || ARRAY['5a-valid-resignation-insert|PASS'];

        BEGIN INSERT INTO offboarding.cases (hr_employee_id, case_type, reason_category, last_working_date, initiated_by) VALUES (v_emp, 'TERMINATION', 'CONDUCT', current_date + 30, v_uid); r := 'FAIL: second open case accepted';
        EXCEPTION WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
            r := CASE WHEN v_cname = 'idx_offboarding_cases_one_open_per_employee' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
        WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['5b-one-open-case-per-employee|' || r];

        BEGIN UPDATE offboarding.cases SET status = 'COMPLETED', completed_at = now(), completed_by = v_uid WHERE id = v_case; r := 'FAIL: SUBMITTED -> COMPLETED accepted';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_INVALID_TRANSITION%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['5c-cannot-skip-to-completed|' || r];
        BEGIN UPDATE offboarding.cases SET status = 'CANCELLED', cancelled_at = now(), cancelled_by = v_uid, cancellation_reason = 'x' WHERE id = v_case; r := 'FAIL: resignation CANCELLED accepted';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_INVALID_TRANSITION%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['5d-resignation-cannot-be-cancelled|' || r];
        BEGIN UPDATE offboarding.cases SET status = 'WITHDRAWN', withdrawn_at = now(), withdrawn_by = v_uid WHERE id = v_case; r := 'FAIL: withdrawal without reason accepted';
        EXCEPTION WHEN check_violation THEN
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
            r := CASE WHEN v_cname = 'chk_cases_withdrawn_consistent' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
        WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['5e-withdrawal-requires-reason|' || r];
        -- employee immutability without depending on any other hr.employees row: a generated UUID; the Offboarding
        -- trigger must reject it BEFORE the foreign key is evaluated
        BEGIN UPDATE offboarding.cases SET hr_employee_id = gen_random_uuid() WHERE id = v_case; r := 'FAIL: employee changed';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_IMMUTABLE_COLUMN%' THEN 'PASS' ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END; END;
        v_res := v_res || ARRAY['5f-employee-immutable-trigger-fires-before-fk|' || r];

        UPDATE offboarding.cases SET status = 'APPROVED', approved_at = now() WHERE id = v_case;
        UPDATE offboarding.cases SET status = 'IN_CLEARANCE', clearance_started_at = now() WHERE id = v_case;
        SELECT version INTO v_ver FROM offboarding.cases WHERE id = v_case;
        v_res := v_res || ARRAY['5g-version-bumps-once-per-real-update|' || CASE WHEN v_ver = 3 THEN 'PASS' ELSE 'FAIL: version=' || v_ver || ' expected 3' END];
        RAISE EXCEPTION 'OFF_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'OFF_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['5-cases-block|FAIL: ' || SQLERRM]; END IF; END;

    ---------------------------------------------------------------- 6. terminal cases are final: ANY update is rejected (all four terminal statuses)
    FOREACH v_term IN ARRAY ARRAY['REJECTED','WITHDRAWN','CANCELLED','COMPLETED'] LOOP
        BEGIN
            v_type := CASE WHEN v_term = 'WITHDRAWN' THEN 'RESIGNATION' ELSE 'TERMINATION' END;
            INSERT INTO offboarding.cases (hr_employee_id, case_type, reason_category, last_working_date, initiated_by)
            VALUES (v_emp, v_type::offboarding.case_type, CASE WHEN v_type = 'RESIGNATION' THEN 'PERSONAL' ELSE 'CONDUCT' END, current_date + 30, v_uid) RETURNING id INTO v_case;
            IF v_term = 'REJECTED' THEN
                UPDATE offboarding.cases SET status = 'REJECTED' WHERE id = v_case;
            ELSIF v_term = 'WITHDRAWN' THEN
                UPDATE offboarding.cases SET status = 'WITHDRAWN', withdrawn_at = now(), withdrawn_by = v_uid, withdrawal_reason = 'test' WHERE id = v_case;
            ELSIF v_term = 'CANCELLED' THEN
                UPDATE offboarding.cases SET status = 'CANCELLED', cancelled_at = now(), cancelled_by = v_uid, cancellation_reason = 'test' WHERE id = v_case;
            ELSE
                UPDATE offboarding.cases SET status = 'APPROVED', approved_at = now() WHERE id = v_case;
                UPDATE offboarding.cases SET status = 'IN_CLEARANCE', clearance_started_at = now() WHERE id = v_case;
                UPDATE offboarding.cases SET status = 'COMPLETED', completed_at = now(), completed_by = v_uid WHERE id = v_case;
            END IF;
            SELECT version INTO v_ver FROM offboarding.cases WHERE id = v_case;

            BEGIN UPDATE offboarding.cases SET reason_detail = 'tampered' WHERE id = v_case; r := 'FAIL: non-status field changed on a ' || v_term || ' case';
            EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_TERMINAL_STATUS%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
            v_res := v_res || ARRAY['6-' || lower(v_term) || '-rejects-non-status-update|' || r];

            BEGIN UPDATE offboarding.cases SET status = status WHERE id = v_case; r := 'FAIL: same-status update accepted on a ' || v_term || ' case';
            EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_TERMINAL_STATUS%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
            v_res := v_res || ARRAY['6-' || lower(v_term) || '-rejects-same-status-update|' || r];

            BEGIN UPDATE offboarding.cases SET status = 'APPROVED' WHERE id = v_case; r := 'FAIL: left terminal ' || v_term;
            EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_TERMINAL_STATUS%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
            v_res := v_res || ARRAY['6-' || lower(v_term) || '-cannot-leave-terminal|' || r];
            RAISE EXCEPTION 'OFF_TEST_ROLLBACK';
        EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'OFF_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['6-' || lower(v_term) || '-block|FAIL: ' || SQLERRM]; END IF; END;
    END LOOP;

    ---------------------------------------------------------------- 7. clearance tasks: final once CLEARED or WAIVED
    BEGIN
        INSERT INTO offboarding.cases (hr_employee_id, case_type, reason_category, last_working_date, initiated_by) VALUES (v_emp, 'TERMINATION', 'CONDUCT', current_date + 30, v_uid) RETURNING id INTO v_case;
        INSERT INTO offboarding.clearance_tasks (case_id, domain) VALUES (v_case, 'ASSETS') RETURNING id INTO v_task;
        v_res := v_res || ARRAY['7a-task-insert-pending|PASS'];
        BEGIN INSERT INTO offboarding.clearance_tasks (case_id, domain) VALUES (v_case, 'ASSETS'); r := 'FAIL: duplicate domain accepted';
        EXCEPTION WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
            r := CASE WHEN v_cname = 'uq_clearance_tasks_case_domain' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
        WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['7b-one-task-per-domain|' || r];
        BEGIN UPDATE offboarding.clearance_tasks SET status = 'CLEARED' WHERE id = v_task; r := 'FAIL: CLEARED without sign-off fields accepted';
        EXCEPTION WHEN check_violation THEN
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
            r := CASE WHEN v_cname = 'chk_clearance_cleared' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
        WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['7c-cleared-needs-sign-off-fields|' || r];
        BEGIN UPDATE offboarding.clearance_tasks SET status = 'WAIVED', waived_at = now(), waived_by = v_uid, waiver_reason = 'because' WHERE id = v_task; r := 'FAIL: ASSETS clearance waived';
        EXCEPTION WHEN check_violation THEN
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
            r := CASE WHEN v_cname = 'chk_clearance_waived' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
        WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['7d-assets-clearance-can-never-be-waived|' || r];

        INSERT INTO offboarding.clearance_tasks (case_id, domain) VALUES (v_case, 'ACCESS') RETURNING id INTO v_task;
        BEGIN UPDATE offboarding.clearance_tasks SET status = 'WAIVED', waived_at = now(), waived_by = v_uid, waiver_reason = '  ' WHERE id = v_task; r := 'FAIL: blank waiver reason accepted';
        EXCEPTION WHEN check_violation THEN
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
            r := CASE WHEN v_cname = 'chk_clearance_waived' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
        WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['7e-waiver-needs-a-real-reason|' || r];

        -- ACCESS is CLEARED; FINANCE is WAIVED with a valid reason
        UPDATE offboarding.clearance_tasks SET status = 'CLEARED', cleared_at = now(), cleared_by = v_uid, clearance_note = 'ok' WHERE id = v_task;
        INSERT INTO offboarding.clearance_tasks (case_id, domain) VALUES (v_case, 'FINANCE') RETURNING id INTO v_task2;
        UPDATE offboarding.clearance_tasks SET status = 'WAIVED', waived_at = now(), waived_by = v_uid, waiver_reason = 'valid management override' WHERE id = v_task2;

        BEGIN UPDATE offboarding.clearance_tasks SET clearance_note = 'edited after sign-off' WHERE id = v_task; r := 'FAIL: CLEARED -> CLEARED with changed note accepted';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_CLEARANCE_TERMINAL%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['7f-cleared-same-status-edit-rejected|' || r];
        BEGIN UPDATE offboarding.clearance_tasks SET cleared_at = now() WHERE id = v_task; r := 'FAIL: CLEARED sign-off timestamp changed';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_CLEARANCE_TERMINAL%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['7g-cleared-signoff-data-immutable|' || r];
        BEGIN UPDATE offboarding.clearance_tasks SET waiver_reason = 'rewritten reason' WHERE id = v_task2; r := 'FAIL: WAIVED -> WAIVED with changed reason accepted';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_CLEARANCE_TERMINAL%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['7h-waived-same-status-edit-rejected|' || r];
        BEGIN UPDATE offboarding.clearance_tasks SET status = 'PENDING', cleared_at = NULL, cleared_by = NULL, clearance_note = NULL WHERE id = v_task; r := 'FAIL: CLEARED task returned to PENDING';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_CLEARANCE_TERMINAL%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['7i-cleared-cannot-return-to-pending|' || r];
        BEGIN UPDATE offboarding.clearance_tasks SET status = 'PENDING', waived_at = NULL, waived_by = NULL, waiver_reason = NULL WHERE id = v_task2; r := 'FAIL: WAIVED task returned to PENDING';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_CLEARANCE_TERMINAL%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['7j-waived-cannot-return-to-pending|' || r];
        RAISE EXCEPTION 'OFF_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'OFF_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['7-tasks-block|FAIL: ' || SQLERRM]; END IF; END;

    ---------------------------------------------------------------- 8. append-only history and outbox; delivery state separate
    BEGIN
        INSERT INTO offboarding.cases (hr_employee_id, case_type, reason_category, last_working_date, initiated_by) VALUES (v_emp, 'TERMINATION', 'CONDUCT', current_date + 30, v_uid) RETURNING id INTO v_case;
        INSERT INTO offboarding.case_history (case_id, event_type, to_status, actor) VALUES (v_case, 'SUBMITTED', 'SUBMITTED', v_uid);
        BEGIN UPDATE offboarding.case_history SET event_type = 'X' WHERE case_id = v_case; r := 'FAIL: history UPDATE accepted';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_APPEND_ONLY%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['8a-history-update-rejected|' || r];
        BEGIN DELETE FROM offboarding.case_history WHERE case_id = v_case; r := 'FAIL: history DELETE accepted';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_APPEND_ONLY%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['8b-history-delete-rejected|' || r];
        INSERT INTO offboarding.outbox_events (case_id, event_type, payload) VALUES (v_case, 'OFFBOARDING_COMPLETED', '{}'::jsonb) RETURNING id INTO v_ev;
        BEGIN UPDATE offboarding.outbox_events SET payload = '{"x":1}'::jsonb WHERE id = v_ev; r := 'FAIL: outbox event UPDATE accepted';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'OFFBOARDING_APPEND_ONLY%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['8c-outbox-event-immutable|' || r];
        BEGIN INSERT INTO offboarding.outbox_events (case_id, event_type, payload) VALUES (v_case, 'OFFBOARDING_COMPLETED', '{}'::jsonb); r := 'FAIL: duplicate event accepted';
        EXCEPTION WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
            r := CASE WHEN v_cname = 'uq_outbox_events_case_event' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
        WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['8d-one-event-per-case-and-type|' || r];
        INSERT INTO offboarding.outbox_delivery (event_id) VALUES (v_ev);
        BEGIN UPDATE offboarding.outbox_delivery SET delivery_status = 'DELIVERED', delivered_at = now(), attempts = 1, last_attempt_at = now(), updated_at = now() WHERE event_id = v_ev; r := 'PASS';
        EXCEPTION WHEN OTHERS THEN r := 'FAIL: delivery state not updatable: ' || SQLERRM; END;
        v_res := v_res || ARRAY['8e-delivery-state-is-separately-mutable|' || r];
        BEGIN UPDATE offboarding.outbox_delivery SET delivery_status = 'DELIVERED', delivered_at = NULL WHERE event_id = v_ev; r := 'FAIL: DELIVERED without delivered_at';
        EXCEPTION WHEN check_violation THEN
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
            r := CASE WHEN v_cname = 'chk_outbox_delivery_delivered' THEN 'PASS' ELSE 'FAIL: wrong constraint ' || coalesce(v_cname, '?') END;
        WHEN OTHERS THEN r := 'FAIL: ' || SQLSTATE || ' ' || SQLERRM; END;
        v_res := v_res || ARRAY['8f-delivered-needs-timestamp|' || r];
        RAISE EXCEPTION 'OFF_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'OFF_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['8-outbox-block|FAIL: ' || SQLERRM]; END IF; END;

    INSERT INTO "_off_foundation_results" SELECT split_part(x, '|', 1), substr(x, strpos(x, '|') + 1) FROM unnest(v_res) AS x;
END;
$$;

DO $$
DECLARE v_fail int; v_total int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE result <> 'PASS'), count(*),
           string_agg(step || ' = ' || result, ' | ' ORDER BY step) FILTER (WHERE result <> 'PASS')
      INTO v_fail, v_total, v_list FROM "_off_foundation_results";
    IF v_total = 0 THEN RAISE EXCEPTION 'OFFBOARDING 001-003 TEST: no results recorded'; END IF;
    IF v_fail > 0 THEN RAISE EXCEPTION 'OFFBOARDING 001-003 TEST FAILED (% of % checks): %', v_fail, v_total, v_list; END IF;
    RAISE NOTICE 'OFFBOARDING 001-003 TEST PASSED: % checks, 0 failures', v_total;
END;
$$;

SELECT step, result FROM "_off_foundation_results" ORDER BY step;
-- ========================================================================
-- END TEST_offboarding_001_003_foundation.sql
-- ========================================================================
