-- ========================================================================
-- 006_backfill_people_and_links.sql
-- Phase 7: Backfill core.people / core.person_user_links / hr.employees
-- for every eligible auth.users id currently referenced live.
--
-- REVISION 3 - team lead's follow-up review: Step 0 in Revision 2 was
-- only a SELECT a human had to eyeball ("expect zero rows"), not an
-- actual guard - it would not have stopped Step 2/3 from running even
-- if it returned collisions. This revision makes it a true fail-fast:
-- a DO block that RAISEs EXCEPTION and aborts, wrapped together with
-- every other write in this script inside one explicit BEGIN...COMMIT
-- transaction, so a collision guarantees NOTHING in this script commits
-- - not the role grant, not the temp table, nothing.
--
-- REVISION 2 - corrects an identity-integrity issue the team lead
-- flagged on review: the original version linked a backfilled user to
-- a core.people row purely by matching lower(primary_email), which is
-- NOT deterministic - if any pre-existing core.people row happened to
-- share an email with a backfill-eligible user for any reason (typo,
-- a recycled address, an unrelated coincidence), that user would have
-- been silently attached to the WRONG person record. This revision
-- removes email-based association from the backfill entirely: every
-- eligible auth.users.id now gets its own core.people row created and
-- linked in the SAME transaction, by construction, using the id
-- returned from its own INSERT - never re-matched by any other field
-- afterward. A pre-flight check (Step 0 below) also hard-stops the
-- whole script if it finds two distinct eligible users sharing a
-- non-null email, rather than assuming that can't happen.
--
-- Email-based matching by verified email is still exactly right for
-- core.provision_person_for_user() (003) - that's a live, per-signup
-- reconciliation against a specific known HR-pre-created CANDIDATE
-- record, gated behind an email-confirmation check, one user at a
-- time. This is a one-time bulk backfill script with no such per-row
-- verification step available, which is exactly why it should not
-- rely on the same mechanism - different context, different risk
-- profile, corrected here accordingly rather than assumed equivalent.
--
-- NOT a bare migration - run as ONE complete paste in the Supabase SQL
-- Editor, as a real logged-in admin session (LOCAL_TEST_ADMIN:
-- 2d48e4e3-fee2-4034-8b8d-a3cce8298ce2 - the same account already used
-- to bootstrap every prior module), same actor-integrity constraint as
-- 006_asset_categories_seed.sql / TEST_bootstrap_*.sql.
--
-- Wrapped in an explicit BEGIN...COMMIT below (this revision) rather
-- than relying on the SQL Editor's implicit per-paste transaction
-- behavior - guarantees Step 0's RAISE EXCEPTION rolls back
-- EVERYTHING in this script atomically, including the role grant and
-- the temp table, not just "the rest of the statements happen to not
-- run." set_config(..., true) is transaction-LOCAL, which is exactly
-- why it has to be inside this same explicit transaction, not before it.
--
-- CONFIRMED BACKFILL-ELIGIBILITY RULE (team lead's first review-reply,
-- unchanged by this revision):
-- an auth.users.id qualifies for a core.people / hr.employees row ONLY
-- IF it appears as employee_id in at least one of the 9 tables below -
-- the one unambiguous "this is a real employee" business signal
-- available in the live data. An id that appears only as
-- created_by/updated_by/approved_by (an audit/actor column, never as
-- employee_id) is explicitly EXCLUDED - it gets no row here.
--
-- Verified against actual applied migrations before writing this query:
--   - LOCAL_TEST_ADMIN (2d48e4e3-...) never appears as employee_id
--     anywhere - only as approver/actor. Correctly excluded.
--   - The Leave/Attendance placeholder approver
--     (00000000-0000-0000-0000-0000000000a6) is a non-loggable test
--     fixture, not a real auth.users row - excluded by the INNER JOIN
--     to auth.users below regardless.
--   - The test employee (ed761a27-783e-43d2-8fcd-ac2f64b29249) DOES
--     appear as employee_id in Attendance/Assets/Contracts test data -
--     correctly included.
--
-- Idempotent: safe to re-run. Every write below is guarded against
-- reprocessing a user_id that already has an ACTIVE link.
-- ========================================================================

BEGIN;

-- Run as LOCAL_TEST_ADMIN. is_local=true (transaction-scoped) - must be
-- inside this same explicit transaction, not before it.
SELECT set_config('request.jwt.claims', json_build_object('sub', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'role', 'authenticated')::text, true);

-- Grant PEOPLE_MANAGE to the LOCAL_TEST_ADMIN role so this session's
-- inserts pass core.people / core.person_user_links / hr.employees RLS
-- (same pattern as TEST_bootstrap_assets_workflow.sql granting
-- ASSET_MANAGE before its seed inserts).
DO $$
DECLARE
    v_role_id uuid;
    v_permission_id uuid;
BEGIN
    SELECT "id" INTO v_role_id FROM "core"."roles" WHERE "name" = 'LOCAL_TEST_ADMIN';
    IF v_role_id IS NULL THEN
        RAISE EXCEPTION 'LOCAL_TEST_ADMIN role not found - check core.roles for the exact name before re-running';
    END IF;

    SELECT "id" INTO v_permission_id FROM "core"."permissions" WHERE "code" = 'PEOPLE_MANAGE';
    IF v_permission_id IS NULL THEN
        RAISE EXCEPTION 'PEOPLE_MANAGE permission not found - run 005_people_org_permissions_seed.sql first';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "core"."role_permissions" WHERE "role_id" = v_role_id AND "permission_id" = v_permission_id) THEN
        INSERT INTO "core"."role_permissions" ("role_id", "permission_id") VALUES (v_role_id, v_permission_id);
        RAISE NOTICE 'Granted PEOPLE_MANAGE to LOCAL_TEST_ADMIN role';
    ELSE
        RAISE NOTICE 'LOCAL_TEST_ADMIN already has PEOPLE_MANAGE - left unchanged';
    END IF;
END;
$$;

-- ------------------------------------------------------------------------
-- Step 1: the eligible-id set - distinct employee_id across all 9
-- tables, inner-joined to auth.users so any id with no live account
-- (e.g. a stale test fixture) is dropped automatically. ID-based, not
-- email-based - unaffected by this revision.
-- ------------------------------------------------------------------------
CREATE TEMP TABLE "_backfill_eligible_users" AS
SELECT DISTINCT u."id" AS "user_id", u."email"
FROM "auth"."users" u
WHERE u."id" IN (
    SELECT "employee_id" FROM "leave"."leave_requests"
    UNION SELECT "employee_id" FROM "leave"."leave_ledger"
    UNION SELECT "employee_id" FROM "leave"."leave_accruals"
    UNION SELECT "employee_id" FROM "leave"."leave_adjustments"
    UNION SELECT "employee_id" FROM "attendance"."attendance_days"
    UNION SELECT "employee_id" FROM "attendance"."correction_requests"
    UNION SELECT "employee_id" FROM "assets"."asset_requests"
    UNION SELECT "employee_id" FROM "assets"."asset_assignments"
    UNION SELECT "employee_id" FROM "hr"."contracts"
);

-- Sanity check before writing anything - report the set before it's used.
SELECT count(*) AS "eligible_user_count" FROM "_backfill_eligible_users";

-- ------------------------------------------------------------------------
-- Step 0 (true fail-fast guard, not just an eyeballed query): hard-stop
-- if any two DISTINCT eligible users share a non-null email. This
-- RAISEs and ABORTS the entire script transactionally - Step 2/3 below
-- physically cannot execute if this fires, regardless of whether the
-- earlier SELECT-only version's "expect zero rows" comment was actually
-- read. This is the correction the team lead asked for.
-- ------------------------------------------------------------------------
DO $$
DECLARE
    v_collision record;
    v_collision_count int := 0;
    v_collision_summary text := '';
BEGIN
    FOR v_collision IN
        SELECT "email", array_agg("user_id") AS "colliding_user_ids", count(*) AS "n"
        FROM "_backfill_eligible_users"
        WHERE "email" IS NOT NULL
        GROUP BY "email"
        HAVING count(*) > 1
    LOOP
        v_collision_count := v_collision_count + 1;
        v_collision_summary := v_collision_summary || format('email=%s user_ids=%s; ', v_collision."email", v_collision."colliding_user_ids");
    END LOOP;

    IF v_collision_count > 0 THEN
        RAISE EXCEPTION 'BACKFILL_EMAIL_COLLISION_ABORT: % distinct email(s) shared by more than one eligible user - refusing to proceed. Manual review required before re-running this script. Details: %',
            v_collision_count, v_collision_summary;
    END IF;

    RAISE NOTICE 'Step 0 passed: no email collisions among % eligible users.', (SELECT count(*) FROM "_backfill_eligible_users");
END;
$$;

-- ------------------------------------------------------------------------
-- Step 2: create + link, one eligible user at a time, in a single loop
-- so the INSERT ... RETURNING id and its matching person_user_links
-- row are always the SAME transaction operating on a captured
-- variable - never re-derived by matching any other column afterward.
-- This is the actual correction: no core.people lookup by email
-- anywhere in this step. Skips any user_id that already has an ACTIVE
-- link (idempotent re-run safety, and covers the case where a signup
-- already ran through 003's RPC before this backfill executes).
-- ------------------------------------------------------------------------
DO $$
DECLARE
    v_user record;
    v_organization_id uuid;
    v_person_id uuid;
BEGIN
    SELECT "id" INTO v_organization_id FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    IF v_organization_id IS NULL THEN
        RAISE EXCEPTION 'BACKFILL_OSYSTIC_ORG_MISSING: seeded OSYSTIC organization row not found';
    END IF;

    FOR v_user IN SELECT "user_id", "email" FROM "_backfill_eligible_users" LOOP
        IF EXISTS (
            SELECT 1 FROM "core"."person_user_links"
            WHERE "user_id" = v_user."user_id" AND "status" = 'ACTIVE'
        ) THEN
            CONTINUE;  -- already linked (e.g. via 003's RPC before this ran) - skip, do not touch
        END IF;

        -- full_name placeholder is the user's email, same placeholder
        -- logic as 003's RPC uses for a fresh signup - flagged there,
        -- not repeated here as a new decision, just applied
        -- consistently. One fresh core.people row per eligible
        -- user_id, unconditionally - no reuse of any pre-existing
        -- person row by email match.
        INSERT INTO "core"."people" ("organization_id", "full_name", "primary_email", "person_type", "status")
        VALUES (v_organization_id, COALESCE(v_user."email", 'Unnamed'), v_user."email", 'EMPLOYEE', 'ACTIVE')
        RETURNING "id" INTO v_person_id;

        INSERT INTO "core"."person_user_links" ("person_id", "user_id", "status")
        VALUES (v_person_id, v_user."user_id", 'ACTIVE');
    END LOOP;
END;
$$;

-- ------------------------------------------------------------------------
-- Step 3: hr.employees - one row per eligible user now linked.
-- employee_number left NULL - no source of real employee numbers
-- exists in the live data to backfill from; a real value needs a
-- manual HR data-entry pass same as full_name (v2 S7).
-- hire_date/termination_date also left NULL for the same reason -
-- nothing upstream supplies them. ID-based join throughout, unaffected
-- by this revision.
-- ------------------------------------------------------------------------
INSERT INTO "hr"."employees" ("person_id", "employment_status")
SELECT DISTINCT p."id", 'ACTIVE'::"hr"."employment_status"
FROM "_backfill_eligible_users" beu
JOIN "core"."person_user_links" pul ON pul."user_id" = beu."user_id" AND pul."status" = 'ACTIVE'
JOIN "core"."people" p ON p."id" = pul."person_id"
WHERE NOT EXISTS (
    SELECT 1 FROM "hr"."employees" e WHERE e."person_id" = p."id"
);

DROP TABLE "_backfill_eligible_users";

COMMIT;

-- ========================================================================
-- END 006_backfill_people_and_links.sql
-- ========================================================================
