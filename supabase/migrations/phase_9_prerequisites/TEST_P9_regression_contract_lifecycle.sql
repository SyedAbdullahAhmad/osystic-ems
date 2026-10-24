-- P06 NOTE: after P06 the direct UPDATE in step C is refused earlier, by privilege (42501), instead of
-- by the P03 guard. Either outcome passes; the contract must stay ACTIVE. Runs before and after P06.
-- ========================================================================
-- TEST_P9_regression_contract_lifecycle.sql
-- Regression: the new TERMINATED guard must not disturb the real contract
-- approval workflow. Runs a contract through the REAL path with the right
-- accounts:  hr.create_contract -> workflow approval by a DIFFERENT user ->
-- workflow trigger sets ACTIVE -> direct TERMINATED attempt (must fail) ->
-- sanctioned hr.terminate_contract (must succeed).
--
-- Why a temporary role: the approver set is fixed when the workflow request is
-- created (accepted shared-engine limitation), so a second CONTRACT_MANAGE
-- holder must exist BEFORE the contract is created. A temporary role grants
-- CONTRACT_MANAGE to fixture user a6 for this test and is removed by captured
-- id at the end.
--
-- Permanent leftovers (clearly tagged P9-REG-<run>): the contract row and its
-- immutable workflow history. One paste; zero-failure gate at the end; any
-- raise rolls the whole script back.
-- ========================================================================
DROP TABLE IF EXISTS "_p9c_results";
CREATE TEMP TABLE "_p9c_results" ("step" text, "result" text);
GRANT ALL ON "_p9c_results" TO "authenticated";
DROP TABLE IF EXISTS "_p9c_ids";
CREATE TEMP TABLE "_p9c_ids" ("key" text PRIMARY KEY, "value" text);
GRANT ALL ON "_p9c_ids" TO "authenticated";

-- SETUP (privileged): temporary CONTRACT_MANAGE role for the approver ----------
DO $$
DECLARE
    v_admin uuid := '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2';
    v_approver uuid := '00000000-0000-0000-0000-0000000000a6';
    v_run text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    v_perm uuid; v_role uuid; v_rp uuid; v_ur uuid;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    IF NOT core.has_permission(v_admin, 'CONTRACT_MANAGE') THEN RAISE EXCEPTION 'SETUP: LOCAL_TEST_ADMIN lacks CONTRACT_MANAGE'; END IF;
    IF core.has_permission(v_approver, 'CONTRACT_MANAGE') THEN RAISE EXCEPTION 'SETUP: a6 already holds CONTRACT_MANAGE - expected a clean approver fixture'; END IF;
    IF EXISTS (SELECT 1 FROM core.roles WHERE name = 'TEMP_TEST_P9_CONTRACT_APPROVER') THEN RAISE EXCEPTION 'SETUP: leftover TEMP_TEST_P9_CONTRACT_APPROVER role - investigate manually'; END IF;

    SELECT id INTO v_perm FROM core.permissions WHERE code = 'CONTRACT_MANAGE';
    INSERT INTO core.roles (name, display_name, description)
    VALUES ('TEMP_TEST_P9_CONTRACT_APPROVER', 'TEMP P9 contract approver', 'TEMPORARY - removed by the same script') RETURNING id INTO v_role;
    INSERT INTO core.role_permissions (role_id, permission_id) VALUES (v_role, v_perm) RETURNING id INTO v_rp;
    INSERT INTO core.user_roles (user_id, role_id) VALUES (v_approver, v_role) RETURNING id INTO v_ur;

    INSERT INTO "_p9c_ids" VALUES ('run', v_run), ('role', v_role::text), ('rp', v_rp::text), ('ur', v_ur::text),
        ('real_before', (SELECT string_agg(c.id::text || ':' || c.status::text, ',' ORDER BY c.id) FROM hr.contracts c WHERE c.contract_number NOT LIKE 'P9-REG-%'));
    INSERT INTO "_p9c_results" VALUES ('0-setup', 'temporary CONTRACT_MANAGE role granted to the approver fixture (run ' || v_run || ')');
END;
$$;

-- STEP A: create the contract as LOCAL_TEST_ADMIN (real RPC) ---------------------
SET ROLE "authenticated";
DO $$
DECLARE
    v_run text := (SELECT "value" FROM "_p9c_ids" WHERE "key" = 'run');
    v_number text; v_contract uuid; v_request uuid; v_status text; v_assignees int; v_approver_listed boolean;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    v_number := 'P9-REG-' || v_run;

    PERFORM hr.create_contract(
        'ed761a27-783e-43d2-8fcd-ac2f64b29249'::uuid, 'PERMANENT'::hr.contract_type, CURRENT_DATE, NULL::date,
        NULL::uuid, 'Phase 9 regression contract', v_number::varchar, ('p9-reg-' || v_run)::varchar);

    SELECT c.id, c.status::text INTO v_contract, v_status FROM hr.contracts c WHERE c.contract_number = v_number;
    IF v_contract IS NULL THEN RAISE EXCEPTION 'STEP A: create_contract did not create a contract numbered %', v_number; END IF;
    SELECT cr.workflow_request_id INTO v_request FROM hr.contract_requests cr WHERE cr.contract_id = v_contract;
    IF v_request IS NULL THEN RAISE EXCEPTION 'STEP A: no workflow request is linked to the new contract'; END IF;

    SELECT count(*), bool_or(a.assignee_user_id = '00000000-0000-0000-0000-0000000000a6')
    INTO v_assignees, v_approver_listed
    FROM workflow.approval_step_assignees a JOIN workflow.approval_steps s ON s.id = a.approval_step_id
    WHERE s.approval_request_id = v_request;

    INSERT INTO "_p9c_ids" VALUES ('contract', v_contract::text), ('request', v_request::text);
    INSERT INTO "_p9c_results" VALUES ('1-create-contract',
        CASE WHEN v_status = 'PENDING_APPROVAL' AND v_approver_listed
             THEN 'PASS: create_contract made contract ' || v_number || ' in PENDING_APPROVAL with a workflow request; the approver fixture is a named assignee'
             ELSE 'FAIL: status=' || coalesce(v_status, 'NULL') || ', approver listed=' || coalesce(v_approver_listed::text, 'NULL') || ' (assignees=' || coalesce(v_assignees::text, '0') || ')' END);
END;
$$;
RESET ROLE;

-- STEP B: approve as the DIFFERENT user (real workflow action) -------------------------
SET ROLE "authenticated";
DO $$
DECLARE
    v_contract uuid := (SELECT "value"::uuid FROM "_p9c_ids" WHERE "key" = 'contract');
    v_request uuid := (SELECT "value"::uuid FROM "_p9c_ids" WHERE "key" = 'request');
    v_step uuid; v_version int; v_status text;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','00000000-0000-0000-0000-0000000000a6','role','authenticated')::text, true);
    SELECT s.id INTO v_step FROM workflow.approval_steps s
    WHERE s.approval_request_id = v_request AND s.status IN ('PENDING', 'IN_PROGRESS') ORDER BY s.step_no LIMIT 1;
    SELECT version INTO v_version FROM workflow.approval_requests WHERE id = v_request;

    PERFORM workflow.process_approval_action(v_request, 'APPROVE', v_step, 'approved (P9 regression)', NULL, 'p9-reg-approve-' || v_request::text, v_version);

    SELECT status::text INTO v_status FROM hr.contracts WHERE id = v_contract;
    INSERT INTO "_p9c_results" VALUES ('2-approval-makes-contract-active',
        CASE WHEN v_status = 'ACTIVE' THEN 'PASS: the workflow trigger moved PENDING_APPROVAL -> ACTIVE; the TERMINATED guard did not interfere with the approval workflow'
             ELSE 'FAIL: contract status after approval is ' || coalesce(v_status, 'NULL') END);
END;
$$;
RESET ROLE;

-- STEP C: direct TERMINATED attempt on the now-ACTIVE real contract (must fail) -----------
SET ROLE "authenticated";
DO $$
DECLARE v_contract uuid := (SELECT "value"::uuid FROM "_p9c_ids" WHERE "key" = 'contract'); v_status text;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    BEGIN
        UPDATE hr.contracts SET status = 'TERMINATED' WHERE id = v_contract;
        INSERT INTO "_p9c_results" VALUES ('3-direct-termination-of-real-contract', 'FAIL: the direct UPDATE succeeded');
    EXCEPTION WHEN OTHERS THEN
        SELECT status::text INTO v_status FROM hr.contracts WHERE id = v_contract;
        INSERT INTO "_p9c_results" VALUES ('3-direct-termination-of-real-contract',
            CASE WHEN (SQLSTATE = '42501' OR SQLERRM LIKE 'HR_CONTRACT_TERMINATION_NOT_SANCTIONED%') AND v_status = 'ACTIVE'
                 THEN 'PASS: a CONTRACT_MANAGE holder cannot terminate the approved contract directly (rejected by ' || CASE WHEN SQLSTATE = '42501' THEN 'privilege, P06' ELSE 'the P03 guard, pre-P06' END || '); it stays ACTIVE'
                 ELSE 'FAIL: ' || SQLSTATE || ' ' || SQLERRM END);
    END;
END;
$$;
RESET ROLE;

-- STEP D: sanctioned termination (owner session standing in for complete_offboarding) ------
DO $$
DECLARE
    v_contract uuid := (SELECT "value"::uuid FROM "_p9c_ids" WHERE "key" = 'contract');
    v_r jsonb; v_status text; v_version int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    v_r := hr.terminate_contract(v_contract, CURRENT_DATE);
    SELECT status::text, version INTO v_status, v_version FROM hr.contracts WHERE id = v_contract;
    INSERT INTO "_p9c_results" VALUES ('4-sanctioned-termination-of-real-contract',
        CASE WHEN v_status = 'TERMINATED' AND (v_r->>'idempotent_replay')::boolean = false
             THEN 'PASS: the sanctioned function terminated the approved contract (version now ' || v_version::text || ')'
             ELSE 'FAIL: ' || v_r::text END);
END;
$$;

-- REVOKE the temporary role by captured id and check the rest is untouched ------------------
DO $$
DECLARE
    v_role uuid := (SELECT "value"::uuid FROM "_p9c_ids" WHERE "key" = 'role');
    v_rp uuid := (SELECT "value"::uuid FROM "_p9c_ids" WHERE "key" = 'rp');
    v_ur uuid := (SELECT "value"::uuid FROM "_p9c_ids" WHERE "key" = 'ur');
    v_left int; v_real_after text;
BEGIN
    DELETE FROM core.user_roles WHERE id = v_ur;
    DELETE FROM core.role_permissions WHERE id = v_rp;
    DELETE FROM core.roles WHERE id = v_role;
    SELECT (SELECT count(*) FROM core.roles WHERE name = 'TEMP_TEST_P9_CONTRACT_APPROVER')
         + (SELECT count(*) FROM core.role_permissions WHERE id = v_rp) + (SELECT count(*) FROM core.user_roles WHERE id = v_ur) INTO v_left;
    INSERT INTO "_p9c_results" VALUES ('5-temp-role-removed', CASE WHEN v_left = 0 THEN 'PASS: temporary role, grant and assignment removed by captured id' ELSE 'FAIL: ' || v_left::text || ' leftover row(s)' END);
    INSERT INTO "_p9c_results" VALUES ('5b-approver-fixture-clean-again',
        CASE WHEN NOT core.has_permission('00000000-0000-0000-0000-0000000000a6', 'CONTRACT_MANAGE') THEN 'PASS: the approver fixture no longer holds CONTRACT_MANAGE' ELSE 'FAIL: still holds CONTRACT_MANAGE' END);

    SELECT string_agg(c.id::text || ':' || c.status::text, ',' ORDER BY c.id) INTO v_real_after FROM hr.contracts c WHERE c.contract_number NOT LIKE 'P9-REG-%';
    INSERT INTO "_p9c_results" VALUES ('6-existing-contracts-untouched',
        CASE WHEN v_real_after IS NOT DISTINCT FROM (SELECT "value" FROM "_p9c_ids" WHERE "key" = 'real_before')
             THEN 'PASS: all pre-existing contracts keep their status' ELSE 'FAIL: a pre-existing contract changed' END);
END;
$$;

DO $$
DECLARE v_fail int; v_pass int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE "result" LIKE 'FAIL%'), count(*) FILTER (WHERE "result" LIKE 'PASS%'),
           string_agg("step" || ' => ' || "result", E'\n') FILTER (WHERE "result" LIKE 'FAIL%')
    INTO v_fail, v_pass, v_list FROM "_p9c_results";
    IF v_fail > 0 THEN RAISE EXCEPTION 'P9_CONTRACT_REGRESSION_FAILED: % FAIL, % PASS:%', v_fail, v_pass, E'\n' || v_list; END IF;
    INSERT INTO "_p9c_results" VALUES ('99-summary', 'ALL PASS: FAIL count = 0, PASS count = ' || v_pass::text);
END;
$$;
SELECT * FROM "_p9c_results" ORDER BY "step";
