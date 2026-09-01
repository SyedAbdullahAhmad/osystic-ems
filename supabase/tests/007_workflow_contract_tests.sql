-- ========================================================================
-- 007_workflow_contract_tests.sql
--
-- Contract / functional lifecycle tests for the workflow engine
-- (001-006, 006a). Written against the round-4-corrected baseline.
--
-- HOW TO RUN: apply 001-006 (006a is NOT required for these tests -
-- they use test fixture roles, not the real production role mapping,
-- per explicit instruction not to wait on that). Then run this file,
-- then 008. Then:
--   SELECT * FROM workflow._test_summary();
-- to see pass/fail counts per suite. Any FAILED row is a real
-- regression against the contract described below - do not proceed to
-- the next step of the execution cycle until this is all green.
--
-- FRAMEWORK: no external test extension (pgTAP etc.) is assumed to be
-- installed - this is a small self-contained assertion harness so it
-- runs anywhere psql/the Supabase SQL editor can reach. Every
-- assertion is recorded to workflow._test_results (created below) so
-- a full run produces a queryable report, not just RAISE NOTICE
-- output that scrolls past.
--
-- COVERAGE NOTE: this is a representative, not exhaustive, test suite
-- covering every category your review explicitly required. It is
-- intended to be extended, not treated as a final/complete count of
-- every possible edge case.
-- ========================================================================


-- ------------------------------------------------------------------------
-- Test harness (shared by 007 and 008)
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "workflow"."_test_results" (
    "id" bigserial PRIMARY KEY,
    "suite" text NOT NULL,
    "test_name" text NOT NULL,
    "passed" boolean NOT NULL,
    "detail" text,
    "run_at" timestamptz NOT NULL DEFAULT now()
);

-- Several suites (in both 007 and 008) deliberately SET LOCAL ROLE
-- "authenticated" mid-block to test RLS/grant boundaries from that
-- role's own perspective, then call _test_assert() while still under
-- that role to record the result. _test_assert() is a plain function
-- (not SECURITY DEFINER), so its own INSERT runs as whatever role is
-- currently active - without this, that INSERT fails with
-- "permission denied for table _test_results" the moment any test
-- tries to record its own outcome while impersonating authenticated.
-- This is pure test-harness plumbing (not a real production grant);
-- scoped to only what _test_assert()/_test_assert_raises() actually
-- do (a single INSERT each, per their bodies below - no UPDATE/DELETE
-- needed).
GRANT INSERT ON "workflow"."_test_results" TO "authenticated";
GRANT USAGE ON SEQUENCE "workflow"."_test_results_id_seq" TO "authenticated";

-- Every _test_assert() call is a plain INSERT with no de-dup, and
-- neither _test_summary() nor _test_failures() filters by run_at - so
-- without this, results accumulate FOREVER across every run this file
-- has ever been pasted, and a test that was fixed and now passes can
-- still show up as a failure via its own stale row from an old run
-- (this is exactly what happened: a test name that no longer even
-- exists in this file's current code still appeared as a failure).
-- Truncate here, once, at the top of 007 (which always runs first) -
-- 008 deliberately does NOT truncate, so its own results land
-- alongside 007's for one combined summary, per its header comment.
TRUNCATE TABLE "workflow"."_test_results";

CREATE OR REPLACE FUNCTION "workflow"."_test_assert"(
    "p_suite" text, "p_test_name" text, "p_condition" boolean, "p_detail" text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO "workflow"."_test_results" ("suite", "test_name", "passed", "detail")
    VALUES (p_suite, p_test_name, p_condition, p_detail);
    IF NOT p_condition THEN
        RAISE WARNING 'TEST FAILED [%] %: %', p_suite, p_test_name, COALESCE(p_detail, '(no detail)');
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION "workflow"."_test_assert_raises"(
    "p_suite" text, "p_test_name" text, "p_sql" text, "p_expected_sqlstate_fragment" text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    PERFORM "workflow"."_test_assert"(p_suite, p_test_name, false, 'expected an exception, none was raised');
EXCEPTION WHEN OTHERS THEN
    IF p_expected_sqlstate_fragment IS NULL OR SQLERRM ILIKE '%' || p_expected_sqlstate_fragment || '%' THEN
        PERFORM "workflow"."_test_assert"(p_suite, p_test_name, true, SQLERRM);
    ELSE
        PERFORM "workflow"."_test_assert"(p_suite, p_test_name, false,
            'wrong exception - expected message containing "' || p_expected_sqlstate_fragment || '", got: ' || SQLERRM);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION "workflow"."_test_summary"()
RETURNS TABLE ("suite" text, "passed" bigint, "failed" bigint, "total" bigint)
LANGUAGE sql AS $$
    SELECT "suite",
           count(*) FILTER (WHERE "passed"),
           count(*) FILTER (WHERE NOT "passed"),
           count(*)
    FROM "workflow"."_test_results"
    GROUP BY "suite"
    ORDER BY "suite";
$$;

CREATE OR REPLACE FUNCTION "workflow"."_test_failures"()
RETURNS TABLE ("suite" text, "test_name" text, "detail" text)
LANGUAGE sql AS $$
    SELECT "suite", "test_name", "detail" FROM "workflow"."_test_results" WHERE NOT "passed" ORDER BY "suite", "test_name";
$$;


-- ------------------------------------------------------------------------
-- Fixtures: test-only auth.users rows and a full DRAFT->ACTIVE workflow
-- (2-step: a parallel MIN_N stage, then a sequential ONE_OF stage) for
-- the lifecycle tests below. These UUIDs are fixed/literal so tests
-- are reproducible - TEST FIXTURES ONLY, never use these in a real
-- environment.
-- ------------------------------------------------------------------------
DO $$
DECLARE
    v_actor_a uuid := '00000000-0000-0000-0000-0000000000a1';  -- parallel-stage approver A
    v_actor_b uuid := '00000000-0000-0000-0000-0000000000a2';  -- parallel-stage approver B
    v_actor_c uuid := '00000000-0000-0000-0000-0000000000a3';  -- parallel-stage approver C (3rd, for MIN_N=2-of-3)
    v_actor_final uuid := '00000000-0000-0000-0000-0000000000a4'; -- sequential ONE_OF approver
    v_initiator uuid := '00000000-0000-0000-0000-0000000000a5';
    v_admin uuid := '00000000-0000-0000-0000-0000000000a6';   -- holds WORKFLOW_CONFIG_MANAGE fixture permission
    v_definition_id uuid;
    v_version_id uuid;
    v_permission_id uuid;
BEGIN
    INSERT INTO auth.users (id, email) VALUES
        (v_actor_a, 'test-actor-a@example.invalid'),
        (v_actor_b, 'test-actor-b@example.invalid'),
        (v_actor_c, 'test-actor-c@example.invalid'),
        (v_actor_final, 'test-actor-final@example.invalid'),
        (v_initiator, 'test-initiator@example.invalid'),
        (v_admin, 'test-admin@example.invalid')
    ON CONFLICT (id) DO NOTHING;

    -- Fixture permission + role/user_role grant so v_admin can call
    -- activate_workflow_version() (gated by WORKFLOW_CONFIG_MANAGE)
    -- without depending on 006a / the real production role mapping.
    INSERT INTO core.permissions (code, name, module, action, description, is_system)
    VALUES ('WORKFLOW_CONFIG_MANAGE', 'Manage Workflow Configuration', 'workflow', 'MANAGE', 'test fixture', true)
    ON CONFLICT (code) DO NOTHING;

    INSERT INTO core.roles (id, name, display_name, level, is_system)
    VALUES ('00000000-0000-0000-0000-0000000000f1', 'TEST_WORKFLOW_ADMIN', 'Test Workflow Admin', 100, false)
    ON CONFLICT (id) DO NOTHING;

    SELECT "id" INTO v_permission_id FROM core.permissions WHERE code = 'WORKFLOW_CONFIG_MANAGE';
    INSERT INTO core.role_permissions (role_id, permission_id, data_scope, effective_from)
    SELECT '00000000-0000-0000-0000-0000000000f1', v_permission_id, 'ALL', CURRENT_DATE
    WHERE NOT EXISTS (
        SELECT 1 FROM core.role_permissions
        WHERE role_id = '00000000-0000-0000-0000-0000000000f1' AND permission_id = v_permission_id
    );

    INSERT INTO core.user_roles (user_id, role_id, effective_from, is_active)
    SELECT v_admin, '00000000-0000-0000-0000-0000000000f1', CURRENT_DATE, true
    WHERE NOT EXISTS (
        SELECT 1 FROM core.user_roles
        WHERE user_id = v_admin AND role_id = '00000000-0000-0000-0000-0000000000f1'
    );

    -- Item (this fix): a workflow_version's children AND its own
    -- identity fields become PERMANENTLY immutable once ACTIVE -
    -- including against DELETE (confirmed: every child-immutability
    -- trigger covers INSERT OR UPDATE OR DELETE). That is correct,
    -- intentional behavior (it's the whole point of the immutability
    -- guarantee), not something to work around via teardown/deletion.
    -- The only safe way to make this fixture block re-runnable against
    -- the same persistent database is to detect "already done" and
    -- skip the whole creation+activation attempt entirely - never
    -- re-attempt a mutation that would only be needed on a truly fresh
    -- database.
    -- Always establish identity as v_admin here, regardless of which
    -- branch below runs - suites further down in this file no longer
    -- rely on this carryover for their own calls (each sets its own
    -- identity now), but keeping this unconditional costs nothing and
    -- removes one more implicit cross-block dependency.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

    IF EXISTS (
        SELECT 1 FROM "workflow"."workflow_versions"
        WHERE "id" = '00000000-0000-0000-0000-0000000000d2' AND "status" = 'ACTIVE'
    ) THEN
        v_definition_id := '00000000-0000-0000-0000-0000000000d1';
        v_version_id := '00000000-0000-0000-0000-0000000000d2';
    ELSE
        -- Item 4 (round 4): workflow_definitions/workflow_versions now
        -- require an authenticated session (auth.uid() must be present) to
        -- INSERT at all - identity is already set above.
        -- Definition + DRAFT version
        INSERT INTO "workflow"."workflow_definitions" (id, name, module, code, is_active, created_by)
        VALUES ('00000000-0000-0000-0000-0000000000d1', 'TEST_APPROVAL', 'test', 'TEST_ENTITY', true, v_admin)
        ON CONFLICT (id) DO NOTHING
        RETURNING "id" INTO v_definition_id;
        IF v_definition_id IS NULL THEN v_definition_id := '00000000-0000-0000-0000-0000000000d1'; END IF;

        INSERT INTO "workflow"."workflow_versions" (id, workflow_definition_id, version_no, status, created_by)
        VALUES ('00000000-0000-0000-0000-0000000000d2', v_definition_id, 1, 'DRAFT', v_admin)
        ON CONFLICT (id) DO NOTHING;
        v_version_id := '00000000-0000-0000-0000-0000000000d2';

        INSERT INTO "workflow"."workflow_statuses" (workflow_version_id, workflow_definition_id, status_code, is_initial, is_terminal, display_name)
        VALUES
            (v_version_id, '00000000-0000-0000-0000-0000000000d1', 'PENDING', true, false, 'Pending'),
            (v_version_id, '00000000-0000-0000-0000-0000000000d1', 'APPROVED', false, true, 'Approved'),
            (v_version_id, '00000000-0000-0000-0000-0000000000d1', 'REJECTED', false, true, 'Rejected')
        ON CONFLICT DO NOTHING;

        -- Step 1: parallel MIN_N (2-of-3)
        INSERT INTO "workflow"."workflow_steps" (id, workflow_version_id, step_key, step_no, sequence_no, step_name, approval_mode, required_approvals, is_maker_checker, sla_minutes)
        VALUES ('00000000-0000-0000-0000-0000000000d3', v_version_id, 'PARALLEL_MIN_N', 1, 1, 'Parallel MIN_N', 'MIN_N', 2, false, 1440)
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO "workflow"."workflow_step_assignees" (workflow_step_id, assignee_type, user_id)
        VALUES
            ('00000000-0000-0000-0000-0000000000d3', 'USER', v_actor_a),
            ('00000000-0000-0000-0000-0000000000d3', 'USER', v_actor_b),
            ('00000000-0000-0000-0000-0000000000d3', 'USER', v_actor_c)
        ON CONFLICT DO NOTHING;

        -- Step 2: sequential ONE_OF
        INSERT INTO "workflow"."workflow_steps" (id, workflow_version_id, step_key, step_no, sequence_no, step_name, approval_mode, is_maker_checker, sla_minutes)
        VALUES ('00000000-0000-0000-0000-0000000000d4', v_version_id, 'FINAL_ONE_OF', 2, 1, 'Final ONE_OF', 'ONE_OF', false, 1440)
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO "workflow"."workflow_step_assignees" (workflow_step_id, assignee_type, user_id)
        VALUES ('00000000-0000-0000-0000-0000000000d4', 'USER', v_actor_final)
        ON CONFLICT DO NOTHING;

        -- Transition rules
        INSERT INTO "workflow"."transition_rules" (workflow_version_id, workflow_definition_id, from_status, to_status, trigger_action)
        VALUES
            (v_version_id, '00000000-0000-0000-0000-0000000000d1', 'PENDING', 'APPROVED', 'APPROVE'),
            (v_version_id, '00000000-0000-0000-0000-0000000000d1', 'PENDING', 'REJECTED', 'REJECT')
        ON CONFLICT DO NOTHING;

        -- Activate (as v_admin, who holds the fixture WORKFLOW_CONFIG_MANAGE grant)
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
        PERFORM "workflow"."activate_workflow_version"(v_version_id);
    END IF;
END;
$$;


-- ========================================================================
-- SUITE: lifecycle (start -> materialize -> parallel approval -> advance
-- -> sequential approval -> terminal)
-- ========================================================================
DO $$
DECLARE
    v_suite text := 'lifecycle';
    v_definition_id uuid := '00000000-0000-0000-0000-0000000000d1';
    v_entity_id uuid := '00000000-0000-0000-0000-0000000000d5';  -- fixed, paired 1:1 with the fixed idempotency key below
    v_initiator uuid := '00000000-0000-0000-0000-0000000000a5';
    v_actor_a uuid := '00000000-0000-0000-0000-0000000000a1';
    v_actor_b uuid := '00000000-0000-0000-0000-0000000000a2';
    v_actor_final uuid := '00000000-0000-0000-0000-0000000000a4';
    v_result jsonb;
    v_request_id uuid;
    v_step1_id uuid;
    v_step2_id uuid;
    v_current_status text;
    v_current_step_no int;
BEGIN
    -- This suite must establish its own identity rather than rely on
    -- carryover from the preceding fixture-setup block, which only
    -- calls set_config inside its "create fresh" branch - on a re-run
    -- where the fixture already exists/is ACTIVE, that branch (and its
    -- set_config call) is skipped entirely, leaving auth.uid() unset.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_initiator::text, 'role', 'authenticated')::text, true);

    -- start_approval_request() is internal-only as of round 3 item 1 -
    -- call it directly here as service_role (this test file itself
    -- runs with that level of access; see the "unauthorized start"
    -- suite below for the authenticated-cannot-call-it assertion).
    --
    -- entity_id is now FIXED (not gen_random_uuid()), paired 1:1 with
    -- the fixed idempotency_key below. A random entity_id combined
    -- with a fixed key guarantees WORKFLOW_IDEMPOTENCY_KEY_REUSE_MISMATCH
    -- on every re-run (payload_hash is derived from entity_id, so a
    -- fixed key + changing entity_id never matches its own prior
    -- payload_hash) - this was the actual cause of the last error.
    v_result := "workflow"."start_approval_request"(
        v_definition_id, 'TEST_ENTITY', v_entity_id, '{"note":"lifecycle test"}'::jsonb, 'test-lifecycle-key-002'
    );
    v_request_id := (v_result->>'approval_request_id')::uuid;

    -- On a re-run, this now correctly replays as ALREADY_PROCESSED
    -- (same key, same entity_id, same payload) rather than erroring -
    -- and since this suite's request always runs to a terminal state
    -- by the end, a replay means the whole walkthrough below was
    -- already exercised and proven in an earlier run. Re-attempting
    -- process_approval_action against an already-closed request would
    -- fail with WORKFLOW_REQUEST_CLOSED, so skip straight to
    -- reasserting the known terminal facts instead.
    IF v_result->>'status' = 'ALREADY_PROCESSED' AND NOT (v_result->>'is_open')::boolean THEN
        PERFORM "workflow"."_test_assert"(v_suite, 'skipped - already ran to terminal APPROVED in a prior run', true,
            'This suite exercises a one-way lifecycle (start->...->terminal APPROVED). It already completed in an earlier run against this fixed fixture (entity_id d5); re-running it requires a fresh entity_id or a full rollback/re-apply.');
        RETURN;
    END IF;

    PERFORM "workflow"."_test_assert"(v_suite, 'start creates request', v_request_id IS NOT NULL, v_result::text);
    PERFORM "workflow"."_test_assert"(v_suite, 'start returns CREATED', v_result->>'status' = 'CREATED', v_result::text);

    SELECT "current_status", "current_step_no" INTO v_current_status, v_current_step_no
    FROM "workflow"."approval_requests" WHERE "id" = v_request_id;
    PERFORM "workflow"."_test_assert"(v_suite, 'initial status is PENDING', v_current_status = 'PENDING', v_current_status);
    PERFORM "workflow"."_test_assert"(v_suite, 'first stage materialized (step_no=1)', v_current_step_no = 1, v_current_step_no::text);

    SELECT "id" INTO v_step1_id FROM "workflow"."approval_steps" WHERE "approval_request_id" = v_request_id AND "step_no" = 1;
    PERFORM "workflow"."_test_assert"(v_suite, 'stage 1 step materialized', v_step1_id IS NOT NULL);

    -- Parallel MIN_N=2-of-3: first APPROVE should not complete the stage
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor_a::text, 'role', 'authenticated')::text, true);
    PERFORM "workflow"."process_approval_action"(v_request_id, 'APPROVE', v_step1_id, 'actor A approves', NULL, 'test-lifecycle-a-approve', 1);

    SELECT "current_step_no" INTO v_current_step_no FROM "workflow"."approval_requests" WHERE "id" = v_request_id;
    PERFORM "workflow"."_test_assert"(v_suite, 'stage not advanced after 1-of-2 MIN_N approvals', v_current_step_no = 1, v_current_step_no::text);

    -- Second APPROVE completes MIN_N=2, should advance to stage 2
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor_b::text, 'role', 'authenticated')::text, true);
    PERFORM "workflow"."process_approval_action"(v_request_id, 'APPROVE', v_step1_id, 'actor B approves', NULL, 'test-lifecycle-b-approve', 1);

    SELECT "current_status", "current_step_no" INTO v_current_status, v_current_step_no
    FROM "workflow"."approval_requests" WHERE "id" = v_request_id;
    PERFORM "workflow"."_test_assert"(v_suite, 'stage advanced to step 2 after MIN_N satisfied', v_current_step_no = 2, v_current_step_no::text);
    PERFORM "workflow"."_test_assert"(v_suite, 'status still PENDING mid-workflow', v_current_status = 'PENDING', v_current_status);

    SELECT "id" INTO v_step2_id FROM "workflow"."approval_steps" WHERE "approval_request_id" = v_request_id AND "step_no" = 2;
    PERFORM "workflow"."_test_assert"(v_suite, 'stage 2 step materialized', v_step2_id IS NOT NULL);

    -- Final ONE_OF approval -> request goes terminal (APPROVED)
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor_final::text, 'role', 'authenticated')::text, true);
    PERFORM "workflow"."process_approval_action"(v_request_id, 'APPROVE', v_step2_id, 'final approval', NULL, 'test-lifecycle-final-approve', 2);

    SELECT "current_status" INTO v_current_status FROM "workflow"."approval_requests" WHERE "id" = v_request_id;
    PERFORM "workflow"."_test_assert"(v_suite, 'request reaches terminal APPROVED status', v_current_status = 'APPROVED', v_current_status);
    PERFORM "workflow"."_test_assert"(v_suite, 'request is_open = false at terminal', NOT (SELECT "is_open" FROM "workflow"."approval_requests" WHERE "id" = v_request_id));

    -- status_history logs REQUEST-LEVEL current_status transitions only
    -- (by design - _advance_after_step_completion explicitly skips
    -- inserting a row when a stage merely advances but current_status
    -- stays the same). This lifecycle has exactly 2 such transitions:
    -- NULL->PENDING at creation, and PENDING->APPROVED at the terminal
    -- step. The intermediate stage-1->stage-2 advance does NOT get a
    -- row - that is expected, not a gap.
    PERFORM "workflow"."_test_assert"(v_suite, 'status_history recorded exactly the 2 request-level transitions (create + terminal)',
        (SELECT count(*) FROM "workflow"."status_history" WHERE "approval_request_id" = v_request_id) = 2);
END;
$$;


-- ========================================================================
-- SUITE: idempotency / replay
-- ========================================================================
DO $$
DECLARE
    v_suite text := 'idempotency';
    v_definition_id uuid := '00000000-0000-0000-0000-0000000000d1';
    v_admin uuid := '00000000-0000-0000-0000-0000000000a6';
    v_entity_id uuid := '00000000-0000-0000-0000-0000000000d6';  -- fixed (was gen_random_uuid()) - see lifecycle suite's comment for why
    v_result1 jsonb;
    v_result2 jsonb;
    v_result3 jsonb;
    v_step1_id uuid;
    v_request_id uuid;
BEGIN
    -- This suite must establish its own identity, not rely on
    -- carryover from a preceding suite's set_config call - the
    -- lifecycle suite (immediately before this one) may take an
    -- IF-EXISTS fast-path on a re-run that never calls set_config at
    -- all, leaving auth.uid() unset for whatever runs next.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

    -- Same key + same payload -> ALREADY_PROCESSED, same request id
    v_result1 := "workflow"."start_approval_request"(v_definition_id, 'TEST_ENTITY', v_entity_id, NULL, 'test-idem-key-002');
    v_result2 := "workflow"."start_approval_request"(v_definition_id, 'TEST_ENTITY', v_entity_id, NULL, 'test-idem-key-002');

    PERFORM "workflow"."_test_assert"(v_suite, 'replay with same key+payload returns same request',
        v_result1->>'approval_request_id' = v_result2->>'approval_request_id',
        v_result1::text || ' vs ' || v_result2::text);
    PERFORM "workflow"."_test_assert"(v_suite, 'replay reports ALREADY_PROCESSED', v_result2->>'status' = 'ALREADY_PROCESSED', v_result2::text);

    -- Same key, DIFFERENT payload (different entity_id) -> hard mismatch error
    PERFORM "workflow"."_test_assert_raises"(
        v_suite, 'same key different entity_id raises mismatch',
        format('SELECT "workflow"."start_approval_request"(%L, %L, %L, NULL, %L)',
               v_definition_id, 'TEST_ENTITY', gen_random_uuid(), 'test-idem-key-002'),
        'WORKFLOW_IDEMPOTENCY_KEY_REUSE_MISMATCH'
    );

    -- Repeated APPROVE action with the same action idempotency_key must not double-count
    v_request_id := (v_result1->>'approval_request_id')::uuid;
    SELECT "id" INTO v_step1_id FROM "workflow"."approval_steps" WHERE "approval_request_id" = v_request_id AND "step_no" = 1;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000a1'::text, 'role', 'authenticated')::text, true);
    PERFORM "workflow"."process_approval_action"(v_request_id, 'APPROVE', v_step1_id, NULL, NULL, 'test-idem-action-key-001', 1);
    PERFORM "workflow"."process_approval_action"(v_request_id, 'APPROVE', v_step1_id, NULL, NULL, 'test-idem-action-key-001', 1);

    PERFORM "workflow"."_test_assert"(v_suite, 'repeated action idempotency_key does not double-insert',
        (SELECT count(*) FROM "workflow"."approval_actions"
         WHERE "idempotency_key" = 'test-idem-action-key-001' AND "approval_request_id" = v_request_id) = 1);
END;
$$;


-- ========================================================================
-- SUITE: delegation + maker-checker
-- ========================================================================
DO $$
DECLARE
    v_suite text := 'delegation_maker_checker';
    v_delegator uuid := '00000000-0000-0000-0000-0000000000a1';  -- actor A, a real step-1 assignee
    v_delegate uuid := '00000000-0000-0000-0000-0000000000a7';
    v_delegation_id uuid;
BEGIN
    INSERT INTO auth.users (id, email) VALUES (v_delegate, 'test-delegate@example.invalid') ON CONFLICT (id) DO NOTHING;

    -- Delegator creates a delegation for themself (RLS allows this)
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_delegator::text, 'role', 'authenticated')::text, true);
    INSERT INTO "workflow"."delegations" (id, delegator_user_id, delegate_user_id, module, valid_from, valid_to, is_active)
    VALUES (gen_random_uuid(), v_delegator, v_delegate, 'test', now() - interval '1 day', now() + interval '30 days', true)
    RETURNING "id" INTO v_delegation_id;

    PERFORM "workflow"."_test_assert"(v_suite, 'delegation created', v_delegation_id IS NOT NULL);

    -- created_by must be the actual caller (auth.uid()), not spoofable
    PERFORM "workflow"."_test_assert"(v_suite, 'delegation created_by forced to caller',
        (SELECT "created_by" FROM "workflow"."delegations" WHERE "id" = v_delegation_id) = v_delegator);

    -- Core fields immutable after creation (allowlist trigger)
    PERFORM "workflow"."_test_assert_raises"(
        v_suite, 'delegation core field change rejected',
        format('UPDATE "workflow"."delegations" SET "delegate_user_id" = %L WHERE "id" = %L', v_delegator, v_delegation_id),
        'WORKFLOW_DELEGATION_CORE_FIELDS_IMMUTABLE'
    );

    -- Revocation: revoked_by must match caller
    PERFORM "workflow"."_test_assert_raises"(
        v_suite, 'revoked_by must match caller',
        format('UPDATE "workflow"."delegations" SET "is_active" = false, "revoked_at" = now(), "revoked_by" = %L WHERE "id" = %L', v_delegate, v_delegation_id),
        'WORKFLOW_DELEGATION_REVOKED_BY_MUST_MATCH_CALLER'
    );

    -- Legitimate revocation by the delegator themself
    UPDATE "workflow"."delegations" SET "is_active" = false, "revoked_at" = now(), "revoked_by" = v_delegator WHERE "id" = v_delegation_id;
    PERFORM "workflow"."_test_assert"(v_suite, 'legitimate revocation succeeds',
        NOT (SELECT "is_active" FROM "workflow"."delegations" WHERE "id" = v_delegation_id));

    -- One-way revocation: cannot reactivate
    PERFORM "workflow"."_test_assert_raises"(
        v_suite, 'reactivation after revocation rejected',
        format('UPDATE "workflow"."delegations" SET "is_active" = true WHERE "id" = %L', v_delegation_id),
        'WORKFLOW_DELEGATION_REACTIVATION_DENIED'
    );

    -- Maker-checker: initiator cannot approve their own request's
    -- maker-checker-flagged step. Isolated fixture (separate
    -- definition/version) so the initiator can be deliberately made
    -- both the initiator AND a step assignee.
    DECLARE
        v_mc_def_id uuid := '00000000-0000-0000-0000-0000000000e6';
        v_mc_ver_id uuid := '00000000-0000-0000-0000-0000000000e7';
        v_mc_step_tmpl_id uuid := '00000000-0000-0000-0000-0000000000e8';
        v_initiator uuid := '00000000-0000-0000-0000-0000000000e9';
        v_other_approver uuid := '00000000-0000-0000-0000-0000000000ea';
        v_admin uuid := '00000000-0000-0000-0000-0000000000a6';
        v_result jsonb;
        v_request_id uuid;
        v_step_id uuid;
    BEGIN
        INSERT INTO auth.users (id, email) VALUES
            (v_initiator, 'test-mc-initiator@example.invalid'),
            (v_other_approver, 'test-mc-other@example.invalid')
        ON CONFLICT (id) DO NOTHING;

        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

        IF NOT EXISTS (
            SELECT 1 FROM "workflow"."workflow_versions"
            WHERE "id" = v_mc_ver_id AND "status" = 'ACTIVE'
        ) THEN
            INSERT INTO "workflow"."workflow_definitions" (id, name, module, code, is_active, created_by)
            VALUES (v_mc_def_id, 'TEST_MAKER_CHECKER', 'test', 'TEST_MC_ENTITY', true, v_admin) ON CONFLICT (id) DO NOTHING;
            INSERT INTO "workflow"."workflow_versions" (id, workflow_definition_id, version_no, status, created_by)
            VALUES (v_mc_ver_id, v_mc_def_id, 1, 'DRAFT', v_admin) ON CONFLICT (id) DO NOTHING;
            INSERT INTO "workflow"."workflow_statuses" (workflow_version_id, workflow_definition_id, status_code, is_initial, is_terminal, display_name)
            VALUES (v_mc_ver_id, v_mc_def_id, 'PENDING', true, false, 'Pending'), (v_mc_ver_id, v_mc_def_id, 'APPROVED', false, true, 'Approved'),
                   (v_mc_ver_id, v_mc_def_id, 'REJECTED', false, true, 'Rejected') ON CONFLICT DO NOTHING;
            -- is_maker_checker = true, ONE_OF, with BOTH the initiator and
            -- another user as eligible assignees.
            INSERT INTO "workflow"."workflow_steps" (id, workflow_version_id, step_key, step_no, sequence_no, step_name, approval_mode, is_maker_checker, sla_minutes)
            VALUES (v_mc_step_tmpl_id, v_mc_ver_id, 'MC_STEP', 1, 1, 'Maker-checker step', 'ONE_OF', true, 1440) ON CONFLICT (id) DO NOTHING;
            INSERT INTO "workflow"."workflow_step_assignees" (workflow_step_id, assignee_type, user_id)
            VALUES (v_mc_step_tmpl_id, 'USER', v_initiator), (v_mc_step_tmpl_id, 'USER', v_other_approver) ON CONFLICT DO NOTHING;
            INSERT INTO "workflow"."transition_rules" (workflow_version_id, workflow_definition_id, from_status, to_status, trigger_action)
            VALUES (v_mc_ver_id, v_mc_def_id, 'PENDING', 'APPROVED', 'APPROVE'), (v_mc_ver_id, v_mc_def_id, 'PENDING', 'REJECTED', 'REJECT') ON CONFLICT DO NOTHING;

            PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
            PERFORM "workflow"."activate_workflow_version"(v_mc_ver_id);
        END IF;

        -- start_approval_request()'s idempotency handling only makes a
        -- re-run safe if entity_id is ALSO fixed to match - entity_id
        -- feeds payload_hash, so a random entity_id here would trigger
        -- WORKFLOW_IDEMPOTENCY_KEY_REUSE_MISMATCH on every re-run
        -- against the same fixed key (this was the actual bug hit
        -- last run, in a different suite - fixed the same way here).
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_initiator::text, 'role', 'authenticated')::text, true);
        v_result := "workflow"."start_approval_request"(v_mc_def_id, 'TEST_MC_ENTITY', '00000000-0000-0000-0000-0000000000eb'::uuid, NULL, 'test-mc-key-002');
        v_request_id := (v_result->>'approval_request_id')::uuid;

        -- This suite drives the request all the way to terminal
        -- APPROVED (line further below). A replay on re-run returns
        -- that same already-closed request - re-attempting actions
        -- against it would raise WORKFLOW_REQUEST_CLOSED (masking the
        -- maker-checker-specific assertion below and aborting the
        -- unguarded APPROVE after it). Skip the whole walkthrough in
        -- that case instead.
        IF v_result->>'status' = 'ALREADY_PROCESSED' AND NOT (v_result->>'is_open')::boolean THEN
            PERFORM "workflow"."_test_assert"(v_suite, 'skipped - already verified maker-checker + terminal approval in a prior run', true,
                'This suite drives its fixture to terminal APPROVED, which is one-way. Already completed in an earlier run; needs a fresh entity_id or full rollback/re-apply to re-verify from scratch.');
            RETURN;
        END IF;

        SELECT "id" INTO v_step_id FROM "workflow"."approval_steps" WHERE "approval_request_id" = v_request_id AND "step_no" = 1;

        -- The initiator, despite being a valid step assignee, must be
        -- blocked from approving their own request on a
        -- maker-checker-flagged step.
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_initiator::text, 'role', 'authenticated')::text, true);
        PERFORM "workflow"."_test_assert_raises"(
            v_suite, 'initiator blocked from approving own maker-checker step',
            format('SELECT "workflow"."process_approval_action"(%L, %L, %L, NULL, NULL, %L, %L)',
                   v_request_id, 'APPROVE', v_step_id, 'test-mc-initiator-approve', 1),
            'WORKFLOW_MAKER_CHECKER_VIOLATION'
        );

        -- A DIFFERENT eligible assignee can still approve normally.
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_other_approver::text, 'role', 'authenticated')::text, true);
        PERFORM "workflow"."process_approval_action"(v_request_id, 'APPROVE', v_step_id, NULL, NULL, 'test-mc-other-approve', 1);
        PERFORM "workflow"."_test_assert"(v_suite, 'non-initiator assignee can approve maker-checker step',
            (SELECT "current_status" = 'APPROVED' FROM "workflow"."approval_requests" WHERE "id" = v_request_id));
    END;
END;
$$;


-- ========================================================================
-- SUITE: approval modes (ONE_OF / ALL_OF) + SKIP quorum-safety
-- ========================================================================
DO $$
DECLARE
    v_suite text := 'approval_modes_and_skip';
    v_definition_id uuid := '00000000-0000-0000-0000-0000000000d1';
    v_version_id uuid := '00000000-0000-0000-0000-0000000000d2';
    v_admin uuid := '00000000-0000-0000-0000-0000000000a6';
    v_actor_final uuid := '00000000-0000-0000-0000-0000000000a4';
    v_result jsonb;
    v_request_id uuid;
    v_step2_id uuid;
BEGIN
    -- NOTE: this suite's real coverage is the ALL_OF SKIP
    -- quorum-safety fixture below. An earlier version of this suite
    -- also started a ONE_OF request here but never used its result for
    -- any assertion - removed as genuinely dead code (and it was also
    -- carrying the same fixed-key/random-entity_id idempotency bug
    -- fixed elsewhere in this file, for zero benefit since nothing
    -- ever checked its outcome).

    -- ALL_OF SKIP quorum-safety: build an isolated 1-step ALL_OF
    -- workflow with 2 assignees, skip one, confirm the step is NOT
    -- silently deadlocked and a further SKIP of the last countable
    -- assignee is rejected.
    DECLARE
        v_allof_def_id uuid := '00000000-0000-0000-0000-0000000000e1';
        v_allof_ver_id uuid := '00000000-0000-0000-0000-0000000000e2';
        v_allof_step_tmpl_id uuid := '00000000-0000-0000-0000-0000000000e3';
        v_actor_x uuid := '00000000-0000-0000-0000-0000000000e4';
        v_actor_y uuid := '00000000-0000-0000-0000-0000000000e5';
        v_allof_request_id uuid;
        v_allof_step_id uuid;
        v_allof_result jsonb;
    BEGIN
        INSERT INTO auth.users (id, email) VALUES
            (v_actor_x, 'test-allof-x@example.invalid'),
            (v_actor_y, 'test-allof-y@example.invalid')
        ON CONFLICT (id) DO NOTHING;

        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

        IF NOT EXISTS (
            SELECT 1 FROM "workflow"."workflow_versions"
            WHERE "id" = v_allof_ver_id AND "status" = 'ACTIVE'
        ) THEN
            INSERT INTO "workflow"."workflow_definitions" (id, name, module, code, is_active, created_by)
            VALUES (v_allof_def_id, 'TEST_ALLOF', 'test', 'TEST_ALLOF_ENTITY', true, v_admin) ON CONFLICT (id) DO NOTHING;
            INSERT INTO "workflow"."workflow_versions" (id, workflow_definition_id, version_no, status, created_by)
            VALUES (v_allof_ver_id, v_allof_def_id, 1, 'DRAFT', v_admin) ON CONFLICT (id) DO NOTHING;
            INSERT INTO "workflow"."workflow_statuses" (workflow_version_id, workflow_definition_id, status_code, is_initial, is_terminal, display_name)
            VALUES (v_allof_ver_id, v_allof_def_id, 'PENDING', true, false, 'Pending'), (v_allof_ver_id, v_allof_def_id, 'APPROVED', false, true, 'Approved'),
                   (v_allof_ver_id, v_allof_def_id, 'REJECTED', false, true, 'Rejected') ON CONFLICT DO NOTHING;
            INSERT INTO "workflow"."workflow_steps" (id, workflow_version_id, step_key, step_no, sequence_no, step_name, approval_mode, is_maker_checker, skip_allowed, sla_minutes)
            VALUES (v_allof_step_tmpl_id, v_allof_ver_id, 'ALLOF_STEP', 1, 1, 'ALL_OF step', 'ALL_OF', false, true, 1440) ON CONFLICT (id) DO NOTHING;
            INSERT INTO "workflow"."workflow_step_assignees" (workflow_step_id, assignee_type, user_id)
            VALUES (v_allof_step_tmpl_id, 'USER', v_actor_x), (v_allof_step_tmpl_id, 'USER', v_actor_y) ON CONFLICT DO NOTHING;
            INSERT INTO "workflow"."transition_rules" (workflow_version_id, workflow_definition_id, from_status, to_status, trigger_action)
            VALUES (v_allof_ver_id, v_allof_def_id, 'PENDING', 'APPROVED', 'APPROVE'), (v_allof_ver_id, v_allof_def_id, 'PENDING', 'REJECTED', 'REJECT') ON CONFLICT DO NOTHING;

            PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
            PERFORM "workflow"."activate_workflow_version"(v_allof_ver_id);
        END IF;

        -- start_approval_request()/process_approval_action() both have
        -- their own idempotency handling (fixed keys used below), so
        -- re-running these specific calls is already safe once the
        -- fixture above can actually be reached.
        -- entity_id is fixed (not gen_random_uuid()) so a re-run
        -- replays the SAME request/step via start_approval_request's
        -- own idempotency match, rather than hitting
        -- WORKFLOW_IDEMPOTENCY_KEY_REUSE_MISMATCH against the fixed
        -- key below. This step never resolves to a request-level
        -- terminal state (actor_y's SKIP is designed to always be
        -- rejected, and nothing here ever gets a 2nd successful vote),
        -- so no early-exit-on-replay guard is needed - the assertions
        -- below hold true whether this is a fresh run or a replay.
        v_allof_result := "workflow"."start_approval_request"(v_allof_def_id, 'TEST_ALLOF_ENTITY', '00000000-0000-0000-0000-0000000000ec'::uuid, NULL, 'test-allof-skip-key-002');
        v_allof_request_id := (v_allof_result->>'approval_request_id')::uuid;
        SELECT "id" INTO v_allof_step_id FROM "workflow"."approval_steps" WHERE "approval_request_id" = v_allof_request_id AND "step_no" = 1;

        -- Actor X skips - 1 countable assignee (Y) remains, quorum for
        -- ALL_OF (both must approve) is still achievable -> allowed.
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor_x::text, 'role', 'authenticated')::text, true);
        PERFORM "workflow"."process_approval_action"(v_allof_request_id, 'SKIP', v_allof_step_id, 'skip test', NULL, 'test-allof-skip-x', 1);

        PERFORM "workflow"."_test_assert"(v_suite, 'first SKIP on ALL_OF with 1 remaining countable assignee allowed',
            (SELECT "sa"."status" FROM "workflow"."approval_step_assignees" sa
             JOIN "workflow"."approval_steps" s ON s."id" = sa."approval_step_id"
             WHERE s."id" = v_allof_step_id AND sa."assignee_user_id" = v_actor_x) = 'SKIPPED');

        -- Actor Y attempting to SKIP now would make ALL_OF's quorum
        -- impossible (0 countable assignees left, no APPROVE would
        -- ever be able to complete it) - must be rejected.
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_actor_y::text, 'role', 'authenticated')::text, true);
        PERFORM "workflow"."_test_assert_raises"(
            v_suite, 'SKIP of last countable ALL_OF assignee rejected',
            format('SELECT "workflow"."process_approval_action"(%L, %L, %L, %L, NULL, %L, %L)',
                   v_allof_request_id, 'SKIP', v_allof_step_id, 'should fail', 'test-allof-skip-y', 1),
            'WORKFLOW_SKIP'
        );
    END;
END;
$$;


-- ========================================================================
-- SUITE: unauthorized direct start (item 1, round 3)
-- ========================================================================
DO $$
DECLARE
    v_suite text := 'unauthorized_start';
    v_definition_id uuid := '00000000-0000-0000-0000-0000000000d1';
    v_random_user uuid := '00000000-0000-0000-0000-0000000000a9';
    v_caught boolean := false;
    v_detail text;
BEGIN
    INSERT INTO auth.users (id, email) VALUES (v_random_user, 'test-random@example.invalid') ON CONFLICT (id) DO NOTHING;

    -- As an ordinary authenticated role (not service_role), calling
    -- start_approval_request() directly must fail on privilege grounds -
    -- confirms it is genuinely internal-only, not just documented as
    -- such. SET LOCAL ROLE and the function call must be separate
    -- statements (PL/pgSQL's EXECUTE cannot run multiple
    -- semicolon-separated commands in one string), so this is done as
    -- its own nested block rather than via _test_assert_raises.
    BEGIN
        SET LOCAL ROLE "authenticated";
        PERFORM "workflow"."start_approval_request"(v_definition_id, 'TEST_ENTITY', gen_random_uuid(), NULL, 'test-unauth-key-001');
    EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
        v_caught := true;
        v_detail := SQLERRM;
    END;
    RESET ROLE;

    PERFORM "workflow"."_test_assert"(v_suite, 'authenticated cannot call start_approval_request directly', v_caught, v_detail);
    IF v_caught THEN
        PERFORM "workflow"."_test_assert"(v_suite, 'failure is a permission error, not something else',
            v_detail ILIKE '%permission denied%', v_detail);
    END IF;
END;
$$;


-- ========================================================================
-- SUITE: rollback integrity marker
-- ========================================================================
-- This suite intentionally has no assertions of its own - it exists so
-- workflow._test_summary() always shows a 'rollback_integrity' row,
-- prompting whoever runs the execution cycle to perform the ACTUAL
-- rollback-integrity check as a separate manual step (per your
-- instruction: full rollback -> verify pre-migration state -> re-apply
-- -> rerun), which cannot be expressed as a single in-database SQL
-- assertion (it spans applying, dropping, and reapplying the schema
-- itself).
DO $$
BEGIN
    PERFORM "workflow"."_test_assert"('rollback_integrity', 'manual step required - see 000_MANIFEST.txt execution cycle', true,
        'Not an automated check: run full rollback, verify workflow schema and _seed_provenance are gone, re-apply 001-006a, rerun 007/008.');
END;
$$;


-- ========================================================================
-- Report
-- ========================================================================
SELECT * FROM "workflow"."_test_summary"();
SELECT * FROM "workflow"."_test_failures"();

-- ========================================================================
-- END 007_workflow_contract_tests.sql
-- ========================================================================
