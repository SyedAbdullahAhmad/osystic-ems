-- ========================================================================
-- TEST_onboarding_full_flow.sql  (v8 - current through Shawaiz's
-- round-7 decision. Full history of every round is in FIXES_SUMMARY.md.)
--
-- THIS FILE BELONGS TO "TRACK B" ONLY (functional/security proof).
-- Never run it in the Track A (migration-reversibility) environment.
--
-- PRECONDITIONS - read before running:
--   1. LOCAL_TEST_ADMIN (2d48e4e3-fee2-4034-8b8d-a3cce8298ce2) holds
--      ONBOARDING_MANAGE.
--   2. A SECOND real account also holds ONBOARDING_MANAGE (maker-checker).
--   3. A THIRD real auth.users row exists, holding NEITHER
--      ONBOARDING_MANAGE NOR PEOPLE_MANAGE - SECTION 0 verifies this
--      explicitly and refuses to run otherwise.
--   4. The onboarding workflow has been seeded (checklist Step 4) and
--      001-007 are all applied (006 and 007 must be re-applied if a
--      rollback drill already dropped them in this environment).
--   5. Run this whole file as ONE paste, top to bottom, in order.
--   6. IMPORTANT: this script WILL create permanent, undeletable
--      workflow.* rows (approval_actions / status_history are
--      append-only by trigger, and ACTIVE workflow configuration is
--      immutable by the triggers installed in
--      phase_2_workflow_engine/005_workflow_rls_grants.sql). Run it only
--      in a database you will never roll Phase 8 back in.
--
-- WHAT CHANGED IN v8 (round 7): header, SECTION 18, a new fresh-vs-replay
-- regression assertion (3b2) and a final zero-failure gate (99-summary). SECTION 18 now documents the corrected two-track
-- procedure: Track A (reversibility) uses a fresh DB with the seed NEVER
-- invoked; Track B (this file) uses a seeded DB and is never rolled back.
-- ========================================================================

DROP TABLE IF EXISTS "_onboarding_test_results";
CREATE TEMP TABLE "_onboarding_test_results" ("step" text, "result" text);

DROP TABLE IF EXISTS "_onboarding_test_config";
CREATE TEMP TABLE "_onboarding_test_config" ("key" text PRIMARY KEY, "value" text);

DROP TABLE IF EXISTS "_onboarding_test_ids";
CREATE TEMP TABLE "_onboarding_test_ids" ("key" text PRIMARY KEY, "value" text);

-- Item 1 (round 5): these three TEMP tables are created and owned by
-- the privileged session connected to run this script. Once a later
-- section does `SET ROLE "authenticated"`, Postgres checks privileges
-- against THAT role from then on - "authenticated" does not
-- automatically inherit ownership of a temp table some other role
-- created, even in the same session. Without an explicit grant here,
-- the very first SET ROLE "authenticated" block (SECTION 2) would fail
-- on its own SELECT/INSERT against these harness tables, before ever
-- reaching an actual onboarding assertion. These are session-local TEMP
-- tables (gone when this session ends) - granting on them has no
-- effect on anything outside this test run.
GRANT SELECT ON "_onboarding_test_config" TO "authenticated";
GRANT SELECT, INSERT ON "_onboarding_test_ids" TO "authenticated";
GRANT SELECT, INSERT ON "_onboarding_test_results" TO "authenticated";
-- SELECT/INSERT are the only operations any SET ROLE "authenticated"
-- block performs against these three tables - nothing here is ever
-- UPDATEd or DELETEd, only appended to or read.

-- ========================================================================
-- SECTION 0 - fill in the two placeholder ids, then run this whole file.
-- ========================================================================
-- Item 4 (round 4): Section 0 now validates everything the suite
-- critically depends on, not just that candidate_user exists - so a
-- bad fixture fails HERE, loudly and specifically, rather than
-- surfacing later as a confusing maker-checker or approval failure that
-- looks like a module defect.
DO $$
DECLARE
    v_hr_admin uuid;
    v_approver_admin uuid;
    v_candidate_user uuid;
BEGIN
    INSERT INTO "_onboarding_test_config" ("key", "value") VALUES
        ('hr_admin', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2'),
        ('approver_admin', '00000000-0000-0000-0000-000000000000'),  -- <<< REPLACE
        ('candidate_user', '00000000-0000-0000-0000-000000000000');  -- <<< REPLACE

    v_hr_admin := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_approver_admin := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'approver_admin');
    v_candidate_user := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'candidate_user');

    IF v_approver_admin = '00000000-0000-0000-0000-000000000000'::uuid
       OR v_candidate_user = '00000000-0000-0000-0000-000000000000'::uuid THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: replace both placeholder ids in SECTION 0 before running.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "auth"."users" WHERE "id" = v_hr_admin) THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: hr_admin (%) is not a real auth.users row.', v_hr_admin;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM "auth"."users" WHERE "id" = v_approver_admin) THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: approver_admin (%) is not a real auth.users row.', v_approver_admin;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM "auth"."users" WHERE "id" = v_candidate_user) THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: candidate_user (%) is not a real auth.users row.', v_candidate_user;
    END IF;

    IF v_hr_admin = v_approver_admin THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: hr_admin and approver_admin must be two DIFFERENT accounts - maker-checker cannot be exercised with the same user twice.';
    END IF;
    IF v_candidate_user = v_hr_admin OR v_candidate_user = v_approver_admin THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: candidate_user must be distinct from both hr_admin and approver_admin.';
    END IF;

    IF NOT core.has_permission(v_hr_admin, 'ONBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: hr_admin (%) does not hold ONBOARDING_MANAGE - grant it per the checklist Step 3 before running.', v_hr_admin;
    END IF;
    IF NOT core.has_permission(v_approver_admin, 'ONBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: approver_admin (%) does not hold ONBOARDING_MANAGE - grant it per the checklist Step 3 before running.', v_approver_admin;
    END IF;

    -- Item 2 (round 6): candidate_user must be verified as genuinely
    -- NON-privileged, not merely "a different auth.users row." Section
    -- 2's unauthorized-create test depends on it lacking
    -- ONBOARDING_MANAGE specifically. Section 9's core.people/
    -- hr.employees tests depend on something ELSE though - those two
    -- tables are gated by PEOPLE_MANAGE (confirmed directly against
    -- phase_7_shared_core_people_org/002_shared_core_rls_grants.sql's
    -- "people_update"/"employees_insert" policies), not
    -- ONBOARDING_MANAGE - a candidate_user that happened to be some
    -- other EMS admin (e.g. already holding PEOPLE_MANAGE for an
    -- unrelated reason) would make Section 9's negative tests pass for
    -- the WRONG reason (genuinely authorized, not correctly denied) -
    -- a false PASS that item 2 of round 3 was specifically trying to
    -- prevent in general, just missed for this exact permission.
    IF core.has_permission(v_candidate_user, 'ONBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: candidate_user (%) holds ONBOARDING_MANAGE - it must be a genuinely unauthorized account for SECTION 2''s test to mean anything. Pick a real EMS test identity with no admin permissions at all, not just a spare account.', v_candidate_user;
    END IF;
    IF core.has_permission(v_candidate_user, 'PEOPLE_MANAGE') THEN
        RAISE EXCEPTION 'TEST SETUP INCOMPLETE: candidate_user (%) holds PEOPLE_MANAGE - SECTION 9''s core.people/hr.employees tests would pass for the wrong reason (genuinely authorized via a different permission, not correctly denied). Pick an account with neither ONBOARDING_MANAGE nor PEOPLE_MANAGE.', v_candidate_user;
    END IF;

    INSERT INTO "_onboarding_test_results" VALUES ('0-setup', 'config loaded and validated: 3 distinct real accounts, both admins hold ONBOARDING_MANAGE, candidate_user confirmed to hold NEITHER ONBOARDING_MANAGE NOR PEOPLE_MANAGE');
END;
$$;

-- ========================================================================
-- SECTION 1 (NEW, supports item 2) - fixture setup: a dedicated,
-- throwaway core.people row for SECTION 4's bypass-INSERT attempts, so
-- a missing FK can never be the reason those statements fail - only the
-- grant/RLS layer can be. Privileged DB role deliberately (this is test
-- setup, not an assertion) - but core.people has its own BEFORE INSERT
-- trigger (core._force_created_by(), from phase_7) requiring
-- auth.uid() IS NOT NULL, and that trigger fires regardless of which
-- role is connected - being privileged bypasses RLS/grants, it does
-- NOT bypass triggers. So request.jwt.claims is set to a real test
-- user FIRST (item 2, round 4), independently in this block rather
-- than assuming it leaked in from elsewhere.
-- ========================================================================
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_organization_id uuid;
    v_fixture_person_id uuid;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    SELECT "id" INTO v_organization_id FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    INSERT INTO "core"."people" ("organization_id", "full_name", "primary_email", "person_type", "status")
    VALUES (v_organization_id, 'Fixture Person (bypass tests)', 'fixture-bypass-' || extract(epoch from now())::text || '@example.invalid', 'CANDIDATE', 'ACTIVE')
    RETURNING "id" INTO v_fixture_person_id;
    INSERT INTO "_onboarding_test_ids" VALUES ('fixture_person_id', v_fixture_person_id::text);
    INSERT INTO "_onboarding_test_results" VALUES ('1-fixture-setup', 'fixture_person_id=' || v_fixture_person_id::text);
END;
$$;

-- ========================================================================
-- SECTION 2 - unauthorized create (item 3: real account, not a
-- fabricated subject - this account holds no permission yet at this
-- point in the script, since linking happens later in SECTION 16)
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_candidate_user uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'candidate_user');
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_candidate_user::text, 'role', 'authenticated')::text, true);
    BEGIN
        PERFORM "onboarding"."create_and_submit_onboarding_request"(
            'Should Not Be Created', 'should-not-exist@example.invalid', 'test-key-unauthorized-' || v_candidate_user::text
        );
        INSERT INTO "_onboarding_test_results" VALUES ('2-unauthorized-create', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'ONBOARDING_NOT_AUTHORIZED%' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('2-unauthorized-create', 'PASS: correctly rejected by the authorization check - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('2-unauthorized-create', 'FAIL: rejected, but by the WRONG control - ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 3 - create + submit, as HR, plus idempotency tests
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_key text := 'test-key-main-' || extract(epoch from now())::text;
    v_submit_result jsonb;
    v_replay_result jsonb;
    v_record_id uuid;
    v_person_id uuid;
    v_workflow_request_id uuid;
    v_version_after_create int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    v_submit_result := "onboarding"."create_and_submit_onboarding_request"(
        'Test Candidate Main', 'test-candidate-main-' || extract(epoch from now())::text || '@example.invalid',
        v_key, 'QA Engineer', NULL, CURRENT_DATE + 14
    );
    INSERT INTO "_onboarding_test_results" VALUES ('3a-create', v_submit_result::text);
    -- Item 5 response-contract check: onboarding_status/workflow_status
    -- present and distinct, no overloaded 'status' key.
    INSERT INTO "_onboarding_test_results" VALUES (
        '3a2-response-contract',
        CASE WHEN v_submit_result ? 'onboarding_status' AND v_submit_result ? 'workflow_status' AND NOT (v_submit_result ? 'status')
            THEN 'PASS: onboarding_status=' || (v_submit_result->>'onboarding_status') || ' workflow_status=' || (v_submit_result->>'workflow_status')
            ELSE 'FAIL: ' || v_submit_result::text
        END
    );

    v_record_id := (v_submit_result->>'onboarding_record_id')::uuid;
    v_person_id := (v_submit_result->>'person_id')::uuid;
    v_workflow_request_id := (v_submit_result->>'workflow_request_id')::uuid;

    v_replay_result := "onboarding"."create_and_submit_onboarding_request"(
        'Test Candidate Main', 'test-candidate-main-' || extract(epoch from now())::text || '@example.invalid',
        v_key, 'QA Engineer', NULL, CURRENT_DATE + 14
    );
    INSERT INTO "_onboarding_test_results" VALUES (
        '3b-idempotent-replay-same-key',
        CASE WHEN (v_replay_result->>'onboarding_record_id')::uuid = v_record_id AND (v_replay_result->>'idempotent_replay')::boolean = true
            THEN 'PASS: same record, idempotent_replay=true, onboarding_status=' || (v_replay_result->>'onboarding_status') || ' workflow_status=' || (v_replay_result->>'workflow_status')
            ELSE 'FAIL: ' || v_replay_result::text
        END
    );

    -- REGRESSION (round 7, Shawaiz item 1): found by real execution -
    -- the fresh path used to return the engine's start-result label
    -- ('CREATED') while the replay path returned
    -- workflow.approval_requests.current_status ('PENDING'). Both paths
    -- must now agree on every returned field, and the value must be the
    -- real current status.
    INSERT INTO "_onboarding_test_results" VALUES (
        '3b2-fresh-vs-replay-consistency-regression',
        CASE
            WHEN v_submit_result->>'workflow_status' IS DISTINCT FROM 'PENDING'
                THEN 'FAIL: fresh workflow_status is ' || coalesce(v_submit_result->>'workflow_status', 'NULL') || ', expected PENDING'
            WHEN v_replay_result->>'workflow_status' IS DISTINCT FROM v_submit_result->>'workflow_status'
                THEN 'FAIL: fresh workflow_status=' || (v_submit_result->>'workflow_status') || ' but replay workflow_status=' || coalesce(v_replay_result->>'workflow_status', 'NULL')
            WHEN v_replay_result->>'onboarding_record_id' IS DISTINCT FROM v_submit_result->>'onboarding_record_id'
                THEN 'FAIL: fresh and replay onboarding_record_id differ'
            WHEN v_replay_result->>'person_id' IS DISTINCT FROM v_submit_result->>'person_id'
                THEN 'FAIL: fresh and replay person_id differ'
            WHEN v_replay_result->>'workflow_request_id' IS DISTINCT FROM v_submit_result->>'workflow_request_id'
                THEN 'FAIL: fresh and replay workflow_request_id differ'
            WHEN v_replay_result->>'onboarding_status' IS DISTINCT FROM v_submit_result->>'onboarding_status'
                THEN 'FAIL: fresh and replay onboarding_status differ'
            ELSE 'PASS: fresh and replay agree - workflow_status=PENDING on both, same onboarding_record_id / person_id / workflow_request_id / onboarding_status'
        END
    );

    BEGIN
        PERFORM "onboarding"."create_and_submit_onboarding_request"(
            'A Totally Different Candidate', 'totally-different-' || extract(epoch from now())::text || '@example.invalid',
            v_key, 'Different Position', NULL, CURRENT_DATE + 99
        );
        INSERT INTO "_onboarding_test_results" VALUES ('3c-idempotency-mismatch', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'ONBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH%' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('3c-idempotency-mismatch', 'PASS: correctly rejected by the payload-hash check - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('3c-idempotency-mismatch', 'FAIL: rejected, but by the WRONG control - ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    SELECT "version" INTO v_version_after_create FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id;

    INSERT INTO "_onboarding_test_ids" VALUES
        ('main_record_id', v_record_id::text),
        ('main_person_id', v_person_id::text),
        ('main_workflow_request_id', v_workflow_request_id::text),
        ('version_after_create', v_version_after_create::text);
    INSERT INTO "_onboarding_test_results" VALUES ('3d-version-after-create', 'version=' || v_version_after_create::text || ' (INSERT starts at 1, then the workflow_request_id attach UPDATE bumps it once)');
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 4 - RPC-bypass tests (item 1/2, round 3): a genuine
-- ONBOARDING_MANAGE holder attempts to go around the RPC/workflow path
-- via raw table writes. Uses the dedicated fixture person (SECTION 1)
-- so a missing FK on person_id can never be mistaken for the grant
-- denial under test. Every assertion checks SQLSTATE = '42501'
-- (insufficient_privilege) specifically - not just "some exception".
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_fixture_person_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'fixture_person_id');
    v_record_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_record_id');
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    BEGIN
        INSERT INTO "onboarding"."onboarding_records" ("person_id", "status") VALUES (v_fixture_person_id, 'APPROVED');
        INSERT INTO "_onboarding_test_results" VALUES ('4a-bypass-insert-approved', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('4a-bypass-insert-approved', 'PASS: correctly rejected, SQLSTATE 42501 (insufficient_privilege) - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('4a-bypass-insert-approved', 'FAIL: rejected, but NOT by a privilege/RLS denial - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    BEGIN
        INSERT INTO "onboarding"."onboarding_records" ("person_id", "status") VALUES (v_fixture_person_id, 'REJECTED');
        INSERT INTO "_onboarding_test_results" VALUES ('4b-bypass-insert-rejected', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('4b-bypass-insert-rejected', 'PASS: correctly rejected, SQLSTATE 42501 - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('4b-bypass-insert-rejected', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    BEGIN
        INSERT INTO "onboarding"."onboarding_records" ("person_id", "status") VALUES (v_fixture_person_id, 'WITHDRAWN');
        INSERT INTO "_onboarding_test_results" VALUES ('4c-bypass-insert-withdrawn', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('4c-bypass-insert-withdrawn', 'PASS: correctly rejected, SQLSTATE 42501 - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('4c-bypass-insert-withdrawn', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    BEGIN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'APPROVED' WHERE "id" = v_record_id;
        INSERT INTO "_onboarding_test_results" VALUES ('4d-bypass-update-approved', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('4d-bypass-update-approved', 'PASS: correctly rejected, SQLSTATE 42501 - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('4d-bypass-update-approved', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    BEGIN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'REJECTED' WHERE "id" = v_record_id;
        INSERT INTO "_onboarding_test_results" VALUES ('4e-bypass-update-rejected', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('4e-bypass-update-rejected', 'PASS: correctly rejected, SQLSTATE 42501 - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('4e-bypass-update-rejected', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    IF (SELECT "status" FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id) = 'SUBMITTED' THEN
        INSERT INTO "_onboarding_test_results" VALUES ('4f-record-unchanged-after-bypass-attempts', 'PASS: still SUBMITTED');
    ELSE
        INSERT INTO "_onboarding_test_results" VALUES ('4f-record-unchanged-after-bypass-attempts', 'FAIL: status changed');
    END IF;
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 5 - maker-checker is actually enforced
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_workflow_request_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_workflow_request_id');
    v_step_id uuid;
    v_version int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    SELECT s."id" INTO v_step_id FROM "workflow"."approval_steps" s
    WHERE s."approval_request_id" = v_workflow_request_id AND s."status" IN ('PENDING', 'IN_PROGRESS')
    ORDER BY s."step_no" LIMIT 1;
    SELECT "version" INTO v_version FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;

    BEGIN
        PERFORM "workflow"."process_approval_action"(
            v_workflow_request_id, 'APPROVE', v_step_id, 'self-approve attempt (test)', NULL,
            'test-self-approve-' || v_workflow_request_id::text, v_version
        );
        INSERT INTO "_onboarding_test_results" VALUES ('5-maker-checker-self-approve', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'WORKFLOW_MAKER_CHECKER_VIOLATION%' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('5-maker-checker-self-approve', 'PASS: correctly rejected by maker-checker - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('5-maker-checker-self-approve', 'FAIL: rejected, but NOT by maker-checker - ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 6 - approve, as the SECOND admin
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_approver_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'approver_admin');
    v_workflow_request_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_workflow_request_id');
    v_record_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_record_id');
    v_step_id uuid;
    v_version int;
    v_approve_result jsonb;
    v_final_status text;
    v_version_after_approve int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_approver_admin::text, 'role', 'authenticated')::text, true);

    SELECT s."id" INTO v_step_id FROM "workflow"."approval_steps" s
    WHERE s."approval_request_id" = v_workflow_request_id AND s."status" IN ('PENDING', 'IN_PROGRESS')
    ORDER BY s."step_no" LIMIT 1;
    SELECT "version" INTO v_version FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;

    v_approve_result := "workflow"."process_approval_action"(
        v_workflow_request_id, 'APPROVE', v_step_id, 'approved (test, different user)', NULL,
        'test-approve-' || v_record_id::text, v_version
    );
    INSERT INTO "_onboarding_test_results" VALUES ('6a-approve-by-different-user', v_approve_result::text);

    SELECT "status" INTO v_final_status FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id;
    INSERT INTO "_onboarding_test_results" VALUES ('6b-status-after-approve', v_final_status);

    SELECT "version" INTO v_version_after_approve FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id;
    INSERT INTO "_onboarding_test_ids" VALUES ('version_after_approve', v_version_after_approve::text);
    INSERT INTO "_onboarding_test_results" VALUES ('6c-version-after-approve', 'version=' || v_version_after_approve::text);
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 7 - the APPROVED -> HIRED raw-UPDATE attempt. With item 1
-- (round 2)'s fix, this now fails at the SAME grant layer as SECTION
-- 4's tests (no UPDATE privilege exists at all for any status) - kept
-- as its own section for clarity since it's specifically the HIRED
-- case, but the assertion is honestly the same SQLSTATE check, not a
-- different one.
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_record_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_record_id');
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);
    BEGIN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'HIRED' WHERE "id" = v_record_id;
        INSERT INTO "_onboarding_test_results" VALUES ('7-negative-direct-hired-update', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('7-negative-direct-hired-update', 'PASS: correctly rejected, SQLSTATE 42501 - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('7-negative-direct-hired-update', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 8 (NEW, item 2) - the terminal-transition trigger (001),
-- tested DIRECTLY and on its OWN, as a privileged/bypass session
-- (deliberately, not as "authenticated" - we are testing this specific
-- independent layer, not the grant layer SECTION 4 already covers).
-- With item 1 (round 2)'s lockdown, no ordinary-role test can reach
-- this trigger anymore at all - it needs its own direct exercise to be
-- proven, as Arslan's review implies for "terminal-state tests."
-- ========================================================================
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_organization_id uuid;
    v_trigger_test_person_id uuid;
    v_trigger_test_record_id uuid;
BEGIN
    -- Item 2 (round 4): set independently in THIS block - the test must
    -- not depend on claims state possibly leaking in from an earlier
    -- section. Privileged DB role is unaffected by this (no SET ROLE
    -- here) - only auth.uid() resolution changes.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    SELECT "id" INTO v_organization_id FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    INSERT INTO "core"."people" ("organization_id", "full_name", "primary_email", "person_type", "status")
    VALUES (v_organization_id, 'Trigger Test Person', 'trigger-test-' || extract(epoch from now())::text || '@example.invalid', 'CANDIDATE', 'ACTIVE')
    RETURNING "id" INTO v_trigger_test_person_id;

    INSERT INTO "onboarding"."onboarding_records" ("person_id", "status", "created_by")
    VALUES (v_trigger_test_person_id, 'REJECTED', (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin'))
    RETURNING "id" INTO v_trigger_test_record_id;

    BEGIN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'SUBMITTED' WHERE "id" = v_trigger_test_record_id;
        INSERT INTO "_onboarding_test_results" VALUES ('8a-trigger-terminal-status', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'ONBOARDING_TERMINAL_STATUS%' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('8a-trigger-terminal-status', 'PASS: correctly rejected by the terminal-status guard - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('8a-trigger-terminal-status', 'FAIL: rejected, but NOT by the terminal-status guard - ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;

-- A second, non-terminal but structurally illegal jump: DRAFT straight
-- to APPROVED, skipping SUBMITTED. Needs its own fresh DRAFT row (the
-- record above is REJECTED - terminal - so it can't be reset to DRAFT
-- to run this second case from).

DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_organization_id uuid;
    v_draft_person_id uuid;
    v_draft_record_id uuid;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    SELECT "id" INTO v_organization_id FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    INSERT INTO "core"."people" ("organization_id", "full_name", "primary_email", "person_type", "status")
    VALUES (v_organization_id, 'Trigger Test Person 2', 'trigger-test-2-' || extract(epoch from now())::text || '@example.invalid', 'CANDIDATE', 'ACTIVE')
    RETURNING "id" INTO v_draft_person_id;

    INSERT INTO "onboarding"."onboarding_records" ("person_id", "status", "created_by")
    VALUES (v_draft_person_id, 'DRAFT', (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin'))
    RETURNING "id" INTO v_draft_record_id;

    BEGIN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'APPROVED' WHERE "id" = v_draft_record_id;
        INSERT INTO "_onboarding_test_results" VALUES ('8b-trigger-invalid-transition', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'ONBOARDING_INVALID_TRANSITION%' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('8b-trigger-invalid-transition', 'PASS: correctly rejected by the transition guard - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('8b-trigger-invalid-transition', 'FAIL: rejected, but NOT by the transition guard - ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;

-- ========================================================================
-- SECTION 8C (NEW, item 5, round 5) - _enforce_hired_consistency()
-- (006), tested DIRECTLY and on its own, same pattern as SECTION 8's
-- terminal-transition tests. SECTION 7's APPROVED -> HIRED test proves
-- authenticated users can't bypass the RPC - but it fails at the
-- table-GRANT layer (item 1, round 2's lockdown), before it ever
-- reaches this trigger, so it does NOT exercise this specific guard.
-- This section does: a privileged raw UPDATE straight to HIRED, on a
-- record with NO matching hr.employees row, must still be rejected -
-- by THIS guard specifically, independent of RLS/grants entirely.
-- ========================================================================
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_organization_id uuid;
    v_guard_test_person_id uuid;
    v_guard_test_record_id uuid;
    v_status_after text;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    SELECT "id" INTO v_organization_id FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    INSERT INTO "core"."people" ("organization_id", "full_name", "primary_email", "person_type", "status")
    VALUES (v_organization_id, 'Hired Guard Test Person', 'hired-guard-test-' || extract(epoch from now())::text || '@example.invalid', 'CANDIDATE', 'ACTIVE')
    RETURNING "id" INTO v_guard_test_person_id;

    -- Directly at APPROVED - no create/approve RPC flow needed, this
    -- test is specifically about the HIRED transition's own guard, not
    -- about how the record got to APPROVED. Deliberately: no
    -- hr.employees row exists for this person, and person_type stays
    -- CANDIDATE (never flipped to EMPLOYEE) - exactly the inconsistent
    -- state the guard exists to catch.
    INSERT INTO "onboarding"."onboarding_records" ("person_id", "status", "created_by")
    VALUES (v_guard_test_person_id, 'APPROVED', v_hr_admin)
    RETURNING "id" INTO v_guard_test_record_id;

    BEGIN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'HIRED' WHERE "id" = v_guard_test_record_id;
        INSERT INTO "_onboarding_test_results" VALUES ('8c-hired-consistency-guard', 'FAIL: succeeded - a HIRED record was created with no hr.employees row and person_type still CANDIDATE');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'ONBOARDING_HIRED_INVARIANT_VIOLATED%' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('8c-hired-consistency-guard', 'PASS: correctly rejected by the cross-table consistency guard - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('8c-hired-consistency-guard', 'FAIL: rejected, but NOT by the consistency guard - ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    SELECT "status" INTO v_status_after FROM "onboarding"."onboarding_records" WHERE "id" = v_guard_test_record_id;
    INSERT INTO "_onboarding_test_results" VALUES (
        '8d-hired-consistency-guard-record-unchanged',
        CASE WHEN v_status_after = 'APPROVED' THEN 'PASS: record remains APPROVED' ELSE 'FAIL: record status is now ' || v_status_after END
    );
END;
$$;

-- ========================================================================
-- SECTION 9 (REWRITTEN, item 5, round 4) - direct core.people /
-- hr.employees writes, as the REAL third test account (item 3), which
-- holds no permission yet at this point (linking happens in SECTION
-- 16).
--
-- core.people's "people_update" RLS policy (phase_7) is
-- `FOR UPDATE USING (core.has_permission(...))` - USING ONLY, no WITH
-- CHECK. For UPDATE, a USING-only policy that evaluates false simply
-- EXCLUDES the row from the statement's match set - the UPDATE affects
-- 0 rows and raises NO exception at all. The old 9a assumed an
-- exception (SQLSTATE 42501) would be raised - it would not be, and
-- that test would have reported a false FAIL against a control that is
-- actually working correctly, just silently. The real invariant to
-- check is simpler and more direct than catching an exception: did
-- person_type actually change or not. Checked by re-reading the row in
-- a SEPARATE, privileged block afterward (the unauthorized account
-- can't even SELECT this row under "authenticated" - core.people's own
-- SELECT policy would hide it - so verification has to happen outside
-- that role).
--
-- hr.employees' "employees_insert" policy IS `WITH CHECK`, which DOES
-- raise on violation (INSERT has no "just filter the row" option - the
-- row either gets created or the statement fails) - so 9b's
-- exception-based check was already structurally correct; kept as-is,
-- with a privileged re-verification added that no row was actually
-- created, as defense against relying on the exception alone.
-- ========================================================================

-- Step 1 (privileged): capture the TRUE before-state.
DO $$
DECLARE
    v_person_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_person_id');
    v_person_type_before text;
BEGIN
    SELECT "person_type" INTO v_person_type_before FROM "core"."people" WHERE "id" = v_person_id;
    INSERT INTO "_onboarding_test_ids" VALUES ('person_type_before_section9', v_person_type_before);
END;
$$;

-- Step 2 (as the unauthorized account): attempt both writes. Capture
-- ROW_COUNT after the UPDATE regardless of whether it raised - that's
-- the actual signal for a USING-only policy, not the presence of an
-- exception.
SET ROLE "authenticated";
DO $$
DECLARE
    v_candidate_user uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'candidate_user');
    v_person_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_person_id');
    v_row_count int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_candidate_user::text, 'role', 'authenticated')::text, true);

    BEGIN
        UPDATE "core"."people" SET "person_type" = 'EMPLOYEE' WHERE "id" = v_person_id;
        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        INSERT INTO "_onboarding_test_ids" VALUES ('section9_update_outcome', 'no_exception_rowcount_' || v_row_count::text);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_onboarding_test_ids" VALUES ('section9_update_outcome', 'exception_sqlstate_' || SQLSTATE);
    END;

    BEGIN
        INSERT INTO "hr"."employees" ("person_id", "employee_number", "hire_date", "employment_status")
        VALUES (v_person_id, 'EMP-SHOULD-NOT-EXIST', CURRENT_DATE, 'ACTIVE');
        INSERT INTO "_onboarding_test_results" VALUES ('9b-negative-direct-employees-insert', 'FAIL: INSERT statement succeeded with no exception');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('9b-negative-direct-employees-insert', 'PASS: correctly rejected, SQLSTATE 42501 - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('9b-negative-direct-employees-insert', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;
RESET ROLE;

-- Step 3 (privileged): verify the TRUE after-state and render the real
-- verdicts for both sub-tests, based on actual data, not assumptions
-- about mechanism.
DO $$
DECLARE
    v_person_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_person_id');
    v_person_type_before text := (SELECT "value" FROM "_onboarding_test_ids" WHERE "key" = 'person_type_before_section9');
    v_person_type_after text;
    v_update_outcome text := (SELECT "value" FROM "_onboarding_test_ids" WHERE "key" = 'section9_update_outcome');
    v_employees_row_count int;
BEGIN
    SELECT "person_type" INTO v_person_type_after FROM "core"."people" WHERE "id" = v_person_id;

    IF v_person_type_after = v_person_type_before THEN
        INSERT INTO "_onboarding_test_results" VALUES (
            '9a-negative-direct-people-mutation',
            format('PASS: person_type unchanged (%s) - UPDATE outcome was %s', v_person_type_after, v_update_outcome)
        );
    ELSE
        INSERT INTO "_onboarding_test_results" VALUES (
            '9a-negative-direct-people-mutation',
            format('FAIL: person_type actually changed, %s -> %s - the unauthorized UPDATE took effect', v_person_type_before, v_person_type_after)
        );
    END IF;

    SELECT count(*) INTO v_employees_row_count FROM "hr"."employees" WHERE "person_id" = v_person_id AND "employee_number" = 'EMP-SHOULD-NOT-EXIST';
    INSERT INTO "_onboarding_test_results" VALUES (
        '9c-negative-direct-employees-insert-no-row-created',
        CASE WHEN v_employees_row_count = 0 THEN 'PASS: no hr.employees row was created' ELSE 'FAIL: a row WAS created despite the exception' END
    );
END;
$$;

-- ========================================================================
-- SECTION 10 - confirm_employee_hire(), retry-safety, three resulting
-- states, HIRED -> WITHDRAWN rejected two ways
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_record_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_record_id');
    v_person_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_person_id');
    -- Round 7 (execution finding): hr.employees.employee_number is UNIQUE and
    -- earlier runs commit their rows, so a hard-coded value made the suite
    -- fail on any re-run. Generate a fresh value per run.
    v_emp_no text := 'EMP-TEST-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
    v_hire_result jsonb;
    v_retry_result jsonb;
    v_person_type text;
    v_hr_employee_id_1 uuid;
    v_hr_employee_id_2 uuid;
    v_version_after_hire int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    v_hire_result := "onboarding"."confirm_employee_hire"(v_record_id, v_emp_no, '2026-10-01'::date);
    INSERT INTO "_onboarding_test_results" VALUES ('10a-confirm-hire', v_hire_result::text);
    v_hr_employee_id_1 := (v_hire_result->>'hr_employee_id')::uuid;

    SELECT "person_type" INTO v_person_type FROM "core"."people" WHERE "id" = v_person_id;
    INSERT INTO "_onboarding_test_results" VALUES ('10b-person-type-after-hire', v_person_type);

    -- Clean retry, SAME values - must succeed as an idempotent replay.
    v_retry_result := "onboarding"."confirm_employee_hire"(v_record_id, v_emp_no, '2026-10-01'::date);
    v_hr_employee_id_2 := (v_retry_result->>'hr_employee_id')::uuid;
    INSERT INTO "_onboarding_test_results" VALUES (
        '10c-confirm-hire-retry-safe',
        CASE WHEN v_hr_employee_id_2 = v_hr_employee_id_1 AND (v_retry_result->>'idempotent_replay')::boolean = true
            THEN 'PASS: retry returned the same hr_employee_id, idempotent_replay=true'
            ELSE 'FAIL: ' || v_retry_result::text
        END
    );

    BEGIN
        PERFORM "onboarding"."withdraw_onboarding_request"(v_record_id, 'should not be allowed');
        INSERT INTO "_onboarding_test_results" VALUES ('10d-negative-withdraw-after-hired-via-rpc', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'ONBOARDING_ALREADY_HIRED%' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('10d-negative-withdraw-after-hired-via-rpc', 'PASS: correctly rejected by the already-HIRED check - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('10d-negative-withdraw-after-hired-via-rpc', 'FAIL: wrong control - ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    BEGIN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'WITHDRAWN' WHERE "id" = v_record_id;
        INSERT INTO "_onboarding_test_results" VALUES ('10e-negative-withdraw-after-hired-via-raw-update', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('10e-negative-withdraw-after-hired-via-raw-update', 'PASS: correctly rejected, SQLSTATE 42501 - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('10e-negative-withdraw-after-hired-via-raw-update', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    SELECT "version" INTO v_version_after_hire FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id;
    INSERT INTO "_onboarding_test_ids" VALUES ('version_after_hire', v_version_after_hire::text);
    INSERT INTO "_onboarding_test_results" VALUES ('10f-version-after-hire', 'version=' || v_version_after_hire::text || ' (the clean retry in 10c must NOT have bumped this further - it is a true no-op)');
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 11 (NEW, item 6) - confirm_employee_hire() retry with a
-- CONFLICTING employee_number - must be rejected, not silently return
-- the original (different) result.
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_record_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_record_id');
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);
    BEGIN
        PERFORM "onboarding"."confirm_employee_hire"(v_record_id, 'EMP-999-CONFLICT', '2026-11-01'::date);
        INSERT INTO "_onboarding_test_results" VALUES ('11-hire-replay-payload-mismatch', 'FAIL: succeeded - a conflicting retry was silently accepted as a clean replay');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'ONBOARDING_HIRE_REPLAY_PAYLOAD_MISMATCH%' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('11-hire-replay-payload-mismatch', 'PASS: correctly rejected - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('11-hire-replay-payload-mismatch', 'FAIL: wrong control - ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 11B (NEW, item 3, round 4) - the NULL-safe case specifically:
-- a FRESH request, hired with employee_number = NULL (a legitimate,
-- allowed call - the column has no NOT NULL constraint), then retried
-- with a non-null employee_number. Plain "!=" against NULL evaluates to
-- UNKNOWN, not TRUE, so the old check would have silently passed this
-- straight through as a "clean" replay. Uses a separate request from
-- SECTION 11 deliberately - that one's record already has a non-null
-- employee_number from SECTION 10, which wouldn't exercise this
-- specific NULL-original case at all.
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_approver_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'approver_admin');
    v_submit_result jsonb;
    v_record_id uuid;
    v_workflow_request_id uuid;
    v_step_id uuid;
    v_version int;
    v_hire_result jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);
    v_submit_result := "onboarding"."create_and_submit_onboarding_request"(
        'Test Candidate Null Employee Number', 'test-candidate-null-empno-' || extract(epoch from now())::text || '@example.invalid',
        'test-key-null-empno-' || extract(epoch from now())::text, 'QA Engineer', NULL, CURRENT_DATE + 14
    );
    v_record_id := (v_submit_result->>'onboarding_record_id')::uuid;
    v_workflow_request_id := (v_submit_result->>'workflow_request_id')::uuid;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_approver_admin::text, 'role', 'authenticated')::text, true);
    SELECT s."id" INTO v_step_id FROM "workflow"."approval_steps" s
    WHERE s."approval_request_id" = v_workflow_request_id AND s."status" IN ('PENDING', 'IN_PROGRESS')
    ORDER BY s."step_no" LIMIT 1;
    SELECT "version" INTO v_version FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;
    PERFORM "workflow"."process_approval_action"(
        v_workflow_request_id, 'APPROVE', v_step_id, 'approved (test)', NULL,
        'test-approve-' || v_record_id::text, v_version
    );

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);
    -- Hire with employee_number OMITTED (NULL) - a legitimate call.
    v_hire_result := "onboarding"."confirm_employee_hire"(v_record_id, NULL, '2026-10-01'::date);
    INSERT INTO "_onboarding_test_results" VALUES (
        '11b1-hire-with-null-employee-number',
        CASE WHEN v_hire_result->>'hr_employee_id' IS NOT NULL THEN 'PASS: hired with employee_number=NULL' ELSE 'FAIL: ' || v_hire_result::text END
    );

    -- Retry with a NON-NULL employee_number - must be caught despite
    -- the original being NULL.
    BEGIN
        PERFORM "onboarding"."confirm_employee_hire"(v_record_id, 'EMP-SHOULD-BE-REJECTED', '2026-10-01'::date);
        INSERT INTO "_onboarding_test_results" VALUES ('11b2-hire-replay-null-original-mismatch', 'FAIL: succeeded - a non-null retry against a NULL original was silently accepted');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'ONBOARDING_HIRE_REPLAY_PAYLOAD_MISMATCH%' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('11b2-hire-replay-null-original-mismatch', 'PASS: correctly rejected even though the original value was NULL - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('11b2-hire-replay-null-original-mismatch', 'FAIL: wrong control - ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 12 - a SECOND, separate onboarding request, taken to REJECTED
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_approver_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'approver_admin');
    v_submit_result jsonb;
    v_record_id uuid;
    v_workflow_request_id uuid;
    v_step_id uuid;
    v_version int;
    v_reject_result jsonb;
    v_final_status text;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);
    v_submit_result := "onboarding"."create_and_submit_onboarding_request"(
        'Test Candidate Reject', 'test-candidate-reject-' || extract(epoch from now())::text || '@example.invalid',
        'test-key-reject-' || extract(epoch from now())::text, 'QA Engineer', NULL, CURRENT_DATE + 14
    );
    v_record_id := (v_submit_result->>'onboarding_record_id')::uuid;
    v_workflow_request_id := (v_submit_result->>'workflow_request_id')::uuid;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_approver_admin::text, 'role', 'authenticated')::text, true);
    SELECT s."id" INTO v_step_id FROM "workflow"."approval_steps" s
    WHERE s."approval_request_id" = v_workflow_request_id AND s."status" IN ('PENDING', 'IN_PROGRESS')
    ORDER BY s."step_no" LIMIT 1;
    SELECT "version" INTO v_version FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;

    v_reject_result := "workflow"."process_approval_action"(
        v_workflow_request_id, 'REJECT', v_step_id, 'rejected (test)', NULL,
        'test-reject-' || v_record_id::text, v_version
    );
    INSERT INTO "_onboarding_test_results" VALUES ('12a-reject', v_reject_result::text);

    SELECT "status" INTO v_final_status FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id;
    INSERT INTO "_onboarding_test_results" VALUES (
        '12b-status-after-reject',
        CASE WHEN v_final_status = 'REJECTED' THEN 'PASS: REJECTED' ELSE 'FAIL: ' || v_final_status END
    );

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);
    BEGIN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'SUBMITTED' WHERE "id" = v_record_id;
        INSERT INTO "_onboarding_test_results" VALUES ('12c-negative-rejected-to-submitted', 'FAIL: succeeded');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('12c-negative-rejected-to-submitted', 'PASS: correctly rejected, SQLSTATE 42501 - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('12c-negative-rejected-to-submitted', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 13 - a THIRD onboarding request, withdrawn while SUBMITTED.
-- Also the first real exercise of process_system_action (item 11
-- checkpoint, still standing from round 2) - if this fails, report the
-- exact PostgreSQL error, do not widen any grant.
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_submit_result jsonb;
    v_record_id uuid;
    v_workflow_request_id uuid;
    v_withdraw_result jsonb;
    v_final_status text;
    v_workflow_is_open boolean;
    v_fresh_withdraw_cancelled boolean;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    v_submit_result := "onboarding"."create_and_submit_onboarding_request"(
        'Test Candidate Withdraw Submitted', 'test-candidate-withdraw-sub-' || extract(epoch from now())::text || '@example.invalid',
        'test-key-withdraw-sub-' || extract(epoch from now())::text, 'QA Engineer', NULL, CURRENT_DATE + 14
    );
    v_record_id := (v_submit_result->>'onboarding_record_id')::uuid;
    v_workflow_request_id := (v_submit_result->>'workflow_request_id')::uuid;

    v_withdraw_result := "onboarding"."withdraw_onboarding_request"(v_record_id, '  '); -- blank reason, deliberately - item 7: must normalize, not store blank
    INSERT INTO "_onboarding_test_results" VALUES ('13a-withdraw-while-submitted', v_withdraw_result::text);
    INSERT INTO "_onboarding_test_results" VALUES (
        '13b-blank-reason-normalized',
        CASE WHEN v_withdraw_result->>'withdrawal_reason' = 'Onboarding request withdrawn'
            THEN 'PASS: blank reason normalized to the fallback'
            ELSE 'FAIL: ' || (v_withdraw_result->>'withdrawal_reason')
        END
    );

    SELECT "status" INTO v_final_status FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id;
    SELECT "is_open" INTO v_workflow_is_open FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;

    INSERT INTO "_onboarding_test_results" VALUES (
        '13c-withdraw-closed-workflow',
        CASE WHEN v_final_status = 'WITHDRAWN' AND v_workflow_is_open = false
            THEN 'PASS: onboarding_records WITHDRAWN and workflow.approval_requests is_open=false'
            ELSE 'FAIL: status=' || v_final_status || ' is_open=' || v_workflow_is_open::text
        END
    );

    -- Item 3 (round 5): for the SUBMITTED-withdrawal case, CANCEL is
    -- genuinely performed - workflow_cancelled must be true, both on
    -- the fresh call (captured in v_fresh_withdraw_cancelled right
    -- after 13a, before v_withdraw_result gets overwritten by the
    -- retry call below) and on replay.
    v_fresh_withdraw_cancelled := (v_withdraw_result->>'workflow_cancelled')::boolean;
    INSERT INTO "_onboarding_test_results" VALUES (
        '13c2-workflow-cancelled-true-on-fresh-submitted-withdrawal',
        CASE WHEN v_fresh_withdraw_cancelled = true THEN 'PASS: workflow_cancelled=true on the fresh call' ELSE 'FAIL: workflow_cancelled=' || v_fresh_withdraw_cancelled::text END
    );

    v_withdraw_result := "onboarding"."withdraw_onboarding_request"(v_record_id, 'retry (test)');
    INSERT INTO "_onboarding_test_results" VALUES (
        '13d-withdraw-retry-idempotent',
        CASE WHEN (v_withdraw_result->>'idempotent_replay')::boolean = true THEN 'PASS: idempotent_replay=true' ELSE 'FAIL: ' || v_withdraw_result::text END
    );
    -- ...and still true on replay (this is the exact case the old
    -- `NOT is_open` logic happened to get RIGHT by coincidence for
    -- SUBMITTED, but WRONG for APPROVED - section 14 is the one that
    -- actually distinguishes the two).
    INSERT INTO "_onboarding_test_results" VALUES (
        '13e-workflow-cancelled-true-on-replay-submitted-withdrawal',
        CASE WHEN (v_withdraw_result->>'workflow_cancelled')::boolean = true
            THEN 'PASS: workflow_cancelled=true on replay too'
            ELSE 'FAIL: workflow_cancelled=' || (v_withdraw_result->>'workflow_cancelled')
        END
    );
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 14 - a FOURTH onboarding request, approved then withdrawn
-- before hire, WITH an explicit reason this time (item 7 - the normal,
-- non-blank path).
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_approver_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'approver_admin');
    v_submit_result jsonb;
    v_record_id uuid;
    v_workflow_request_id uuid;
    v_step_id uuid;
    v_version int;
    v_withdraw_result jsonb;
    v_final_status text;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);
    v_submit_result := "onboarding"."create_and_submit_onboarding_request"(
        'Test Candidate Withdraw Approved', 'test-candidate-withdraw-app-' || extract(epoch from now())::text || '@example.invalid',
        'test-key-withdraw-app-' || extract(epoch from now())::text, 'QA Engineer', NULL, CURRENT_DATE + 14
    );
    v_record_id := (v_submit_result->>'onboarding_record_id')::uuid;
    v_workflow_request_id := (v_submit_result->>'workflow_request_id')::uuid;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_approver_admin::text, 'role', 'authenticated')::text, true);
    SELECT s."id" INTO v_step_id FROM "workflow"."approval_steps" s
    WHERE s."approval_request_id" = v_workflow_request_id AND s."status" IN ('PENDING', 'IN_PROGRESS')
    ORDER BY s."step_no" LIMIT 1;
    SELECT "version" INTO v_version FROM "workflow"."approval_requests" WHERE "id" = v_workflow_request_id;
    PERFORM "workflow"."process_approval_action"(
        v_workflow_request_id, 'APPROVE', v_step_id, 'approved (test)', NULL,
        'test-approve-' || v_record_id::text, v_version
    );

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);
    v_withdraw_result := "onboarding"."withdraw_onboarding_request"(v_record_id, 'offer declined after approval (test)');
    INSERT INTO "_onboarding_test_results" VALUES ('14a-withdraw-while-approved', v_withdraw_result::text);

    SELECT "status" INTO v_final_status FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id;
    INSERT INTO "_onboarding_test_results" VALUES (
        '14b-status-after-withdraw-approved',
        CASE WHEN v_final_status = 'WITHDRAWN' AND v_withdraw_result->>'withdrawal_reason' = 'offer declined after approval (test)'
            THEN 'PASS: WITHDRAWN, reason stored verbatim'
            ELSE 'FAIL: status=' || v_final_status || ' reason=' || (v_withdraw_result->>'withdrawal_reason')
        END
    );

    -- Item 3 (round 5): the APPROVED-withdrawal case never actually
    -- calls process_system_action CANCEL (the workflow request is
    -- already closed as APPROVED, not cancelled) - workflow_cancelled
    -- must be false here, on the FRESH call.
    INSERT INTO "_onboarding_test_results" VALUES (
        '14c-workflow-cancelled-false-on-fresh-approved-withdrawal',
        CASE WHEN (v_withdraw_result->>'workflow_cancelled')::boolean = false
            THEN 'PASS: workflow_cancelled=false (correctly - this request was never actually cancelled, only closed by approval)'
            ELSE 'FAIL: workflow_cancelled=' || (v_withdraw_result->>'workflow_cancelled')
        END
    );

    -- Item 3 (round 5), new: and still false on REPLAY - this is
    -- exactly the case the old `NOT is_open` logic got wrong (an
    -- APPROVED request is also is_open=false, which the old code
    -- misread as "cancelled").
    v_withdraw_result := "onboarding"."withdraw_onboarding_request"(v_record_id, 'retry (test)');
    INSERT INTO "_onboarding_test_results" VALUES (
        '14d-workflow-cancelled-false-on-replay-approved-withdrawal',
        CASE WHEN (v_withdraw_result->>'idempotent_replay')::boolean = true AND (v_withdraw_result->>'workflow_cancelled')::boolean = false
            THEN 'PASS: idempotent_replay=true AND workflow_cancelled=false on replay'
            ELSE 'FAIL: ' || v_withdraw_result::text
        END
    );
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 15 (item 1, round 3) - unique constraints, FIXED: the
-- one-open-per-person test now uses a DEDICATED fresh person, NOT the
-- main record's person (HIRED by now, and HIRED is not "open" under
-- the partial index at all - the old test proved nothing). Both
-- assertions check SQLSTATE = '23505' (unique_violation) specifically.
-- ========================================================================
DO $$
DECLARE
    v_organization_id uuid;
    v_unique_test_person_id uuid;
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
    v_fake_workflow_request_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_workflow_request_id');
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    SELECT "id" INTO v_organization_id FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    INSERT INTO "core"."people" ("organization_id", "full_name", "primary_email", "person_type", "status")
    VALUES (v_organization_id, 'Unique Index Test Person', 'unique-test-' || extract(epoch from now())::text || '@example.invalid', 'CANDIDATE', 'ACTIVE')
    RETURNING "id" INTO v_unique_test_person_id;

    -- First OPEN record for this person - must succeed.
    INSERT INTO "onboarding"."onboarding_records" ("person_id", "status", "created_by")
    VALUES (v_unique_test_person_id, 'SUBMITTED', v_hr_admin);
    INSERT INTO "_onboarding_test_results" VALUES ('15a-first-open-record-succeeds', 'PASS: first OPEN record for a dedicated fresh person created');

    -- Second OPEN record for the SAME person - must fail with 23505.
    BEGIN
        INSERT INTO "onboarding"."onboarding_records" ("person_id", "status", "created_by")
        VALUES (v_unique_test_person_id, 'APPROVED', v_hr_admin);
        INSERT INTO "_onboarding_test_results" VALUES ('15b-negative-second-open-record-same-person', 'FAIL: a second OPEN onboarding record for the same person was allowed');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '23505' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('15b-negative-second-open-record-same-person', 'PASS: correctly rejected, SQLSTATE 23505 (unique_violation) - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('15b-negative-second-open-record-same-person', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;

    BEGIN
        INSERT INTO "onboarding"."onboarding_records" ("person_id", "status", "workflow_request_id", "created_by")
        VALUES (v_unique_test_person_id, 'REJECTED', v_fake_workflow_request_id, v_hr_admin);
        INSERT INTO "_onboarding_test_results" VALUES ('15c-negative-duplicate-workflow-request-link', 'FAIL: the same workflow_request_id was linked to a second onboarding record');
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '23505' THEN
            INSERT INTO "_onboarding_test_results" VALUES ('15c-negative-duplicate-workflow-request-link', 'PASS: correctly rejected, SQLSTATE 23505 - ' || SQLERRM);
        ELSE
            INSERT INTO "_onboarding_test_results" VALUES ('15c-negative-duplicate-workflow-request-link', 'FAIL: wrong control - SQLSTATE ' || SQLSTATE || ': ' || SQLERRM);
        END IF;
    END;
END;
$$;

-- ========================================================================
-- SECTION 16 - candidate self-view, before and after linking, using the
-- real third test account.
-- ========================================================================
SET ROLE "authenticated";
DO $$
DECLARE
    v_record_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_record_id');
    v_candidate_user uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'candidate_user');
    v_found_count int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_candidate_user::text, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_found_count FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id;
    INSERT INTO "_onboarding_test_results" VALUES (
        '16a-candidate-view-before-linking',
        CASE WHEN v_found_count = 0 THEN 'PASS: not visible before linking' ELSE 'FAIL: visible before an ACTIVE person_user_link exists' END
    );
END;
$$;
RESET ROLE;

-- NOT one of Arslan's named spots for item 2, but the same root cause:
-- core.person_user_links has its own BEFORE INSERT trigger
-- (core._force_created_by(), same mechanism as onboarding_records' and
-- core.people's) requiring auth.uid() IS NOT NULL. Found while applying
-- the item-2 fix elsewhere - fixed here too for the same reason.
DO $$
DECLARE
    v_person_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_person_id');
    v_candidate_user uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'candidate_user');
    v_hr_admin uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'hr_admin');
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_hr_admin::text, 'role', 'authenticated')::text, true);

    INSERT INTO "core"."person_user_links" ("person_id", "user_id", "status", "created_by")
    VALUES (v_person_id, v_candidate_user, 'ACTIVE', v_hr_admin);
END;
$$;

SET ROLE "authenticated";
DO $$
DECLARE
    v_record_id uuid := (SELECT "value"::uuid FROM "_onboarding_test_ids" WHERE "key" = 'main_record_id');
    v_candidate_user uuid := (SELECT "value"::uuid FROM "_onboarding_test_config" WHERE "key" = 'candidate_user');
    v_found_count int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_candidate_user::text, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_found_count FROM "onboarding"."onboarding_records" WHERE "id" = v_record_id;
    INSERT INTO "_onboarding_test_results" VALUES (
        '16b-candidate-view-after-linking',
        CASE WHEN v_found_count = 1 THEN 'PASS: visible after ACTIVE person_user_link' ELSE 'FAIL: still not visible after linking' END
    );
END;
$$;
RESET ROLE;

-- ========================================================================
-- SECTION 17 (item 9, round 3) - version progression asserted at the
-- exact defined lifecycle points, not just ">1" at the end: starts at
-- 1 (INSERT), then bumps exactly once per real UPDATE. For the main
-- record: INSERT(1) -> attach workflow_request_id(2) -> approve(3) ->
-- hire(4). The clean retry in SECTION 10c must NOT have added a 5th.
-- ========================================================================
DO $$
DECLARE
    v_after_create int := (SELECT "value"::int FROM "_onboarding_test_ids" WHERE "key" = 'version_after_create');
    v_after_approve int := (SELECT "value"::int FROM "_onboarding_test_ids" WHERE "key" = 'version_after_approve');
    v_after_hire int := (SELECT "value"::int FROM "_onboarding_test_ids" WHERE "key" = 'version_after_hire');
BEGIN
    INSERT INTO "_onboarding_test_results" VALUES (
        '17-version-progression',
        CASE WHEN v_after_create = 2 AND v_after_approve = 3 AND v_after_hire = 4
            THEN format('PASS: exact progression 2 -> 3 -> 4 (create+attach=%s, approve=%s, hire=%s)', v_after_create, v_after_approve, v_after_hire)
            ELSE format('FAIL: expected 2 -> 3 -> 4, got create+attach=%s, approve=%s, hire=%s - investigate which step double-incremented or failed to increment', v_after_create, v_after_approve, v_after_hire)
        END
    );
END;
$$;

-- ========================================================================
-- SECTION 18 (REWRITTEN, round 7) - rollback / re-apply is a PROCEDURE,
-- not a SQL assertion. Two separate environments, never combined.
--
-- WHY: once the onboarding workflow seed has run, its version is ACTIVE
-- and its configuration is immutable (triggers from
-- phase_2_workflow_engine/005_workflow_rls_grants.sql block DELETE on
-- workflow_steps / workflow_statuses / transition_rules /
-- workflow_step_assignees for ACTIVE or RETIRED versions). Runtime rows
-- in workflow.approval_actions / status_history are append-only too.
-- This is a shared workflow-engine characteristic, not a Phase 8 defect.
-- Phase 8 therefore does not try to retract an activated workflow.
--
-- TRACK A - Migration Reversibility Evidence (fresh scratch DB/branch;
--   never shared UAT or production):
--     1. Clean pre-apply snapshot (checklist Step 1).
--     2. Apply 001-007.
--     3. DO NOT call onboarding.seed_onboarding_workflow_definition().
--     4. DO NOT run this test file. Create no onboarding data.
--     5. Run rollbacks: 007 -> 006 -> 004 -> 005 -> 003 -> 002 -> 001.
--        (004's rollback prints the CASE 1 notice and drops only the
--        seed function.)
--     6. Verify exact pre-Phase-8 state: pg_namespace has no
--        'onboarding'; Step 1 snapshot matches, including
--        workflow._seed_provenance.
--     7. Re-apply 001-007 and confirm it succeeds (repeatability).
--
-- TRACK B - Functional Execution Evidence (the seeded scratch DB):
--     1. 001-007 applied, workflow seeded (checklist Steps 1-4).
--     2. Run THIS file in full.
--     3. Run the two-session concurrency test (checklist Step 5a).
--     4. Run Leave/Attendance/Assets/Contracts regressions (Step 6).
--     5. NEVER attempt rollback here. The seeded workflow is permanent
--        in this database; if the 004 rollback is run here by mistake it
--        raises ONBOARDING_ROLLBACK_BLOCKED_ACTIVE_WORKFLOW and changes
--        nothing. Dispose of the environment wholesale when finished.
-- ========================================================================

-- ========================================================================
-- FINAL GATE (round 7, Shawaiz item 2): a completed script is NOT a
-- passing run. Record a summary row, then raise if ANY result row begins
-- with FAIL, listing the failing steps in the error message so they are
-- visible even though the final SELECT is never reached. (The raise also
-- rolls the whole script back when the editor runs it as one
-- transaction, which is the safe outcome for a failed run.)
-- ========================================================================
DO $$
DECLARE
    v_fail_count int;
    v_pass_count int;
    v_failed_steps text;
BEGIN
    SELECT count(*) FILTER (WHERE "result" LIKE 'FAIL%'),
           count(*) FILTER (WHERE "result" LIKE 'PASS%'),
           string_agg("step" || ' => ' || "result", E'\n' ORDER BY "step") FILTER (WHERE "result" LIKE 'FAIL%')
    INTO v_fail_count, v_pass_count, v_failed_steps
    FROM "_onboarding_test_results";

    IF v_fail_count > 0 THEN
        RAISE EXCEPTION 'ONBOARDING_TEST_SUITE_FAILED: % FAIL result(s), % PASS. Failing steps:%', v_fail_count, v_pass_count, E'\n' || v_failed_steps;
    END IF;

    IF v_pass_count = 0 THEN
        RAISE EXCEPTION 'ONBOARDING_TEST_SUITE_EMPTY: no PASS results were recorded - the suite did not actually assert anything';
    END IF;

    INSERT INTO "_onboarding_test_results" VALUES (
        '99-summary',
        'ALL PASS: FAIL count = 0, PASS count = ' || v_pass_count::text
    );
END;
$$;

SELECT * FROM "_onboarding_test_results" ORDER BY "step";
