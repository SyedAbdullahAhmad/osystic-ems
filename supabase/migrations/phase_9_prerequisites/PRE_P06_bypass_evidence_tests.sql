-- ========================================================================
-- PRE_P06_bypass_evidence_tests.sql - remaining baseline evidence BEFORE P06.
-- Run once, after P05 has been applied and its regression is green (P05 does not
-- touch hr.contract_versions or assets.assets, so results are the same before or
-- after P05; run it before P06 changes anything).
-- Ends with a deliberate error that rolls everything back; copy the whole text.
-- Covers lead's list:
--   hr.contract_versions: direct INSERT / UPDATE / DELETE (CONTRACT_MANAGE holder)
--   assets.assets: direct DELETE; direct INSERT claiming a lifecycle status (ASSIGNED)
-- ========================================================================
DO $$
DECLARE
  v_cm uuid; v_am uuid; v_cat uuid; v_cid uuid; v_aid uuid; v_vid uuid;
  v_out text := ''; v_n int; v_st text;
BEGIN
  SELECT id INTO v_cm FROM auth.users WHERE core.has_permission(id, 'CONTRACT_MANAGE') ORDER BY created_at LIMIT 1;
  SELECT id INTO v_am FROM auth.users WHERE core.has_permission(id, 'ASSET_MANAGE')    ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cat FROM assets.asset_categories LIMIT 1;
  IF v_cm IS NULL OR v_am IS NULL OR v_cat IS NULL THEN
    RAISE EXCEPTION 'SETUP: contract_manager=%, asset_manager=%, category=%', v_cm, v_am, v_cat;
  END IF;

  ---------------- CONTRACT_MANAGE holder: hr.contract_versions ----------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_cm::text, true);
  SET LOCAL ROLE authenticated;

  BEGIN
    INSERT INTO hr.contracts (employee_id, contract_number, contract_type)
    VALUES (v_cm, 'P06EVID-' || substr(gen_random_uuid()::text, 1, 8), 'PERMANENT') RETURNING id INTO v_cid;
    v_out := v_out || E'\nV0 fixture: direct INSERT of a DRAFT contract: SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nV0 fixture contract INSERT: FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  IF v_cid IS NOT NULL THEN
    BEGIN
      INSERT INTO hr.contract_versions (contract_id, version_no, effective_from, notes)
      VALUES (v_cid, 1, current_date, 'P06 evidence') RETURNING id INTO v_vid;
      v_out := v_out || E'\nV1 direct INSERT into hr.contract_versions: SUCCEEDED';
    EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nV1 INSERT contract_versions: FAILED ' || SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_vid IS NOT NULL THEN
      BEGIN
        UPDATE hr.contract_versions SET notes = 'edited directly' WHERE id = v_vid;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_out := v_out || E'\nV2 direct UPDATE hr.contract_versions: rows=' || v_n;
      EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nV2 UPDATE contract_versions: FAILED ' || SQLSTATE || ' ' || SQLERRM;
      END;
      BEGIN
        DELETE FROM hr.contract_versions WHERE id = v_vid;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_out := v_out || E'\nV3 direct DELETE hr.contract_versions: rows=' || v_n;
      EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nV3 DELETE contract_versions: FAILED ' || SQLSTATE || ' ' || SQLERRM;
      END;
    END IF;
  END IF;

  ---------------- ASSET_MANAGE holder: assets.assets ----------------
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_am, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_am::text, true);
  SET LOCAL ROLE authenticated;

  BEGIN
    INSERT INTO assets.assets (asset_category_id, asset_code, asset_name, current_status)
    VALUES (v_cat, 'P06EVID-' || substr(gen_random_uuid()::text, 1, 8), 'p06 evidence asset (claims ASSIGNED)', 'ASSIGNED')
    RETURNING id, current_status::text INTO v_aid, v_st;
    v_out := v_out || E'\nS1 direct INSERT of an asset already ASSIGNED: SUCCEEDED status=' || v_st;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nS1 INSERT asset as ASSIGNED: FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  BEGIN
    IF v_aid IS NULL THEN
      INSERT INTO assets.assets (asset_category_id, asset_code, asset_name)
      VALUES (v_cat, 'P06EVID-' || substr(gen_random_uuid()::text, 1, 8), 'p06 evidence asset') RETURNING id INTO v_aid;
    END IF;
    DELETE FROM assets.assets WHERE id = v_aid;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || E'\nS2 direct hard DELETE of an asset: rows=' || v_n;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nS2 DELETE asset: FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  RESET ROLE;
  RAISE EXCEPTION E'PRE-P06 RESULTS (rolled back; contract_manager=%, asset_manager=%)%', v_cm, v_am, v_out;
END $$;
