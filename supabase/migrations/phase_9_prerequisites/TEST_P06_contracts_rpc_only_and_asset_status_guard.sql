-- ========================================================================
-- TEST_P06_contracts_rpc_only_and_asset_status_guard.sql
-- Run AFTER P06. Persists nothing: every fixture lives in a rolled-back sub-block.
-- Gate: any FAIL -> RAISE EXCEPTION; zero failures -> RAISE NOTICE + result table.
-- Needs: one account holding CONTRACT_MANAGE and one holding ASSET_MANAGE (may be the
-- same), at least one asset category, at least one auth user.
-- ========================================================================
DROP TABLE IF EXISTS "_p06_results";
CREATE TEMP TABLE "_p06_results" ("step" text, "result" text);

DO $$
DECLARE
    v_cm uuid; v_am uuid; v_emp uuid; v_cat uuid;
    v_res text[] := ARRAY[]::text[];
    v_a uuid; v_b uuid; v_req uuid; v_asg uuid;
    v_state text; v_msg text; v_n int; v_ver0 int; v_ver int; v_ledger int; v_priv text;
    r text;
BEGIN
    SELECT id INTO v_cm  FROM auth.users WHERE core.has_permission(id,'CONTRACT_MANAGE') ORDER BY created_at LIMIT 1;
    SELECT id INTO v_am  FROM auth.users WHERE core.has_permission(id,'ASSET_MANAGE')    ORDER BY created_at LIMIT 1;
    SELECT id INTO v_emp FROM auth.users ORDER BY created_at LIMIT 1;
    SELECT id INTO v_cat FROM assets.asset_categories LIMIT 1;
    IF v_cm IS NULL OR v_am IS NULL OR v_cat IS NULL THEN
        RAISE EXCEPTION 'SETUP: contract_manager=%, asset_manager=%, category=%', v_cm, v_am, v_cat; END IF;

    ------------------------------------------------------------------ 1. static state
    r := 'PASS';
    FOREACH v_priv IN ARRAY ARRAY['INSERT','UPDATE','DELETE'] LOOP
        IF has_table_privilege('authenticated','hr.contracts',v_priv) OR has_table_privilege('authenticated','hr.contract_versions',v_priv) THEN
            r := 'FAIL: authenticated still holds ' || v_priv || ' on contracts/contract_versions'; END IF;
    END LOOP;
    IF NOT has_table_privilege('authenticated','hr.contracts','SELECT') OR NOT has_table_privilege('authenticated','hr.contract_versions','SELECT') THEN
        r := 'FAIL: lost SELECT on contracts/contract_versions'; END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='hr' AND tablename IN ('contracts','contract_versions') AND cmd <> 'SELECT') THEN
        r := 'FAIL: a non-SELECT policy remains on contracts/contract_versions'; END IF;
    v_res := v_res || ARRAY['1a-contracts-read-only-at-privilege-and-policy-level|' || r];

    r := 'PASS';
    IF has_table_privilege('authenticated','assets.assets','DELETE') THEN r := 'FAIL: DELETE still granted on assets.assets'; END IF;
    IF NOT (has_table_privilege('authenticated','assets.assets','INSERT') AND has_table_privilege('authenticated','assets.assets','UPDATE')) THEN
        r := 'FAIL: ASSET_MANAGE write path (INSERT/UPDATE) was removed'; END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname='assets' AND tablename='assets') <> 3 THEN r := 'FAIL: assets.assets must have exactly insert/update/select policies'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='assets.assets'::regclass AND tgname='trg_assets_guard_status' AND tgenabled <> 'D') THEN r := 'FAIL: status guard trigger missing'; END IF;
    v_res := v_res || ARRAY['1b-assets-privileges-policies-guard|' || r];

    r := 'PASS';
    IF has_table_privilege('authenticated','assets._sanctioned_transitions','SELECT') OR has_table_privilege('authenticated','assets._sanctioned_transitions','INSERT')
       OR has_table_privilege('anon','assets._sanctioned_transitions','SELECT') THEN r := 'FAIL: ledger readable/writable by an app role'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid='assets._sanctioned_transitions'::regclass AND relrowsecurity) THEN r := 'FAIL: ledger RLS not enabled'; END IF;
    v_res := v_res || ARRAY['1c-sanction-ledger-locked-down|' || r];

    ------------------------------------------------------------------ 2. contracts: app role cannot write
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cm, 'role','authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', v_cm::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN INSERT INTO hr.contracts (employee_id, contract_number, contract_type) VALUES (v_cm, 'P06T-' || substr(gen_random_uuid()::text,1,8), 'PERMANENT'); r := 'FAIL: direct INSERT succeeded';
    EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: unexpected ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2a-contracts-direct-insert-denied|' || r];
    BEGIN UPDATE hr.contracts SET status = 'ACTIVE' WHERE id = gen_random_uuid(); r := 'FAIL: direct UPDATE accepted';
    EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: unexpected ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2b-contracts-direct-update-denied|' || r];
    BEGIN DELETE FROM hr.contracts WHERE id = gen_random_uuid(); r := 'FAIL: direct DELETE accepted';
    EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: unexpected ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2c-contracts-direct-delete-denied|' || r];
    BEGIN INSERT INTO hr.contract_versions (contract_id, version_no, effective_from) VALUES (gen_random_uuid(), 1, current_date); r := 'FAIL: direct INSERT succeeded';
    EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: unexpected ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2d-contract-versions-direct-insert-denied|' || r];
    BEGIN UPDATE hr.contract_versions SET notes = 'x' WHERE id = gen_random_uuid(); r := 'FAIL: direct UPDATE accepted';
    EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: unexpected ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2e-contract-versions-direct-update-denied|' || r];
    BEGIN DELETE FROM hr.contract_versions WHERE id = gen_random_uuid(); r := 'FAIL: direct DELETE accepted';
    EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: unexpected ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2f-contract-versions-direct-delete-denied|' || r];
    BEGIN PERFORM count(*) FROM hr.contracts; PERFORM count(*) FROM hr.contract_versions; r := 'PASS';
    EXCEPTION WHEN OTHERS THEN r := 'FAIL: CONTRACT_MANAGE holder lost read access: ' || SQLSTATE; END;
    v_res := v_res || ARRAY['2g-contract-manage-can-still-read|' || r];
    RESET ROLE;

    ------------------------------------------------------------------ 3. P03 guard still works independently of privileges (owner session)
    BEGIN
        INSERT INTO hr.contracts (employee_id, contract_number, contract_type) VALUES (v_emp, 'P06G-' || substr(gen_random_uuid()::text,1,8), 'PERMANENT') RETURNING id INTO v_a;
        BEGIN UPDATE hr.contracts SET status = 'TERMINATED' WHERE id = v_a; r := 'FAIL: guard did not fire';
        EXCEPTION WHEN OTHERS THEN
            r := CASE WHEN SQLERRM LIKE 'HR_CONTRACT_TERMINATION_NOT_SANCTIONED%' THEN 'PASS' ELSE 'FAIL: wrong error ' || SQLERRM END;
        END;
        v_res := v_res || ARRAY['3-p03-termination-guard-still-fires-for-owner|' || r];
        RAISE EXCEPTION 'P06_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'P06_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['3-p03-guard-block|FAIL: ' || SQLERRM]; END IF;
    END;

    ------------------------------------------------------------------ 4. assets: ASSET_MANAGE direct writes
    BEGIN
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_am, 'role','authenticated')::text, true);
        PERFORM set_config('request.jwt.claim.sub', v_am::text, true);
        INSERT INTO assets.assets (asset_category_id, asset_code, asset_name) VALUES (v_cat, 'P06A-' || substr(gen_random_uuid()::text,1,8), 'p06 fixture A') RETURNING id, version INTO v_a, v_ver0;
        SET LOCAL ROLE authenticated;

        BEGIN INSERT INTO assets.assets (asset_category_id, asset_code, asset_name, current_status) VALUES (v_cat, 'P06X-' || substr(gen_random_uuid()::text,1,8), 'claims ASSIGNED', 'ASSIGNED'); r := 'FAIL: INSERT as ASSIGNED accepted';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'ASSETS_STATUS_CHANGE_NOT_SANCTIONED%' THEN 'PASS' ELSE 'FAIL: wrong error ' || SQLERRM END; END;
        v_res := v_res || ARRAY['4a-insert-as-assigned-rejected|' || r];

        BEGIN INSERT INTO assets.assets (asset_category_id, asset_code, asset_name) VALUES (v_cat, 'P06B-' || substr(gen_random_uuid()::text,1,8), 'p06 fixture B'); r := 'PASS';
        EXCEPTION WHEN OTHERS THEN r := 'FAIL: inventory registration broke: ' || SQLERRM; END;
        v_res := v_res || ARRAY['4b-inventory-insert-still-works|' || r];

        BEGIN UPDATE assets.assets SET current_status = 'ASSIGNED' WHERE id = v_a; r := 'FAIL: direct AVAILABLE->ASSIGNED accepted';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'ASSETS_STATUS_CHANGE_NOT_SANCTIONED%' THEN 'PASS' ELSE 'FAIL: wrong error ' || SQLERRM END; END;
        SELECT current_status::text, version INTO v_state, v_ver FROM assets.assets WHERE id = v_a;
        IF r = 'PASS' AND (v_state <> 'AVAILABLE' OR v_ver <> v_ver0) THEN r := 'FAIL: state or version changed despite rejection'; END IF;
        v_res := v_res || ARRAY['4c-direct-assign-rejected-state-and-version-unchanged|' || r];

        BEGIN UPDATE assets.assets SET asset_name = 'renamed' WHERE id = v_a; GET DIAGNOSTICS v_n = ROW_COUNT; r := CASE WHEN v_n = 1 THEN 'PASS' ELSE 'FAIL: rows=' || v_n END;
        EXCEPTION WHEN OTHERS THEN r := 'FAIL: metadata edit broke: ' || SQLERRM; END;
        v_res := v_res || ARRAY['4d-metadata-edit-still-works|' || r];

        BEGIN UPDATE assets.assets SET current_status = 'IN_REPAIR' WHERE id = v_a; GET DIAGNOSTICS v_n = ROW_COUNT; r := CASE WHEN v_n = 1 THEN 'PASS' ELSE 'FAIL: rows=' || v_n END;
        EXCEPTION WHEN OTHERS THEN r := 'FAIL: non-lifecycle status edit broke: ' || SQLERRM; END;
        v_res := v_res || ARRAY['4e-non-lifecycle-status-edit-unaffected|' || r];

        BEGIN DELETE FROM assets.assets WHERE id = v_a; r := 'FAIL: hard DELETE accepted';
        EXCEPTION WHEN insufficient_privilege THEN r := 'PASS'; WHEN OTHERS THEN r := 'FAIL: unexpected ' || SQLSTATE; END;
        v_res := v_res || ARRAY['4f-asset-hard-delete-denied|' || r];
        RESET ROLE;
        RAISE EXCEPTION 'P06_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'P06_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['4-assets-block|FAIL: ' || SQLERRM]; END IF;
    END;
    RESET ROLE;

    ------------------------------------------------------------------ 5. sanction binding (owner session)
    BEGIN  -- asset-bound
        INSERT INTO assets.assets (asset_category_id, asset_code, asset_name) VALUES (v_cat, 'P06S1-' || substr(gen_random_uuid()::text,1,8), 'a') RETURNING id INTO v_a;
        INSERT INTO assets.assets (asset_category_id, asset_code, asset_name) VALUES (v_cat, 'P06S2-' || substr(gen_random_uuid()::text,1,8), 'b') RETURNING id INTO v_b;
        INSERT INTO assets._sanctioned_transitions (asset_id, to_status) VALUES (v_a, 'ASSIGNED');
        BEGIN UPDATE assets.assets SET current_status = 'ASSIGNED' WHERE id = v_b; r := 'FAIL: another asset used the sanction';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'ASSETS_STATUS_CHANGE_NOT_SANCTIONED%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['5a-sanction-bound-to-asset-id|' || r];
        RAISE EXCEPTION 'P06_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'P06_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['5a-block|FAIL: ' || SQLERRM]; END IF; END;

    BEGIN  -- target-bound
        INSERT INTO assets.assets (asset_category_id, asset_code, asset_name) VALUES (v_cat, 'P06S3-' || substr(gen_random_uuid()::text,1,8), 'a') RETURNING id INTO v_a;
        INSERT INTO assets._sanctioned_transitions (asset_id, to_status) VALUES (v_a, 'ASSIGNED');
        UPDATE assets.assets SET current_status = 'ASSIGNED' WHERE id = v_a;
        BEGIN UPDATE assets.assets SET current_status = 'AVAILABLE' WHERE id = v_a; r := 'FAIL: an ASSIGNED sanction authorised leaving ASSIGNED';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'ASSETS_STATUS_CHANGE_NOT_SANCTIONED%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['5b-sanction-bound-to-target-status|' || r];
        RAISE EXCEPTION 'P06_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'P06_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['5b-block|FAIL: ' || SQLERRM]; END IF; END;

    BEGIN  -- transaction-bound
        INSERT INTO assets.assets (asset_category_id, asset_code, asset_name) VALUES (v_cat, 'P06S4-' || substr(gen_random_uuid()::text,1,8), 'a') RETURNING id INTO v_a;
        INSERT INTO assets._sanctioned_transitions (asset_id, to_status, txid) VALUES (v_a, 'ASSIGNED', txid_current() - 1);
        BEGIN UPDATE assets.assets SET current_status = 'ASSIGNED' WHERE id = v_a; r := 'FAIL: an old-transaction sanction was honoured';
        EXCEPTION WHEN OTHERS THEN r := CASE WHEN SQLERRM LIKE 'ASSETS_STATUS_CHANGE_NOT_SANCTIONED%' THEN 'PASS' ELSE 'FAIL: ' || SQLERRM END; END;
        v_res := v_res || ARRAY['5c-sanction-bound-to-transaction|' || r];
        RAISE EXCEPTION 'P06_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'P06_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['5c-block|FAIL: ' || SQLERRM]; END IF; END;

    BEGIN  -- ledger immutability
        INSERT INTO assets.assets (asset_category_id, asset_code, asset_name) VALUES (v_cat, 'P06S5-' || substr(gen_random_uuid()::text,1,8), 'a') RETURNING id INTO v_a;
        INSERT INTO assets._sanctioned_transitions (asset_id, to_status) VALUES (v_a, 'ASSIGNED');
        r := 'PASS';
        BEGIN UPDATE assets._sanctioned_transitions SET to_status = 'AVAILABLE' WHERE asset_id = v_a; r := 'FAIL: ledger UPDATE accepted';
        EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'ASSETS_APPEND_ONLY%' THEN r := 'FAIL: ' || SQLERRM; END IF; END;
        BEGIN DELETE FROM assets._sanctioned_transitions WHERE asset_id = v_a; r := 'FAIL: ledger DELETE accepted';
        EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'ASSETS_APPEND_ONLY%' THEN r := 'FAIL: ' || SQLERRM; END IF; END;
        v_res := v_res || ARRAY['5d-ledger-append-only|' || r];
        RAISE EXCEPTION 'P06_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'P06_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['5d-block|FAIL: ' || SQLERRM]; END IF; END;

    ------------------------------------------------------------------ 6. sanctioned flow still works; version bumps once per real change
    BEGIN
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_am, 'role','authenticated')::text, true);
        PERFORM set_config('request.jwt.claim.sub', v_am::text, true);
        INSERT INTO assets.assets (asset_category_id, asset_code, asset_name) VALUES (v_cat, 'P06F-' || substr(gen_random_uuid()::text,1,8), 'flow fixture') RETURNING id, version INTO v_a, v_ver0;
        INSERT INTO assets.asset_requests (employee_id, asset_category_id, justification, request_status) VALUES (v_emp, v_cat, 'P06 flow', 'APPROVED') RETURNING id INTO v_req;

        SET LOCAL ROLE authenticated;
        PERFORM assets.fulfill_asset_request(v_req, v_a);
        RESET ROLE;
        SELECT current_status::text, version INTO v_state, v_ver FROM assets.assets WHERE id = v_a;
        SELECT id INTO v_asg FROM assets.asset_assignments WHERE asset_id = v_a AND returned_at IS NULL;
        v_res := v_res || ARRAY['6a-fulfill-assigns-and-bumps-version-once|' ||
            CASE WHEN v_state = 'ASSIGNED' AND v_ver = v_ver0 + 1 AND v_asg IS NOT NULL THEN 'PASS' ELSE 'FAIL: status=' || v_state || ' version=' || v_ver || ' (expected ' || (v_ver0+1) || ') assignment=' || coalesce(v_asg::text,'none') END];

        SET LOCAL ROLE authenticated;
        PERFORM assets.return_asset(v_asg);
        RESET ROLE;
        SELECT current_status::text, version INTO v_state, v_ver FROM assets.assets WHERE id = v_a;
        v_res := v_res || ARRAY['6b-return-releases-and-bumps-version-once|' ||
            CASE WHEN v_state = 'AVAILABLE' AND v_ver = v_ver0 + 2 THEN 'PASS' ELSE 'FAIL: status=' || v_state || ' version=' || v_ver || ' (expected ' || (v_ver0+2) || ')' END];

        SET LOCAL ROLE authenticated;
        BEGIN PERFORM assets.return_asset(v_asg); EXCEPTION WHEN OTHERS THEN NULL; END;   -- replay: no-op or rejection, never a second change
        RESET ROLE;
        SELECT current_status::text, version INTO v_state, v_ver FROM assets.assets WHERE id = v_a;
        v_res := v_res || ARRAY['6c-replayed-return-changes-nothing|' ||
            CASE WHEN v_state = 'AVAILABLE' AND v_ver = v_ver0 + 2 THEN 'PASS' ELSE 'FAIL: status=' || v_state || ' version=' || v_ver END];

        SET LOCAL ROLE authenticated;
        BEGIN PERFORM assets.fulfill_asset_request(v_req, v_a); r := 'FAIL: second fulfil of a fulfilled request accepted';
        EXCEPTION WHEN OTHERS THEN r := 'PASS'; END;
        RESET ROLE;
        SELECT current_status::text, version INTO v_state, v_ver FROM assets.assets WHERE id = v_a;
        IF r = 'PASS' AND (v_state <> 'AVAILABLE' OR v_ver <> v_ver0 + 2) THEN r := 'FAIL: rejected fulfil changed state/version'; END IF;
        v_res := v_res || ARRAY['6d-rejected-fulfil-changes-nothing|' || r];

        SELECT count(*) INTO v_ledger FROM assets._sanctioned_transitions WHERE asset_id = v_a;
        v_res := v_res || ARRAY['6e-exactly-two-sanctions-recorded-for-the-flow|' || CASE WHEN v_ledger = 2 THEN 'PASS' ELSE 'FAIL: ' || v_ledger END];
        RAISE EXCEPTION 'P06_TEST_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'P06_TEST_ROLLBACK' THEN v_res := v_res || ARRAY['6-flow-block|FAIL: ' || SQLERRM]; END IF;
    END;
    RESET ROLE;

    INSERT INTO "_p06_results" SELECT split_part(x,'|',1), substr(x, strpos(x,'|') + 1) FROM unnest(v_res) AS x;
END;
$$;

DO $$
DECLARE v_fail int; v_total int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE result <> 'PASS'), count(*),
           string_agg(step || ' = ' || result, ' | ' ORDER BY step) FILTER (WHERE result <> 'PASS')
      INTO v_fail, v_total, v_list FROM "_p06_results";
    IF v_total = 0 THEN RAISE EXCEPTION 'P06 TEST: no results recorded'; END IF;
    IF v_fail > 0 THEN RAISE EXCEPTION 'P06 TEST FAILED (% of % checks): %', v_fail, v_total, v_list; END IF;
    RAISE NOTICE 'P06 TEST PASSED: % checks, 0 failures', v_total;
END;
$$;

SELECT step, result FROM "_p06_results" ORDER BY step;
-- ========================================================================
-- END TEST_P06_contracts_rpc_only_and_asset_status_guard.sql
-- ========================================================================
