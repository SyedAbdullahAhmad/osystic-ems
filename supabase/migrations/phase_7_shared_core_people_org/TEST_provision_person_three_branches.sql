-- Run as ONE complete paste in the Supabase SQL Editor.
-- 010 Check 4: exercises core.provision_person_for_user()'s three
-- action_taken branches directly. Uses '00000000-0000-0000-0000-
-- 0000000000a9' (test-random@example.invalid) - a REAL, existing,
-- unlinked auth.users fixture row already present in this project
-- (confirmed via a live query before picking it - a fabricated id was
-- tried first and rejected by core.people's created_by -> auth.users
-- foreign key, since the trigger sets created_by to auth.uid() and
-- that FK requires a real row).

-- Results are written to a temp table and SELECTed at the end, so they
-- show up in the normal query-results grid rather than the harder-to-
-- find Notices/Logs panel.

DROP TABLE IF EXISTS "_check4_results";
CREATE TEMP TABLE "_check4_results" (
    "step" text,
    "expected_action" text,
    "actual_person_id" uuid,
    "actual_action_taken" text,
    "row_updated_at_changed" boolean
);

DO $$
DECLARE
    v_fake_user_id uuid := '00000000-0000-0000-0000-0000000000a9';
    v_result_1 record;
    v_result_2 record;
    v_result_3 record;
    v_updated_at_before timestamptz;
    v_updated_at_after timestamptz;
BEGIN
    -- ---- Step 1: brand-new session, first call ----
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_id, 'role', 'authenticated')::text, true);
    SELECT * INTO v_result_1 FROM "core"."provision_person_for_user"();
    INSERT INTO "_check4_results" VALUES ('1', 'CREATED_NEW_PERSON', v_result_1."person_id", v_result_1."action_taken", NULL);

    -- ---- Step 2: SAME session, call again (idempotent re-call) ----
    SELECT * INTO v_result_2 FROM "core"."provision_person_for_user"();
    INSERT INTO "_check4_results" VALUES ('2', 'ALREADY_LINKED', v_result_2."person_id", v_result_2."action_taken", NULL);

    IF v_result_2."person_id" != v_result_1."person_id" THEN
        RAISE EXCEPTION 'MISMATCH: step 2 returned a different person_id than step 1 - % vs %', v_result_2."person_id", v_result_1."person_id";
    END IF;

    -- ---- Step 3: switch to LOCAL_TEST_ADMIN (PEOPLE_MANAGE), revoke the link ----
    SELECT "updated_at" INTO v_updated_at_before FROM "core"."person_user_links" WHERE "person_id" = v_result_1."person_id" AND "user_id" = v_fake_user_id;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'role', 'authenticated')::text, true);
    UPDATE "core"."person_user_links"
    SET "status" = 'REVOKED'
    WHERE "person_id" = v_result_1."person_id" AND "user_id" = v_fake_user_id AND "status" = 'ACTIVE';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'STEP 3 FAILED: the revoke UPDATE matched zero rows - person_id=%, user_id=% was not ACTIVE as expected', v_result_1."person_id", v_fake_user_id;
    END IF;

    SELECT "updated_at" INTO v_updated_at_after FROM "core"."person_user_links" WHERE "person_id" = v_result_1."person_id" AND "user_id" = v_fake_user_id;
    INSERT INTO "_check4_results" VALUES ('3-revoke', 'REVOKED', v_result_1."person_id", 'n/a - direct UPDATE, not the RPC', (v_updated_at_after IS DISTINCT FROM v_updated_at_before));

    -- ---- Step 4: SAME fake session calls again after revoke ----
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_fake_user_id, 'role', 'authenticated')::text, true);
    SELECT * INTO v_result_3 FROM "core"."provision_person_for_user"();
    INSERT INTO "_check4_results" VALUES ('4', 'REACTIVATED_SAME_LOGIN', v_result_3."person_id", v_result_3."action_taken", NULL);

    IF v_result_3."person_id" != v_result_1."person_id" THEN
        RAISE EXCEPTION 'MISMATCH: step 4 returned a different person_id than step 1 - % vs %', v_result_3."person_id", v_result_1."person_id";
    END IF;

    IF v_result_3."action_taken" != 'REACTIVATED_SAME_LOGIN' THEN
        RAISE EXCEPTION 'STEP 4 WRONG BRANCH: expected action_taken=REACTIVATED_SAME_LOGIN but got % - the revoke in step 3 likely did not take effect', v_result_3."action_taken";
    END IF;
END;
$$;

-- The actual evidence - every row's actual_action_taken should match
-- its expected_action exactly, and row_updated_at_changed on the
-- 3-revoke row should be true (proves the UPDATE really changed the
-- row, using a before/after comparison within the same transaction,
-- not relying on now() which is constant for the whole transaction).
SELECT * FROM "_check4_results" ORDER BY "step";
