-- ========================================================================
-- TEST_P04_hr_status_history_and_termination.sql
-- One paste; zero-failure gate at the end; any raise rolls everything back.
-- Creates 3 fixture people/employees ("P04 TEST ..."). Because the status
-- history is immutable and references employees, these fixture rows are
-- PERMANENT by design (same as Phase 8's workflow rows); they are clearly
-- named and use @example.invalid emails.
-- The SQL editor runs the script as ONE transaction, so each guarded direct
-- attempt uses a DIFFERENT fixture than the sanctioned termination.
-- ========================================================================
DROP TABLE IF EXISTS "_p04_results";
CREATE TEMP TABLE "_p04_results" ("step" text, "result" text);
GRANT ALL ON "_p04_results" TO "authenticated";
DROP TABLE IF EXISTS "_p04_ids";
CREATE TEMP TABLE "_p04_ids" ("key" text PRIMARY KEY, "value" text);
GRANT ALL ON "_p04_ids" TO "authenticated";

CREATE FUNCTION pg_temp.p04_make(p_label text, p_run text, p_hire date)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_person uuid := gen_random_uuid(); v_emp uuid := gen_random_uuid();
BEGIN
    INSERT INTO core.people (id, organization_id, full_name, primary_email, person_type, status)
    VALUES (v_person, (SELECT organization_id FROM core.people WHERE organization_id IS NOT NULL LIMIT 1),
            'P04 TEST ' || p_label, 'p04-' || p_label || '-' || p_run || '@example.invalid', 'EMPLOYEE', 'ACTIVE');
    INSERT INTO hr.employees (id, person_id, employee_number, hire_date)
    VALUES (v_emp, v_person, 'P04-' || p_label || '-' || p_run, p_hire);
    RETURN v_emp;
END;
$$;

DO $$
DECLARE
    v_run text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    v_own_emp uuid := 'c0ad2a68-a478-43bd-b25b-0c080934258b';
BEGIN
    -- The audit triggers (_force_created_by) refuse INSERTs without an authenticated session, so fixtures are created as LOCAL_TEST_ADMIN.
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    IF NOT core.has_permission('2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'PEOPLE_MANAGE') THEN RAISE EXCEPTION 'SETUP: LOCAL_TEST_ADMIN lacks PEOPLE_MANAGE'; END IF;
    IF core.has_permission('00000000-0000-0000-0000-0000000000a1', 'PEOPLE_MANAGE') OR core.has_permission('00000000-0000-0000-0000-0000000000a1', 'PEOPLE_VIEW_ALL') THEN
        RAISE EXCEPTION 'SETUP: fixture user a1 unexpectedly holds a PEOPLE permission';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM hr.employees e JOIN core.person_user_links l ON l.person_id = e.person_id
                   WHERE e.id = v_own_emp AND l.user_id = 'ed761a27-783e-43d2-8fcd-ac2f64b29249' AND l.status = 'ACTIVE') THEN
        RAISE EXCEPTION 'SETUP: ed761a27 is expected to be the ACTIVE-linked user of employee c0ad2a68 (own-history test)';
    END IF;

    INSERT INTO "_p04_ids" VALUES
        ('real_before', (SELECT string_agg(e.id::text || ':' || e.employment_status::text || ':' || coalesce(e.termination_date::text, 'null'), ',' ORDER BY e.id)
                         FROM hr.employees e WHERE e.employee_number IS NULL OR e.employee_number NOT LIKE 'P04-%')),
        ('a', pg_temp.p04_make('A', v_run, '2026-01-01')::text),
        ('b', pg_temp.p04_make('B', v_run, '2026-01-01')::text),
        ('c', pg_temp.p04_make('C', v_run, '2026-06-01')::text);
    INSERT INTO "_p04_results" VALUES ('0-setup', 'fixture employees A, B, C created (run ' || v_run || ')');
END;
$$;

-- structure / backfill / insert history ------------------------------------------
DO $$
DECLARE
    v_a uuid := (SELECT "value"::uuid FROM "_p04_ids" WHERE "key" = 'a');
    v_missing int; v_a_rows int; v_src text;
BEGIN
    SELECT count(*) INTO v_missing FROM hr.employees e WHERE NOT EXISTS (SELECT 1 FROM hr.employee_status_history h WHERE h.employee_id = e.id);
    INSERT INTO "_p04_results" VALUES ('1-backfill-complete',
        CASE WHEN v_missing = 0 THEN 'PASS: every employee has at least one history row' ELSE 'FAIL: ' || v_missing::text || ' employee(s) without history' END);

    SELECT count(*), min(source) INTO v_a_rows, v_src FROM hr.employee_status_history WHERE employee_id = v_a;
    INSERT INTO "_p04_results" VALUES ('2-insert-recorded',
        CASE WHEN v_a_rows = 1 AND v_src = 'EMPLOYEE_INSERT' THEN 'PASS: a new employee gets exactly one EMPLOYEE_INSERT history row' ELSE 'FAIL: rows=' || v_a_rows::text || ' source=' || coalesce(v_src, 'NULL') END);

    INSERT INTO "_p04_results" VALUES ('18-no-reason-column',
        CASE WHEN (SELECT string_agg(column_name, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema = 'hr' AND table_name = 'employee_status_history')
                  = 'changed_at,changed_by,effective_date,employee_id,id,new_status,previous_status,source,txid'
             THEN 'PASS: history columns are exactly the approved set - no reason/notes text'
             ELSE 'FAIL: unexpected columns: ' || (SELECT string_agg(column_name, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema = 'hr' AND table_name = 'employee_status_history') END);
END;
$$;

-- direct attempts + normal lifecycle as a PEOPLE_MANAGE user ------------------------
SET ROLE "authenticated";
DO $$
DECLARE
    v_a uuid := (SELECT "value"::uuid FROM "_p04_ids" WHERE "key" = 'a');
    v_status text; v_td date; v_rows int; v_hist int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);

    BEGIN
        UPDATE hr.employees SET employment_status = 'TERMINATED' WHERE id = v_a;
        INSERT INTO "_p04_results" VALUES ('3-direct-terminate', 'FAIL: the UPDATE succeeded');
    EXCEPTION WHEN OTHERS THEN
        SELECT employment_status::text INTO v_status FROM hr.employees WHERE id = v_a;
        INSERT INTO "_p04_results" VALUES ('3-direct-terminate',
            CASE WHEN SQLERRM LIKE 'HR_EMPLOYEE_TERMINATION_NOT_SANCTIONED%' AND v_status = 'ACTIVE' THEN 'PASS: PEOPLE_MANAGE direct TERMINATED rejected; employee stays ACTIVE'
                 ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    BEGIN
        UPDATE hr.employees SET termination_date = '2026-10-01' WHERE id = v_a;
        INSERT INTO "_p04_results" VALUES ('4-direct-termination-date', 'FAIL: the UPDATE succeeded');
    EXCEPTION WHEN OTHERS THEN
        SELECT termination_date INTO v_td FROM hr.employees WHERE id = v_a;
        INSERT INTO "_p04_results" VALUES ('4-direct-termination-date',
            CASE WHEN SQLERRM LIKE 'HR_EMPLOYEE_TERMINATION_NOT_SANCTIONED%' AND v_td IS NULL THEN 'PASS: setting termination_date directly is rejected' ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    UPDATE hr.employees SET employment_status = 'ON_LEAVE' WHERE id = v_a;
    UPDATE hr.employees SET employment_status = 'ACTIVE' WHERE id = v_a;
    SELECT count(*) INTO v_hist FROM hr.employee_status_history WHERE employee_id = v_a;
    INSERT INTO "_p04_results" VALUES ('6-normal-lifecycle-and-history',
        CASE WHEN v_hist = 3
              AND (SELECT count(*) FROM hr.employee_status_history WHERE employee_id = v_a AND source = 'DIRECT_UPDATE'
                       AND ((previous_status = 'ACTIVE' AND new_status = 'ON_LEAVE') OR (previous_status = 'ON_LEAVE' AND new_status = 'ACTIVE'))) = 2
             THEN 'PASS: ACTIVE -> ON_LEAVE -> ACTIVE works and each change is recorded (3 rows: insert + 2 changes)' ELSE 'FAIL: history rows = ' || v_hist::text END);

    BEGIN
        PERFORM hr.terminate_employee(v_a, '2026-10-01');
        INSERT INTO "_p04_results" VALUES ('7-function-not-callable-by-authenticated', 'FAIL: call succeeded');
    EXCEPTION WHEN insufficient_privilege THEN
        INSERT INTO "_p04_results" VALUES ('7-function-not-callable-by-authenticated', 'PASS: permission denied (42501) - internal-only function');
    WHEN OTHERS THEN
        INSERT INTO "_p04_results" VALUES ('7-function-not-callable-by-authenticated', 'FAIL: ' || SQLSTATE || ' ' || SQLERRM);
    END;

    BEGIN
        UPDATE hr.employee_status_history SET new_status = 'ACTIVE' WHERE employee_id = v_a;
        INSERT INTO "_p04_results" VALUES ('15-history-not-writable-by-authenticated', 'FAIL: UPDATE succeeded');
    EXCEPTION WHEN insufficient_privilege THEN
        INSERT INTO "_p04_results" VALUES ('15-history-not-writable-by-authenticated', 'PASS: permission denied (42501) - history can be read, never written, by application roles');
    WHEN OTHERS THEN
        INSERT INTO "_p04_results" VALUES ('15-history-not-writable-by-authenticated', 'FAIL: ' || SQLSTATE || ' ' || SQLERRM);
    END;
END;
$$;
RESET ROLE;

-- direct INSERT as TERMINATED, even by the owner ---------------------------------------
DO $$
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    BEGIN
        INSERT INTO hr.employees (id, person_id, employment_status)
        SELECT gen_random_uuid(), e.person_id, 'TERMINATED' FROM hr.employees e LIMIT 1;
        INSERT INTO "_p04_results" VALUES ('5-direct-insert-terminated', 'FAIL: insert succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p04_results" VALUES ('5-direct-insert-terminated',
            CASE WHEN SQLERRM LIKE 'HR_EMPLOYEE_TERMINATION_NOT_SANCTIONED%' THEN 'PASS: inserting an employee already TERMINATED is rejected, even for the owner' ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;
END;
$$;

-- STALE / MISMATCHED SANCTIONS authorize nothing (team-lead requirement) ----------
-- The sanction must match kind + entity + target status + the CURRENT transaction.
-- Each forged row is planted inside a subtransaction that is always rolled back, so
-- the immutable ledger keeps no trace and the fixture employee stays ACTIVE.
DO $$
DECLARE
    v_a uuid := (SELECT "value"::uuid FROM "_p04_ids" WHERE "key" = 'a');
    v_case text; v_outcome text; v_detail text := ''; v_left int; v_status text; v_td date;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    FOREACH v_case IN ARRAY ARRAY['stale-transaction', 'other-entity', 'other-kind', 'other-status'] LOOP
        v_outcome := 'NOT_REJECTED';
        BEGIN
            IF v_case = 'stale-transaction' THEN
                INSERT INTO hr._sanctioned_transitions (kind, entity_id, to_status, effective_date, txid)
                VALUES ('EMPLOYEE', v_a, 'TERMINATED', DATE '2026-10-01', txid_current() - 1);
            ELSIF v_case = 'other-entity' THEN
                INSERT INTO hr._sanctioned_transitions (kind, entity_id, to_status, effective_date)
                VALUES ('EMPLOYEE', gen_random_uuid(), 'TERMINATED', DATE '2026-10-01');
            ELSIF v_case = 'other-kind' THEN
                INSERT INTO hr._sanctioned_transitions (kind, entity_id, to_status, effective_date)
                VALUES ('CONTRACT', v_a, 'TERMINATED', DATE '2026-10-01');
            ELSE
                INSERT INTO hr._sanctioned_transitions (kind, entity_id, to_status, effective_date)
                VALUES ('EMPLOYEE', v_a, 'ACTIVE', DATE '2026-10-01');
            END IF;
            BEGIN
                UPDATE hr.employees SET employment_status = 'TERMINATED', termination_date = DATE '2026-10-01' WHERE id = v_a;
                v_outcome := 'NOT_REJECTED';
            EXCEPTION WHEN OTHERS THEN
                v_outcome := CASE WHEN SQLERRM LIKE 'HR_EMPLOYEE_TERMINATION_NOT_SANCTIONED%' THEN 'REJECTED' ELSE 'WRONG_ERROR:' || SQLSTATE END;
            END;
            RAISE EXCEPTION 'P04_ROLLBACK_PLANTED_ROW';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'P04_ROLLBACK_PLANTED_ROW' THEN v_outcome := 'SETUP_ERROR:' || SQLERRM; END IF;
        END;
        IF v_outcome <> 'REJECTED' THEN v_detail := v_detail || ' ' || v_case || '=' || v_outcome; END IF;
    END LOOP;

    SELECT count(*) INTO v_left FROM hr._sanctioned_transitions WHERE entity_id = v_a;
    SELECT employment_status::text, termination_date INTO v_status, v_td FROM hr.employees WHERE id = v_a;
    INSERT INTO "_p04_results" VALUES ('21-stale-and-mismatched-sanctions-authorize-nothing',
        CASE WHEN v_detail = '' AND v_left = 0 AND v_status = 'ACTIVE' AND v_td IS NULL
             THEN 'PASS: a ledger row from an earlier transaction, for another entity, of another kind, or for another status each authorize nothing; planted rows rolled back; the employee stayed ACTIVE'
             ELSE 'FAIL:' || v_detail || ' / leftover ledger rows=' || v_left::text || ' / status=' || coalesce(v_status, 'NULL') END);
END;
$$;

-- sanctioned path (owner session standing in for complete_offboarding) ------------------
DO $$
DECLARE
    v_b uuid := (SELECT "value"::uuid FROM "_p04_ids" WHERE "key" = 'b');
    v_c uuid := (SELECT "value"::uuid FROM "_p04_ids" WHERE "key" = 'c');
    v_r jsonb; v_r2 jsonb; v_type text; v_rows int; v_status text; v_hist int;
    v_bv0 int; v_bv1 int; v_bv2 int; v_cv0 int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);

    SELECT version INTO v_bv0 FROM hr.employees WHERE id = v_b;
    v_r := hr.terminate_employee(v_b, '2026-10-01');
    SELECT version INTO v_bv1 FROM hr.employees WHERE id = v_b;
    INSERT INTO "_p04_results" VALUES ('8b-version-increments-exactly-once',
        CASE WHEN v_bv1 = v_bv0 + 1 THEN 'PASS: employee version ' || v_bv0::text || ' -> ' || v_bv1::text ELSE 'FAIL: ' || v_bv0::text || ' -> ' || v_bv1::text END);
    SELECT p.person_type::text INTO v_type FROM hr.employees e JOIN core.people p ON p.id = e.person_id WHERE e.id = v_b;
    SELECT count(*) INTO v_hist FROM hr.employee_status_history WHERE employee_id = v_b;
    INSERT INTO "_p04_results" VALUES ('8-sanctioned-termination',
        CASE WHEN (SELECT employment_status::text FROM hr.employees WHERE id = v_b) = 'TERMINATED'
              AND (SELECT termination_date FROM hr.employees WHERE id = v_b) = '2026-10-01'
              AND v_type = 'EMPLOYEE' AND v_hist = 2
              AND (SELECT count(*) FROM hr.employee_status_history WHERE employee_id = v_b AND source = 'SANCTIONED_TERMINATION'
                       AND previous_status = 'ACTIVE' AND new_status = 'TERMINATED' AND effective_date = '2026-10-01'
                       AND changed_by = '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2') = 1
             THEN 'PASS: TERMINATED + termination_date set, person_type still EMPLOYEE, exactly one SANCTIONED_TERMINATION history row (no duplicate from the trigger)'
             ELSE 'FAIL: ' || v_r::text || ' / person_type=' || coalesce(v_type, 'NULL') || ' / history rows=' || v_hist::text END);

    v_r2 := hr.terminate_employee(v_b, '2026-10-01');
    SELECT version INTO v_bv2 FROM hr.employees WHERE id = v_b;
    INSERT INTO "_p04_results" VALUES ('9b-replay-no-version-change',
        CASE WHEN v_bv2 = v_bv1 THEN 'PASS: replay left the employee version unchanged (' || v_bv2::text || ')' ELSE 'FAIL: replay changed the version ' || v_bv1::text || ' -> ' || v_bv2::text END);
    INSERT INTO "_p04_results" VALUES ('9-replay-same-date',
        CASE WHEN (v_r2->>'idempotent_replay')::boolean = true
              AND (SELECT count(*) FROM hr.employee_status_history WHERE employee_id = v_b) = 2
              AND (SELECT count(*) FROM hr._sanctioned_transitions WHERE kind = 'EMPLOYEE' AND entity_id = v_b) = 1
             THEN 'PASS: replay is a no-op: no new history row, no second ledger row' ELSE 'FAIL: ' || v_r2::text END);

    BEGIN
        PERFORM hr.terminate_employee(v_b, '2026-10-20');
        INSERT INTO "_p04_results" VALUES ('10-replay-different-date', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p04_results" VALUES ('10-replay-different-date', CASE WHEN SQLERRM LIKE 'HR_EMPLOYEE_TERMINATION_REPLAY_MISMATCH%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    BEGIN
        UPDATE hr.employees SET employment_status = 'ON_LEAVE' WHERE id = v_b;
        INSERT INTO "_p04_results" VALUES ('11a-terminal-state-owner', 'FAIL: update succeeded');
    EXCEPTION WHEN OTHERS THEN
        SELECT employment_status::text INTO v_status FROM hr.employees WHERE id = v_b;
        INSERT INTO "_p04_results" VALUES ('11a-terminal-state-owner',
            CASE WHEN SQLERRM LIKE 'HR_EMPLOYEE_TERMINATED_IS_TERMINAL%' AND v_status = 'TERMINATED' THEN 'PASS: a TERMINATED employee cannot leave that state, even for the owner' ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    SELECT version INTO v_cv0 FROM hr.employees WHERE id = v_c;
    BEGIN
        PERFORM hr.terminate_employee(v_c, '2026-05-31');
        INSERT INTO "_p04_results" VALUES ('13-before-hire-date', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        SELECT employment_status::text INTO v_status FROM hr.employees WHERE id = v_c;
        INSERT INTO "_p04_results" VALUES ('13-before-hire-date',
            CASE WHEN SQLERRM LIKE 'HR_TERMINATION_BEFORE_HIRE_DATE%' AND v_status = 'ACTIVE' THEN 'PASS: rejected; employee stays ACTIVE' ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    INSERT INTO "_p04_results" VALUES ('13c-rejected-no-version-change',
        CASE WHEN (SELECT version FROM hr.employees WHERE id = v_c) = v_cv0 THEN 'PASS: the rejected termination changed no version' ELSE 'FAIL: version changed on a rejected call' END);

    BEGIN
        PERFORM hr.terminate_employee(gen_random_uuid(), '2026-10-01');
        INSERT INTO "_p04_results" VALUES ('13b-not-found', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p04_results" VALUES ('13b-not-found', CASE WHEN SQLERRM LIKE 'HR_EMPLOYEE_NOT_FOUND%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    PERFORM set_config('request.jwt.claims', '{}', true);
    BEGIN
        PERFORM hr.terminate_employee(v_c, '2026-10-01');
        INSERT INTO "_p04_results" VALUES ('14-unauthenticated', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p04_results" VALUES ('14-unauthenticated', CASE WHEN SQLERRM LIKE 'HR_UNAUTHENTICATED%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;
END;
$$;

-- terminal guard + other edits as a PEOPLE_MANAGE user; history visibility -------------
SET ROLE "authenticated";
DO $$
DECLARE
    v_b uuid := (SELECT "value"::uuid FROM "_p04_ids" WHERE "key" = 'b');
    v_own uuid := 'c0ad2a68-a478-43bd-b25b-0c080934258b';
    v_rows int; v_status text; v_seen int; v_other int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);

    BEGIN
        UPDATE hr.employees SET employment_status = 'ACTIVE' WHERE id = v_b;
        INSERT INTO "_p04_results" VALUES ('11b-terminal-state-people-manage', 'FAIL: update succeeded');
    EXCEPTION WHEN OTHERS THEN
        SELECT employment_status::text INTO v_status FROM hr.employees WHERE id = v_b;
        INSERT INTO "_p04_results" VALUES ('11b-terminal-state-people-manage',
            CASE WHEN SQLERRM LIKE 'HR_EMPLOYEE_TERMINATED_IS_TERMINAL%' AND v_status = 'TERMINATED' THEN 'PASS: PEOPLE_MANAGE cannot re-activate a TERMINATED employee' ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    UPDATE hr.employees SET employee_number = employee_number || '-r' WHERE id = v_b;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    INSERT INTO "_p04_results" VALUES ('12-other-edits-still-allowed',
        CASE WHEN v_rows = 1 THEN 'PASS: ordinary column edits on a terminated employee are not blocked (guard is narrow)' ELSE 'FAIL: rows updated = ' || v_rows::text END);

    SELECT count(*) INTO v_seen FROM hr.employee_status_history WHERE employee_id = v_b;
    INSERT INTO "_p04_results" VALUES ('17a-people-manage-sees-history',
        CASE WHEN v_seen = 2 THEN 'PASS: PEOPLE_MANAGE reads the history (2 rows for the terminated fixture)' ELSE 'FAIL: saw ' || v_seen::text END);

    PERFORM set_config('request.jwt.claims', json_build_object('sub','00000000-0000-0000-0000-0000000000a1','role','authenticated')::text, true);
    SELECT count(*) INTO v_seen FROM hr.employee_status_history;
    INSERT INTO "_p04_results" VALUES ('17b-unrelated-user-sees-nothing',
        CASE WHEN v_seen = 0 THEN 'PASS: a user with no link and no PEOPLE permission sees 0 history rows' ELSE 'FAIL: saw ' || v_seen::text END);

    PERFORM set_config('request.jwt.claims', json_build_object('sub','ed761a27-783e-43d2-8fcd-ac2f64b29249','role','authenticated')::text, true);
    SELECT count(*) FILTER (WHERE employee_id = v_own), count(*) FILTER (WHERE employee_id <> v_own) INTO v_seen, v_other FROM hr.employee_status_history;
    INSERT INTO "_p04_results" VALUES ('17c-employee-sees-only-own-history',
        CASE WHEN v_seen >= 1 AND v_other = 0 THEN 'PASS: the linked employee sees their own history (' || v_seen::text || ' row(s)) and nobody else''s' ELSE 'FAIL: own=' || v_seen::text || ' others=' || v_other::text END);
END;
$$;
RESET ROLE;

-- immutability, shape/grants, real employees untouched ----------------------------------
DO $$
DECLARE
    v_oid oid := 'hr.terminate_employee(uuid,date)'::regprocedure;
    v_real_after text;
BEGIN
    BEGIN
        UPDATE hr.employee_status_history SET new_status = 'ACTIVE' WHERE true;
        INSERT INTO "_p04_results" VALUES ('16a-history-immutable-update', 'FAIL: UPDATE succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p04_results" VALUES ('16a-history-immutable-update', CASE WHEN SQLERRM LIKE 'HR_APPEND_ONLY%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;
    BEGIN
        DELETE FROM hr.employee_status_history WHERE true;
        INSERT INTO "_p04_results" VALUES ('16b-history-immutable-delete', 'FAIL: DELETE succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p04_results" VALUES ('16b-history-immutable-delete', CASE WHEN SQLERRM LIKE 'HR_APPEND_ONLY%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    INSERT INTO "_p04_results" VALUES ('19-function-shape-and-grants',
        CASE WHEN (SELECT p.prosecdef AND coalesce(p.proconfig::text LIKE '%search_path=%', false) FROM pg_proc p WHERE p.oid = v_oid)
              AND NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
              AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE p.oid = v_oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE')
             THEN 'PASS: SECURITY DEFINER, pinned search_path, no EXECUTE for PUBLIC / anon / authenticated' ELSE 'FAIL: shape or grants differ' END);

    SELECT string_agg(e.id::text || ':' || e.employment_status::text || ':' || coalesce(e.termination_date::text, 'null'), ',' ORDER BY e.id)
    INTO v_real_after FROM hr.employees e WHERE e.employee_number IS NULL OR e.employee_number NOT LIKE 'P04-%';
    INSERT INTO "_p04_results" VALUES ('20-real-employees-untouched',
        CASE WHEN v_real_after IS NOT DISTINCT FROM (SELECT "value" FROM "_p04_ids" WHERE "key" = 'real_before')
             THEN 'PASS: the existing employees (status and termination_date) are identical before and after' ELSE 'FAIL: a real employee changed' END);
END;
$$;

DO $$
DECLARE v_fail int; v_pass int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE "result" LIKE 'FAIL%'), count(*) FILTER (WHERE "result" LIKE 'PASS%'),
           string_agg("step" || ' => ' || "result", E'\n') FILTER (WHERE "result" LIKE 'FAIL%')
    INTO v_fail, v_pass, v_list FROM "_p04_results";
    IF v_fail > 0 THEN RAISE EXCEPTION 'P04_TEST_FAILED: % FAIL, % PASS:%', v_fail, v_pass, E'\n' || v_list; END IF;
    INSERT INTO "_p04_results" VALUES ('99-summary', 'ALL PASS: FAIL count = 0, PASS count = ' || v_pass::text);
END;
$$;
SELECT * FROM "_p04_results" ORDER BY "step";
