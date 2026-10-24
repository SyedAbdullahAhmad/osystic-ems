-- ========================================================================
-- TEST_P03_contracts_termination_and_guard.sql
-- Own fixtures (copied from an existing contract's employee/type keys); the
-- three real contracts are never modified. Fixtures are removed at the end
-- (the immutable ledger rows for the terminated fixtures remain by design).
-- One paste; zero-failure gate at the end; any raise rolls everything back.
-- Note: the SQL editor runs the whole script as ONE transaction, so every
-- sanctioned call and every guarded direct attempt below uses a DIFFERENT
-- fixture contract - a sanction is valid only for its own contract + transaction.
-- ========================================================================
DROP TABLE IF EXISTS "_p03_results";
CREATE TEMP TABLE "_p03_results" ("step" text, "result" text);
GRANT ALL ON "_p03_results" TO "authenticated";
DROP TABLE IF EXISTS "_p03_ids";
CREATE TEMP TABLE "_p03_ids" ("key" text PRIMARY KEY, "value" text);
GRANT ALL ON "_p03_ids" TO "authenticated";

CREATE FUNCTION pg_temp.p03_make(p_template uuid, p_label text, p_run text, p_status text, p_from date, p_to date)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid := gen_random_uuid(); v_ver uuid;
BEGIN
    INSERT INTO hr.contracts (id, employee_id, contract_number, contract_type, status, hr_employee_id, created_at, updated_at, version)
    SELECT v_id, c.employee_id, 'P03-' || p_label || '-' || p_run, c.contract_type, p_status::hr.contract_status, c.hr_employee_id, now(), now(), 1
    FROM hr.contracts c WHERE c.id = p_template;
    INSERT INTO hr.contract_versions (id, contract_id, version_no, effective_from, effective_to, created_at, version)
    VALUES (gen_random_uuid(), v_id, 1, p_from, p_to, now(), 1) RETURNING id INTO v_ver;
    UPDATE hr.contracts SET current_version_id = v_ver WHERE id = v_id;
    RETURN v_id;
END;
$$;

DO $$
DECLARE
    v_tpl uuid := '380d4665-0c52-4c79-9301-b92d045ad4ee';
    v_run text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    v_ids uuid[]; v_k text; v_id uuid;
BEGIN
    -- The audit triggers (_force_created_by) refuse INSERTs without an authenticated session, so fixtures are created as LOCAL_TEST_ADMIN.
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    IF NOT EXISTS (SELECT 1 FROM hr.contracts WHERE id = v_tpl) THEN RAISE EXCEPTION 'SETUP: template contract % not found', v_tpl; END IF;
    IF NOT core.has_permission('2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'CONTRACT_MANAGE') THEN RAISE EXCEPTION 'SETUP: LOCAL_TEST_ADMIN lacks CONTRACT_MANAGE'; END IF;

    -- every fixture is created as ACTIVE/other BEFORE any guard-relevant step
    INSERT INTO "_p03_ids" VALUES
        ('real_before', (SELECT string_agg(c.id::text || ':' || c.status::text || ':' || coalesce(v.effective_to::text, 'null'), ',' ORDER BY c.id)
                         FROM hr.contracts c JOIN hr.contract_versions v ON v.id = c.current_version_id WHERE c.contract_number NOT LIKE 'P03-%')),
        ('direct',   pg_temp.p03_make(v_tpl, 'direct',   v_run, 'ACTIVE', '2026-01-01', NULL)::text),
        ('main',     pg_temp.p03_make(v_tpl, 'main',     v_run, 'ACTIVE', '2026-01-01', NULL)::text),
        ('early',    pg_temp.p03_make(v_tpl, 'early',    v_run, 'ACTIVE', '2026-06-01', NULL)::text),
        ('draft',    pg_temp.p03_make(v_tpl, 'draft',    v_run, 'DRAFT',  '2026-01-01', NULL)::text),
        ('ended',    pg_temp.p03_make(v_tpl, 'ended',    v_run, 'ACTIVE', '2026-01-01', '2026-03-01')::text),
        ('normal',   pg_temp.p03_make(v_tpl, 'normal',   v_run, 'PENDING_APPROVAL', '2026-01-01', NULL)::text);
    INSERT INTO "_p03_results" VALUES ('0-setup', 'fixture contracts created (run ' || v_run || ')');
END;
$$;

-- AS A CONTRACT_MANAGE USER: direct attempts and the normal lifecycle -------
SET ROLE "authenticated";
DO $$
DECLARE
    v_direct uuid := (SELECT "value"::uuid FROM "_p03_ids" WHERE "key" = 'direct');
    v_normal uuid := (SELECT "value"::uuid FROM "_p03_ids" WHERE "key" = 'normal');
    v_status text;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);

    BEGIN
        UPDATE hr.contracts SET status = 'TERMINATED' WHERE id = v_direct;
        INSERT INTO "_p03_results" VALUES ('1-direct-update-to-terminated', 'FAIL: the UPDATE succeeded');
    EXCEPTION WHEN OTHERS THEN
        SELECT status::text INTO v_status FROM hr.contracts WHERE id = v_direct;
        INSERT INTO "_p03_results" VALUES ('1-direct-update-to-terminated',
            CASE WHEN SQLERRM LIKE 'HR_CONTRACT_TERMINATION_NOT_SANCTIONED%' AND v_status = 'ACTIVE' THEN 'PASS: CONTRACT_MANAGE direct UPDATE rejected; contract stays ACTIVE'
                 ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    BEGIN
        PERFORM hr.terminate_contract(v_direct, '2026-10-01');
        INSERT INTO "_p03_results" VALUES ('2-function-not-callable-by-authenticated', 'FAIL: call succeeded');
    EXCEPTION WHEN insufficient_privilege THEN
        INSERT INTO "_p03_results" VALUES ('2-function-not-callable-by-authenticated', 'PASS: permission denied (42501) - internal-only function');
    WHEN OTHERS THEN
        INSERT INTO "_p03_results" VALUES ('2-function-not-callable-by-authenticated', 'FAIL: ' || SQLSTATE || ' ' || SQLERRM);
    END;

    BEGIN
        PERFORM 1 FROM hr._sanctioned_transitions LIMIT 1;
        INSERT INTO "_p03_results" VALUES ('3-ledger-not-readable-by-authenticated', 'FAIL: SELECT succeeded');
    EXCEPTION WHEN insufficient_privilege THEN
        INSERT INTO "_p03_results" VALUES ('3-ledger-not-readable-by-authenticated', 'PASS: permission denied (42501) - the ledger cannot be read or forged by an application role');
    WHEN OTHERS THEN
        INSERT INTO "_p03_results" VALUES ('3-ledger-not-readable-by-authenticated', 'FAIL: ' || SQLSTATE || ' ' || SQLERRM);
    END;

    -- normal lifecycle must still work (guard is narrow): PENDING_APPROVAL -> ACTIVE -> EXPIRED
    UPDATE hr.contracts SET status = 'ACTIVE' WHERE id = v_normal AND status = 'PENDING_APPROVAL';
    UPDATE hr.contracts SET status = 'EXPIRED' WHERE id = v_normal AND status = 'ACTIVE';
    SELECT status::text INTO v_status FROM hr.contracts WHERE id = v_normal;
    INSERT INTO "_p03_results" VALUES ('4-normal-lifecycle-unaffected',
        CASE WHEN v_status = 'EXPIRED' THEN 'PASS: PENDING_APPROVAL -> ACTIVE -> EXPIRED still works for CONTRACT_MANAGE' ELSE 'FAIL: status is ' || coalesce(v_status, 'NULL') END);
END;
$$;
RESET ROLE;

-- direct INSERT as TERMINATED, even by the owner --------------------------------
DO $$
DECLARE v_tpl uuid := '380d4665-0c52-4c79-9301-b92d045ad4ee';
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    BEGIN
        INSERT INTO hr.contracts (id, employee_id, contract_number, contract_type, status, hr_employee_id, created_at, updated_at, version)
        SELECT gen_random_uuid(), c.employee_id, 'P03-insert-' || substr(md5(random()::text), 1, 8), c.contract_type, 'TERMINATED', c.hr_employee_id, now(), now(), 1
        FROM hr.contracts c WHERE c.id = v_tpl;
        INSERT INTO "_p03_results" VALUES ('5-direct-insert-as-terminated', 'FAIL: insert succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p03_results" VALUES ('5-direct-insert-as-terminated',
            CASE WHEN SQLERRM LIKE 'HR_CONTRACT_TERMINATION_NOT_SANCTIONED%' THEN 'PASS: inserting a TERMINATED contract is rejected, even for the table owner' ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;
END;
$$;

-- STALE / MISMATCHED SANCTIONS authorize nothing (team-lead requirement) ----------
-- The sanction must match kind + entity + target status + the CURRENT transaction.
-- Each forged row is planted inside a subtransaction that is always rolled back, so
-- the immutable ledger keeps no trace and the fixture contract stays ACTIVE.
DO $$
DECLARE
    v_direct uuid := (SELECT "value"::uuid FROM "_p03_ids" WHERE "key" = 'direct');
    v_case text; v_outcome text; v_detail text := ''; v_left int; v_status text;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    FOREACH v_case IN ARRAY ARRAY['stale-transaction', 'other-entity', 'other-kind', 'other-status'] LOOP
        v_outcome := 'NOT_REJECTED';
        BEGIN
            IF v_case = 'stale-transaction' THEN
                INSERT INTO hr._sanctioned_transitions (kind, entity_id, to_status, effective_date, txid)
                VALUES ('CONTRACT', v_direct, 'TERMINATED', DATE '2026-10-01', txid_current() - 1);
            ELSIF v_case = 'other-entity' THEN
                INSERT INTO hr._sanctioned_transitions (kind, entity_id, to_status, effective_date)
                VALUES ('CONTRACT', gen_random_uuid(), 'TERMINATED', DATE '2026-10-01');
            ELSIF v_case = 'other-kind' THEN
                INSERT INTO hr._sanctioned_transitions (kind, entity_id, to_status, effective_date)
                VALUES ('EMPLOYEE', v_direct, 'TERMINATED', DATE '2026-10-01');
            ELSE
                INSERT INTO hr._sanctioned_transitions (kind, entity_id, to_status, effective_date)
                VALUES ('CONTRACT', v_direct, 'ACTIVE', DATE '2026-10-01');
            END IF;
            BEGIN
                UPDATE hr.contracts SET status = 'TERMINATED' WHERE id = v_direct;
                v_outcome := 'NOT_REJECTED';
            EXCEPTION WHEN OTHERS THEN
                v_outcome := CASE WHEN SQLERRM LIKE 'HR_CONTRACT_TERMINATION_NOT_SANCTIONED%' THEN 'REJECTED' ELSE 'WRONG_ERROR:' || SQLSTATE END;
            END;
            RAISE EXCEPTION 'P03_ROLLBACK_PLANTED_ROW';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'P03_ROLLBACK_PLANTED_ROW' THEN v_outcome := 'SETUP_ERROR:' || SQLERRM; END IF;
        END;
        IF v_outcome <> 'REJECTED' THEN v_detail := v_detail || ' ' || v_case || '=' || v_outcome; END IF;
    END LOOP;

    SELECT count(*) INTO v_left FROM hr._sanctioned_transitions WHERE entity_id = v_direct;
    SELECT status::text INTO v_status FROM hr.contracts WHERE id = v_direct;
    INSERT INTO "_p03_results" VALUES ('21-stale-and-mismatched-sanctions-authorize-nothing',
        CASE WHEN v_detail = '' AND v_left = 0 AND v_status = 'ACTIVE'
             THEN 'PASS: a ledger row from an earlier transaction, for another entity, of another kind, or for another status each authorize nothing; planted rows rolled back; the contract stayed ACTIVE'
             ELSE 'FAIL:' || v_detail || ' / leftover ledger rows=' || v_left::text || ' / status=' || coalesce(v_status, 'NULL') END);
END;
$$;

-- SANCTIONED PATH (owner session standing in for complete_offboarding) ----------
DO $$
DECLARE
    v_main uuid := (SELECT "value"::uuid FROM "_p03_ids" WHERE "key" = 'main');
    v_early uuid := (SELECT "value"::uuid FROM "_p03_ids" WHERE "key" = 'early');
    v_draft uuid := (SELECT "value"::uuid FROM "_p03_ids" WHERE "key" = 'draft');
    v_ended uuid := (SELECT "value"::uuid FROM "_p03_ids" WHERE "key" = 'ended');
    v_r jsonb; v_r2 jsonb; v_to date; v_versions int; v_status text;
    v_cv0 int; v_vv0 int; v_cv1 int; v_vv1 int; v_cv2 int; v_vv2 int; v_ec0 int; v_dc0 int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);

    SELECT c.version, v.version INTO v_cv0, v_vv0 FROM hr.contracts c JOIN hr.contract_versions v ON v.id = c.current_version_id WHERE c.id = v_main;
    v_r := hr.terminate_contract(v_main, '2026-10-01');
    SELECT c.status::text, v.effective_to, (SELECT count(*) FROM hr.contract_versions x WHERE x.contract_id = c.id)
    INTO v_status, v_to, v_versions FROM hr.contracts c JOIN hr.contract_versions v ON v.id = c.current_version_id WHERE c.id = v_main;
    INSERT INTO "_p03_results" VALUES ('6-sanctioned-termination',
        CASE WHEN v_status = 'TERMINATED' AND v_to = '2026-10-01' AND v_versions = 1 AND (v_r->>'idempotent_replay')::boolean = false
             THEN 'PASS: TERMINATED, current version closed at 2026-10-01, still exactly 1 version row (no new version)' ELSE 'FAIL: ' || v_r::text || ' / versions=' || v_versions::text END);

    SELECT c.version, v.version INTO v_cv1, v_vv1 FROM hr.contracts c JOIN hr.contract_versions v ON v.id = c.current_version_id WHERE c.id = v_main;
    INSERT INTO "_p03_results" VALUES ('6b-version-increments-exactly-once',
        CASE WHEN v_cv1 = v_cv0 + 1 AND v_vv1 = v_vv0 + 1
             THEN 'PASS: contract version ' || v_cv0::text || ' -> ' || v_cv1::text || ' and closed contract_versions row ' || v_vv0::text || ' -> ' || v_vv1::text
             ELSE 'FAIL: contract ' || v_cv0::text || ' -> ' || v_cv1::text || ', contract_versions row ' || v_vv0::text || ' -> ' || v_vv1::text END);

    v_r2 := hr.terminate_contract(v_main, '2026-10-01');
    SELECT c.version, v.version INTO v_cv2, v_vv2 FROM hr.contracts c JOIN hr.contract_versions v ON v.id = c.current_version_id WHERE c.id = v_main;
    INSERT INTO "_p03_results" VALUES ('7b-replay-no-version-change',
        CASE WHEN v_cv2 = v_cv1 AND v_vv2 = v_vv1 THEN 'PASS: replay left both versions unchanged (' || v_cv2::text || ' / ' || v_vv2::text || ')'
             ELSE 'FAIL: replay changed a version' END);
    INSERT INTO "_p03_results" VALUES ('7-replay-same-date-idempotent',
        CASE WHEN (v_r2->>'idempotent_replay')::boolean = true AND (v_r2->>'effective_to')::date = '2026-10-01'
              AND (SELECT count(*) FROM hr._sanctioned_transitions WHERE kind = 'CONTRACT' AND entity_id = v_main) = 1
             THEN 'PASS: replay is a no-op and writes no second ledger row' ELSE 'FAIL: ' || v_r2::text END);

    BEGIN
        PERFORM hr.terminate_contract(v_main, '2026-10-15');
        INSERT INTO "_p03_results" VALUES ('8-replay-different-date', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p03_results" VALUES ('8-replay-different-date', CASE WHEN SQLERRM LIKE 'HR_CONTRACT_TERMINATION_REPLAY_MISMATCH%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    SELECT c.version INTO v_ec0 FROM hr.contracts c WHERE c.id = v_early;
    SELECT c.version INTO v_dc0 FROM hr.contracts c WHERE c.id = v_draft;
    BEGIN
        PERFORM hr.terminate_contract(v_early, '2026-05-31');
        INSERT INTO "_p03_results" VALUES ('9-date-before-effective-from', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        SELECT status::text INTO v_status FROM hr.contracts WHERE id = v_early;
        INSERT INTO "_p03_results" VALUES ('9-date-before-effective-from',
            CASE WHEN SQLERRM LIKE 'HR_TERMINATION_BEFORE_EFFECTIVE_FROM%' AND v_status = 'ACTIVE' THEN 'PASS: rejected; contract stays ACTIVE' ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    BEGIN
        PERFORM hr.terminate_contract(v_draft, '2026-10-01');
        INSERT INTO "_p03_results" VALUES ('10-not-active', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p03_results" VALUES ('10-not-active', CASE WHEN SQLERRM LIKE 'HR_CONTRACT_NOT_ACTIVE%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    INSERT INTO "_p03_results" VALUES ('10b-rejected-no-version-change',
        CASE WHEN (SELECT version FROM hr.contracts WHERE id = v_early) = v_ec0 AND (SELECT version FROM hr.contracts WHERE id = v_draft) = v_dc0
             THEN 'PASS: the two rejected terminations changed no version' ELSE 'FAIL: a version changed on a rejected call' END);

    v_r := hr.terminate_contract(v_ended, '2026-10-01');
    INSERT INTO "_p03_results" VALUES ('11-never-extends-an-earlier-end',
        CASE WHEN (v_r->>'effective_to')::date = '2026-03-01' THEN 'PASS: a version that already ended on 2026-03-01 keeps that end date (LEAST rule)' ELSE 'FAIL: effective_to ' || (v_r->>'effective_to') END);

    BEGIN
        PERFORM hr.terminate_contract(gen_random_uuid(), '2026-10-01');
        INSERT INTO "_p03_results" VALUES ('12-not-found', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p03_results" VALUES ('12-not-found', CASE WHEN SQLERRM LIKE 'HR_CONTRACT_NOT_FOUND%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    PERFORM set_config('request.jwt.claims', '{}', true);
    BEGIN
        PERFORM hr.terminate_contract(v_early, '2026-10-01');
        INSERT INTO "_p03_results" VALUES ('13-unauthenticated', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p03_results" VALUES ('13-unauthenticated', CASE WHEN SQLERRM LIKE 'HR_UNAUTHENTICATED%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;
END;
$$;

-- ledger immutability, shape/grants, real contracts untouched, cleanup ----------
DO $$
DECLARE
    v_oid oid := 'hr.terminate_contract(uuid,date)'::regprocedure;
    v_fix uuid[] := ARRAY(SELECT "value"::uuid FROM "_p03_ids" WHERE "key" IN ('direct','main','early','draft','ended','normal'));
    v_real_after text; v_left int;
BEGIN
    BEGIN
        UPDATE hr._sanctioned_transitions SET to_status = 'ACTIVE' WHERE true;
        INSERT INTO "_p03_results" VALUES ('14-ledger-immutable', 'FAIL: UPDATE succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p03_results" VALUES ('14-ledger-immutable', CASE WHEN SQLERRM LIKE 'HR_APPEND_ONLY%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    INSERT INTO "_p03_results" VALUES ('15-function-shape-and-grants',
        CASE WHEN (SELECT p.prosecdef AND coalesce(p.proconfig::text LIKE '%search_path=%', false) FROM pg_proc p WHERE p.oid = v_oid)
              AND NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
              AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE p.oid = v_oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE')
             THEN 'PASS: SECURITY DEFINER, pinned search_path, no EXECUTE for PUBLIC / anon / authenticated' ELSE 'FAIL: shape or grants differ' END);

    SELECT string_agg(c.id::text || ':' || c.status::text || ':' || coalesce(v.effective_to::text, 'null'), ',' ORDER BY c.id)
    INTO v_real_after FROM hr.contracts c JOIN hr.contract_versions v ON v.id = c.current_version_id WHERE c.contract_number NOT LIKE 'P03-%';
    INSERT INTO "_p03_results" VALUES ('16-real-contracts-untouched',
        CASE WHEN v_real_after IS NOT DISTINCT FROM (SELECT "value" FROM "_p03_ids" WHERE "key" = 'real_before')
             THEN 'PASS: the real contracts (status and version end dates) are identical before and after' ELSE 'FAIL: a real contract changed' END);

    -- cleanup: break the contracts <-> versions cycle, then delete (the immutable ledger rows stay by design)
    UPDATE hr.contracts SET current_version_id = NULL WHERE id = ANY (v_fix);
    DELETE FROM hr.contract_versions WHERE contract_id = ANY (v_fix);
    DELETE FROM hr.contracts WHERE id = ANY (v_fix);
    SELECT (SELECT count(*) FROM hr.contracts WHERE id = ANY (v_fix)) + (SELECT count(*) FROM hr.contract_versions WHERE contract_id = ANY (v_fix)) INTO v_left;
    INSERT INTO "_p03_results" VALUES ('17-fixtures-removed', CASE WHEN v_left = 0 THEN 'PASS: all fixture contracts and versions removed' ELSE 'FAIL: ' || v_left::text || ' left' END);
END;
$$;

DO $$
DECLARE v_fail int; v_pass int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE "result" LIKE 'FAIL%'), count(*) FILTER (WHERE "result" LIKE 'PASS%'),
           string_agg("step" || ' => ' || "result", E'\n') FILTER (WHERE "result" LIKE 'FAIL%')
    INTO v_fail, v_pass, v_list FROM "_p03_results";
    IF v_fail > 0 THEN RAISE EXCEPTION 'P03_TEST_FAILED: % FAIL, % PASS:%', v_fail, v_pass, E'\n' || v_list; END IF;
    INSERT INTO "_p03_results" VALUES ('99-summary', 'ALL PASS: FAIL count = 0, PASS count = ' || v_pass::text);
END;
$$;
SELECT * FROM "_p03_results" ORDER BY "step";
