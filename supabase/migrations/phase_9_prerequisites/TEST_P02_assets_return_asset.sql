-- ========================================================================
-- TEST_P02_assets_return_asset.sql
-- Creates its OWN fixture assets/assignments (never touches the two real open
-- assignments), tests assets.return_asset(), and deletes its fixtures at the
-- end. One paste; zero-failure gate at the end; any raise rolls everything back.
-- ========================================================================
DROP TABLE IF EXISTS "_p02_results";
CREATE TEMP TABLE "_p02_results" ("step" text, "result" text);
GRANT ALL ON "_p02_results" TO "authenticated";
DROP TABLE IF EXISTS "_p02_ids";
CREATE TEMP TABLE "_p02_ids" ("key" text PRIMARY KEY, "value" text);
GRANT ALL ON "_p02_ids" TO "authenticated";

DO $$
DECLARE
    v_admin uuid := '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2';
    v_plain uuid := '00000000-0000-0000-0000-0000000000a1';
    v_tpl assets.asset_assignments;
    v_run text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    v_asset_a uuid := gen_random_uuid(); v_asset_b uuid := gen_random_uuid(); v_asset_c uuid := gen_random_uuid();
    v_as_a uuid := gen_random_uuid(); v_as_b uuid := gen_random_uuid(); v_as_c uuid := gen_random_uuid();
    v_cat uuid;
BEGIN
    -- The audit triggers (_force_created_by) refuse INSERTs without an authenticated session, so fixtures are created as LOCAL_TEST_ADMIN.
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    IF NOT core.has_permission(v_admin, 'ASSET_MANAGE') THEN RAISE EXCEPTION 'SETUP: LOCAL_TEST_ADMIN lacks ASSET_MANAGE'; END IF;
    IF core.has_permission(v_plain, 'ASSET_MANAGE') THEN RAISE EXCEPTION 'SETUP: fixture user a1 unexpectedly holds ASSET_MANAGE'; END IF;
    SELECT * INTO v_tpl FROM assets.asset_assignments ORDER BY assigned_at LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'SETUP: no existing assignment to copy request/employee keys from'; END IF;
    SELECT asset_category_id INTO v_cat FROM assets.assets WHERE id = v_tpl.asset_id;

    -- A: normal open assignment; B: asset in repair but assignment open (inconsistent);
    -- C: used by the one-open-assignment-per-asset invariant check
    -- P06: once the status guard exists, fixtures that claim ASSIGNED need a sanction for this
    -- transaction. Skipped automatically when P06 is not applied (runs before and after P06).
    IF to_regclass('assets._sanctioned_transitions') IS NOT NULL THEN
        EXECUTE 'INSERT INTO assets._sanctioned_transitions (asset_id, to_status) VALUES ($1, ''ASSIGNED''), ($2, ''ASSIGNED'')'
            USING v_asset_a, v_asset_c;
    END IF;
    INSERT INTO assets.assets (id, asset_category_id, asset_code, asset_name, serial_number, current_status, created_at, updated_at, version)
    VALUES (v_asset_a, v_cat, 'P02-A-' || v_run, 'P02 test asset A', 'P02A' || v_run, 'ASSIGNED', now(), now(), 1),
           (v_asset_b, v_cat, 'P02-B-' || v_run, 'P02 test asset B', 'P02B' || v_run, 'IN_REPAIR', now(), now(), 1),
           (v_asset_c, v_cat, 'P02-C-' || v_run, 'P02 test asset C', 'P02C' || v_run, 'ASSIGNED', now(), now(), 1);
    INSERT INTO assets.asset_assignments (id, asset_request_id, asset_id, employee_id, hr_employee_id, assigned_by, assigned_at, created_at, version)
    VALUES (v_as_a,  v_tpl.asset_request_id, v_asset_a, v_tpl.employee_id, v_tpl.hr_employee_id, v_tpl.assigned_by, now(), now(), 1),
           (v_as_b,  v_tpl.asset_request_id, v_asset_b, v_tpl.employee_id, v_tpl.hr_employee_id, v_tpl.assigned_by, now(), now(), 1),
           (v_as_c,  v_tpl.asset_request_id, v_asset_c, v_tpl.employee_id, v_tpl.hr_employee_id, v_tpl.assigned_by, now(), now(), 1);
    INSERT INTO "_p02_ids" VALUES ('asset_a', v_asset_a::text), ('asset_b', v_asset_b::text), ('asset_c', v_asset_c::text),
        ('as_a', v_as_a::text), ('as_b', v_as_b::text), ('as_c', v_as_c::text),
        ('open_before', (SELECT count(*) FROM assets.asset_assignments WHERE returned_at IS NULL AND id NOT IN (v_as_a, v_as_b, v_as_c))::text);
    INSERT INTO "_p02_results" VALUES ('0-setup', 'fixtures created (run ' || v_run || '); real open assignments untouched');
END;
$$;

-- unprivileged + unauthenticated + not found -------------------------------
SET ROLE "authenticated";
DO $$
DECLARE v_as_a uuid := (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'as_a');
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','00000000-0000-0000-0000-0000000000a1','role','authenticated')::text, true);
    BEGIN
        PERFORM assets.return_asset(v_as_a);
        INSERT INTO "_p02_results" VALUES ('1-no-ASSET_MANAGE', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p02_results" VALUES ('1-no-ASSET_MANAGE', CASE WHEN SQLERRM LIKE 'ASSETS_NOT_AUTHORIZED%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    PERFORM set_config('request.jwt.claims', '{}', true);
    BEGIN
        PERFORM assets.return_asset(v_as_a);
        INSERT INTO "_p02_results" VALUES ('2-unauthenticated', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p02_results" VALUES ('2-unauthenticated', CASE WHEN SQLERRM LIKE 'ASSETS_UNAUTHENTICATED%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;
END;
$$;

-- ASSET_MANAGE user: success, replay, not found, inconsistent, conflict -----
DO $$
DECLARE
    v_as_a uuid := (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'as_a');
    v_as_b uuid := (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'as_b');
    v_asset_a uuid := (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'asset_a');
    v_asset_b uuid := (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'asset_b');
    v_r1 jsonb; v_r2 jsonb; v_ra timestamptz; v_st assets.asset_status; v_rows int;
    v_av0 int; v_sv0 int; v_av1 int; v_sv1 int; v_av2 int; v_sv2 int; v_bav0 int; v_bsv0 int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);

    SELECT version INTO v_av0 FROM assets.asset_assignments WHERE id = v_as_a;
    SELECT version INTO v_sv0 FROM assets.assets WHERE id = v_asset_a;
    v_r1 := assets.return_asset(v_as_a);
    SELECT returned_at INTO v_ra FROM assets.asset_assignments WHERE id = v_as_a;
    SELECT current_status INTO v_st FROM assets.assets WHERE id = v_asset_a;
    INSERT INTO "_p02_results" VALUES ('3-return-success',
        CASE WHEN (v_r1->>'idempotent_replay')::boolean = false AND v_ra IS NOT NULL AND v_st = 'AVAILABLE'
             THEN 'PASS: returned_at set and asset AVAILABLE in the same call' ELSE 'FAIL: ' || v_r1::text || ' / ' || coalesce(v_st::text, 'NULL') END);

    SELECT version INTO v_av1 FROM assets.asset_assignments WHERE id = v_as_a;
    SELECT version INTO v_sv1 FROM assets.assets WHERE id = v_asset_a;
    INSERT INTO "_p02_results" VALUES ('3b-version-increments-exactly-once',
        CASE WHEN v_av1 = v_av0 + 1 AND v_sv1 = v_sv0 + 1
             THEN 'PASS: assignment version ' || v_av0::text || ' -> ' || v_av1::text || ' and asset version ' || v_sv0::text || ' -> ' || v_sv1::text
             ELSE 'FAIL: assignment ' || v_av0::text || ' -> ' || v_av1::text || ', asset ' || v_sv0::text || ' -> ' || v_sv1::text END);

    v_r2 := assets.return_asset(v_as_a);
    SELECT version INTO v_av2 FROM assets.asset_assignments WHERE id = v_as_a;
    SELECT version INTO v_sv2 FROM assets.assets WHERE id = v_asset_a;
    INSERT INTO "_p02_results" VALUES ('4b-replay-no-version-change',
        CASE WHEN v_av2 = v_av1 AND v_sv2 = v_sv1 THEN 'PASS: replay left both versions unchanged (' || v_av2::text || ' / ' || v_sv2::text || ')'
             ELSE 'FAIL: replay changed a version: assignment ' || v_av1::text || ' -> ' || v_av2::text || ', asset ' || v_sv1::text || ' -> ' || v_sv2::text END);
    INSERT INTO "_p02_results" VALUES ('4-replay-idempotent',
        CASE WHEN (v_r2->>'idempotent_replay')::boolean = true
              AND v_r2->>'returned_at' IS NOT DISTINCT FROM v_r1->>'returned_at'
              AND (SELECT returned_at FROM assets.asset_assignments WHERE id = v_as_a) = v_ra
              AND (SELECT current_status FROM assets.assets WHERE id = v_asset_a) = 'AVAILABLE'
             THEN 'PASS: replay returned the same recorded returned_at and changed nothing' ELSE 'FAIL: ' || v_r2::text END);

    BEGIN
        PERFORM assets.return_asset(gen_random_uuid());
        INSERT INTO "_p02_results" VALUES ('5-not-found', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p02_results" VALUES ('5-not-found', CASE WHEN SQLERRM LIKE 'ASSETS_ASSIGNMENT_NOT_FOUND%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    SELECT version INTO v_bav0 FROM assets.asset_assignments WHERE id = v_as_b;
    SELECT version INTO v_bsv0 FROM assets.assets WHERE id = v_asset_b;
    BEGIN
        PERFORM assets.return_asset(v_as_b);
        INSERT INTO "_p02_results" VALUES ('6-asset-state-inconsistent', 'FAIL: call succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_p02_results" VALUES ('6-asset-state-inconsistent',
            CASE WHEN SQLERRM LIKE 'ASSETS_ASSET_STATE_INCONSISTENT%' AND (SELECT returned_at FROM assets.asset_assignments WHERE id = v_as_b) IS NULL
                 THEN 'PASS: rejected and the assignment stays open' ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;

    INSERT INTO "_p02_results" VALUES ('6b-rejected-no-version-change',
        CASE WHEN (SELECT version FROM assets.asset_assignments WHERE id = v_as_b) = v_bav0
              AND (SELECT version FROM assets.assets WHERE id = v_asset_b) = v_bsv0
             THEN 'PASS: the rejected return changed no version' ELSE 'FAIL: a version changed on a rejected call' END);

    -- direct write path: even an ASSET_MANAGE holder cannot set returned_at on the table (no UPDATE policy)
    UPDATE assets.asset_assignments SET returned_at = now() WHERE id = v_as_b;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    INSERT INTO "_p02_results" VALUES ('8-direct-update-denied',
        CASE WHEN v_rows = 0 AND (SELECT returned_at FROM assets.asset_assignments WHERE id = v_as_b) IS NULL
             THEN 'PASS: direct UPDATE of returned_at affects 0 rows (RLS); only the function can record a return'
             ELSE 'FAIL: direct UPDATE changed ' || v_rows::text || ' row(s)' END);
END;
$$;
RESET ROLE;

-- shape / grants, real assignments untouched, cleanup -----------------------
DO $$
DECLARE
    v_oid oid := 'assets.return_asset(uuid)'::regprocedure;
    v_open_before int := (SELECT "value"::int FROM "_p02_ids" WHERE "key" = 'open_before');
    v_ids uuid[] := ARRAY[(SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'as_a'), (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'as_b'),
                          (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'as_c')];
    v_assets uuid[] := ARRAY[(SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'asset_a'), (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'asset_b'),
                             (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'asset_c')];
    v_left int;
BEGIN
    INSERT INTO "_p02_results" VALUES ('9-function-shape-and-grants',
        CASE WHEN (SELECT p.prosecdef AND coalesce(p.proconfig::text LIKE '%search_path=%', false) FROM pg_proc p WHERE p.oid = v_oid)
              AND has_function_privilege('authenticated', v_oid, 'EXECUTE')
              AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
              AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a WHERE p.oid = v_oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE')
             THEN 'PASS: SECURITY DEFINER, pinned search_path, EXECUTE for authenticated only (PUBLIC and anon revoked)' ELSE 'FAIL: shape or grants differ' END);

    INSERT INTO "_p02_results" VALUES ('10-real-assignments-untouched',
        CASE WHEN (SELECT count(*) FROM assets.asset_assignments WHERE returned_at IS NULL AND id <> ALL (v_ids)) = v_open_before
             THEN 'PASS: the ' || v_open_before::text || ' real open assignment(s) were not touched' ELSE 'FAIL: real open assignment count changed' END);

    -- the live invariant the function relies on: one OPEN assignment per asset
    DECLARE
        v_asset_c uuid := (SELECT "value"::uuid FROM "_p02_ids" WHERE "key" = 'asset_c');
        v_tpl assets.asset_assignments;
        v_cname text;
    BEGIN
        SELECT * INTO v_tpl FROM assets.asset_assignments WHERE id = v_ids[3];
        BEGIN
            INSERT INTO assets.asset_assignments (id, asset_request_id, asset_id, employee_id, hr_employee_id, assigned_by, assigned_at, created_at, version)
            VALUES (gen_random_uuid(), v_tpl.asset_request_id, v_asset_c, v_tpl.employee_id, v_tpl.hr_employee_id, v_tpl.assigned_by, now(), now(), 1);
            INSERT INTO "_p02_results" VALUES ('7-one-open-assignment-per-asset', 'FAIL: a second open assignment for the same asset was accepted');
        EXCEPTION WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
            INSERT INTO "_p02_results" VALUES ('7-one-open-assignment-per-asset',
                CASE WHEN v_cname = 'idx_asset_assignments_one_active_per_asset' THEN 'PASS: the database rejects a second open assignment (idx_asset_assignments_one_active_per_asset), so return_asset needs no extra conflict check'
                     ELSE 'FAIL: unique violation on ' || coalesce(v_cname, 'NULL') END);
        END;
    END;

    DELETE FROM assets.asset_assignments WHERE id = ANY (v_ids);
    DELETE FROM assets.assets WHERE id = ANY (v_assets);
    SELECT (SELECT count(*) FROM assets.asset_assignments WHERE id = ANY (v_ids)) + (SELECT count(*) FROM assets.assets WHERE id = ANY (v_assets)) INTO v_left;
    INSERT INTO "_p02_results" VALUES ('11-fixtures-removed', CASE WHEN v_left = 0 THEN 'PASS: all fixture rows removed' ELSE 'FAIL: ' || v_left::text || ' fixture row(s) left' END);
END;
$$;

DO $$
DECLARE v_fail int; v_pass int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE "result" LIKE 'FAIL%'), count(*) FILTER (WHERE "result" LIKE 'PASS%'),
           string_agg("step" || ' => ' || "result", E'\n') FILTER (WHERE "result" LIKE 'FAIL%')
    INTO v_fail, v_pass, v_list FROM "_p02_results";
    IF v_fail > 0 THEN RAISE EXCEPTION 'P02_TEST_FAILED: % FAIL, % PASS:%', v_fail, v_pass, E'\n' || v_list; END IF;
    INSERT INTO "_p02_results" VALUES ('99-summary', 'ALL PASS: FAIL count = 0, PASS count = ' || v_pass::text);
END;
$$;
SELECT * FROM "_p02_results" ORDER BY "step";
