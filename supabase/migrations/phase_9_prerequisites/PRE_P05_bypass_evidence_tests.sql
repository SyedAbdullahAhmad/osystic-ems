-- ========================================================================
-- PRE_P05_bypass_evidence_tests.sql  - evidence of the VULNERABLE state, before P05.
-- Run each BLOCK separately (select it, then Run). Each ends with a deliberate
-- error that ROLLS BACK everything; copy the whole error line as the evidence.
-- Reading results:
--   "INSERT SUCCEEDED"      = application-accessible bypass
--   42501 / "FAILED 42501"  = denied by privilege/RLS
--   23503 (foreign key)     = policy+grant ALLOWED the row; only a missing FK row stopped it
-- ========================================================================

-- ============ BLOCK 1: direct INSERT on the three request tables ============
DO $$
DECLARE
  v_uid uuid; v_type uuid; v_day uuid; v_cat uuid;
  v_out text := ''; v_id uuid; v_st text;
BEGIN
  SELECT id INTO v_uid  FROM auth.users ORDER BY created_at LIMIT 1;
  SELECT id INTO v_type FROM leave.leave_types LIMIT 1;
  SELECT id INTO v_day  FROM attendance.attendance_days LIMIT 1;
  SELECT id INTO v_cat  FROM assets.asset_categories LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'SETUP: no auth user'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);
  SET LOCAL ROLE authenticated;

  BEGIN
    INSERT INTO leave.leave_requests (employee_id, leave_type_id, start_date, end_date, total_days, request_status, submitted_at)
    VALUES (v_uid, coalesce(v_type, gen_random_uuid()), current_date, current_date, 1, 'APPROVED', now())
    RETURNING id, request_status::text INTO v_id, v_st;
    v_out := v_out || E'\nLEAVE: INSERT SUCCEEDED id=' || v_id || ' status=' || v_st;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nLEAVE: INSERT FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  BEGIN
    INSERT INTO attendance.correction_requests (attendance_day_id, employee_id, requested_check_in, reason, request_status)
    VALUES (coalesce(v_day, gen_random_uuid()), v_uid, now(), 'pre-P05 evidence', 'APPROVED')
    RETURNING id, request_status::text INTO v_id, v_st;
    v_out := v_out || E'\nATTENDANCE: INSERT SUCCEEDED id=' || v_id || ' status=' || v_st;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nATTENDANCE: INSERT FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  BEGIN
    INSERT INTO assets.asset_requests (employee_id, asset_category_id, justification, request_status)
    VALUES (v_uid, coalesce(v_cat, gen_random_uuid()), 'pre-P05 evidence', 'FULFILLED')
    RETURNING id, request_status::text INTO v_id, v_st;
    v_out := v_out || E'\nASSETS: INSERT SUCCEEDED id=' || v_id || ' status=' || v_st;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nASSETS: INSERT FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  RESET ROLE;
  RAISE EXCEPTION E'BLOCK 1 RESULTS (rolled back; fixtures used: day=%, category=%, leave_type=%)%', v_day, v_cat, v_type, v_out;
END $$;

-- ============ BLOCK 2: CONTRACT_MANAGE / ASSET_MANAGE direct state changes ============
DO $$
DECLARE
  v_cm uuid; v_am uuid; v_cat uuid;
  v_out text := ''; v_cid uuid; v_aid uuid; v_n int; v_st text; v_cnt int;
BEGIN
  SELECT id INTO v_cm FROM auth.users WHERE core.has_permission(id, 'CONTRACT_MANAGE') ORDER BY created_at LIMIT 1;
  SELECT id INTO v_am FROM auth.users WHERE core.has_permission(id, 'ASSET_MANAGE')    ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cat FROM assets.asset_categories LIMIT 1;
  IF v_cm IS NULL OR v_am IS NULL OR v_cat IS NULL THEN
    RAISE EXCEPTION 'SETUP: need a CONTRACT_MANAGE holder (%), an ASSET_MANAGE holder (%) and an asset category (%)', v_cm, v_am, v_cat;
  END IF;

  ---------------- CONTRACT_MANAGE holder ----------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_cm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_cm::text, true);
  SET LOCAL ROLE authenticated;

  BEGIN
    INSERT INTO hr.contracts (employee_id, contract_number, contract_type)
    VALUES (v_cm, 'P05EVID-' || substr(gen_random_uuid()::text, 1, 8), 'PERMANENT') RETURNING id INTO v_cid;
    v_out := v_out || E'\nC0 direct INSERT of a DRAFT contract: SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nC0 direct INSERT of a DRAFT contract: FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  IF v_cid IS NOT NULL THEN
    BEGIN
      UPDATE hr.contracts SET status = 'ACTIVE' WHERE id = v_cid;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      SELECT status::text INTO v_st FROM hr.contracts WHERE id = v_cid;
      v_out := v_out || E'\nC1 direct UPDATE DRAFT -> ACTIVE (skipping workflow): rows=' || v_n || ' status_now=' || coalesce(v_st, 'n/a');
    EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nC1 UPDATE to ACTIVE: FAILED ' || SQLSTATE || ' ' || SQLERRM;
    END;
    BEGIN
      UPDATE hr.contracts SET status = 'TERMINATED' WHERE id = v_cid;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_out := v_out || E'\nC2 direct UPDATE -> TERMINATED: rows=' || v_n || ' (P03 guard expected to block)';
    EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nC2 UPDATE to TERMINATED: FAILED ' || SQLSTATE || ' ' || SQLERRM;
    END;
    BEGIN
      DELETE FROM hr.contracts WHERE id = v_cid;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_out := v_out || E'\nC4 direct DELETE of the contract: rows=' || v_n;
    EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nC4 DELETE: FAILED ' || SQLSTATE || ' ' || SQLERRM;
    END;
  END IF;

  BEGIN
    INSERT INTO hr.contracts (employee_id, contract_number, contract_type, status)
    VALUES (v_cm, 'P05EVID-' || substr(gen_random_uuid()::text, 1, 8), 'PERMANENT', 'ACTIVE');
    v_out := v_out || E'\nC3 direct INSERT of an ACTIVE contract (no workflow): SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nC3 INSERT ACTIVE contract: FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  ---------------- ASSET_MANAGE holder ----------------
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_am, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_am::text, true);
  SET LOCAL ROLE authenticated;

  BEGIN
    INSERT INTO assets.assets (asset_category_id, asset_code, asset_name)
    VALUES (v_cat, 'P05EVID-' || substr(gen_random_uuid()::text, 1, 8), 'p05 evidence asset') RETURNING id INTO v_aid;
    v_out := v_out || E'\nA0 direct INSERT of an AVAILABLE asset (inventory registration): SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nA0 INSERT asset: FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  IF v_aid IS NOT NULL THEN
    BEGIN
      UPDATE assets.assets SET current_status = 'ASSIGNED' WHERE id = v_aid;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      SELECT current_status::text INTO v_st FROM assets.assets WHERE id = v_aid;
      v_out := v_out || E'\nA1 direct UPDATE assets.current_status -> ASSIGNED (no assignment row): rows=' || v_n || ' status_now=' || coalesce(v_st, 'n/a');
    EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nA1 UPDATE to ASSIGNED: FAILED ' || SQLSTATE || ' ' || SQLERRM;
    END;
  END IF;

  BEGIN
    INSERT INTO assets.asset_assignments (asset_request_id, asset_id, employee_id, assigned_by)
    VALUES (gen_random_uuid(), coalesce(v_aid, gen_random_uuid()), v_am, v_am);
    v_out := v_out || E'\nA3 direct INSERT into asset_assignments: SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nA3 INSERT asset_assignments: FAILED ' || SQLSTATE || ' (42501 = denied; 23503 = RLS allowed)';
  END;

  BEGIN
    SELECT count(*) INTO v_cnt FROM assets.asset_requests WHERE request_status = 'SUBMITTED';
    UPDATE assets.asset_requests SET request_status = 'FULFILLED' WHERE request_status = 'SUBMITTED';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || E'\nA4 direct UPDATE asset_requests -> FULFILLED: rows=' || v_n || ' of ' || v_cnt || ' visible SUBMITTED (0 of >0 = blocked; 0 of 0 = untested)';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nA4 UPDATE asset_requests: FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  BEGIN
    SELECT count(*) INTO v_cnt FROM assets.asset_assignments WHERE returned_at IS NULL;
    UPDATE assets.asset_assignments SET returned_at = now() WHERE returned_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || E'\nA5 direct UPDATE asset_assignments.returned_at: rows=' || v_n || ' of ' || v_cnt || ' open assignments (0 of >0 = blocked; 0 of 0 = untested)';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\nA5 UPDATE asset_assignments: FAILED ' || SQLSTATE || ' ' || SQLERRM;
  END;

  RESET ROLE;
  RAISE EXCEPTION E'BLOCK 2 RESULTS (rolled back; contract_manager=%, asset_manager=%)%', v_cm, v_am, v_out;
END $$;

-- ============ BLOCK 3 (read-only): live baseline P05 will assert ============
SELECT schemaname, tablename, policyname, cmd, permissive, roles, qual, with_check
FROM pg_policies
WHERE (schemaname, tablename) IN (('leave','leave_requests'),('attendance','correction_requests'),('assets','asset_requests'))
  AND cmd IN ('INSERT','ALL')
ORDER BY 1,2;
