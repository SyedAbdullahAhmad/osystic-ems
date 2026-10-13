-- ========================================================================
-- TEST_onboarding_view_all_TEMP_GRANT.sql
-- Evidence script for ONBOARDING_VIEW_ALL (Shawaiz: production mapping to
-- the CEO/Executive role is pending the exact existing role name/ID; this
-- proves the positive case with a TEMPORARY scratch role, then revokes
-- ONLY what this script created, by captured id).
--
-- Run as ONE paste. Safe on failure: if anything raises, the whole script
-- rolls back and nothing is left behind. Do not run in production.
--
-- Viewer  = 00000000-...-0000000000fa (test-outsider@example.invalid)
-- Other   = chosen dynamically in SETUP: the first @example.invalid fixture
--           user (not the viewer) with no active role, no onboarding
--           permission and no ACTIVE person link. (test-random@... was
--           rejected: it has a legitimate ACTIVE link from the shared-core
--           phase, which would let it see its own record.)
-- ========================================================================
DROP TABLE IF EXISTS "_va_results";
CREATE TEMP TABLE "_va_results" ("step" text, "result" text);
GRANT ALL ON "_va_results" TO "authenticated";
DROP TABLE IF EXISTS "_va_ids";
CREATE TEMP TABLE "_va_ids" ("key" text PRIMARY KEY, "value" text);
GRANT ALL ON "_va_ids" TO "authenticated";

-- SETUP (privileged): preconditions, then the temporary grant ------------
DO $$
DECLARE
    v_viewer uuid := '00000000-0000-0000-0000-0000000000fa';
    v_other  uuid;
    v_perm uuid; v_role uuid; v_rp uuid; v_ur uuid; v_total int;
BEGIN
    SELECT "id" INTO v_perm FROM "core"."permissions" WHERE "code" = 'ONBOARDING_VIEW_ALL';
    IF v_perm IS NULL THEN RAISE EXCEPTION 'SETUP: permission ONBOARDING_VIEW_ALL does not exist'; END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_viewer) THEN
        RAISE EXCEPTION 'SETUP: viewer fixture user missing from auth.users';
    END IF;
    SELECT u.id INTO v_other
    FROM auth.users u
    WHERE u.email LIKE '%@example.invalid'
      AND u.id <> v_viewer
      AND NOT EXISTS (SELECT 1 FROM core.user_roles ur WHERE ur.user_id = u.id AND ur.is_active)
      AND NOT EXISTS (SELECT 1 FROM core.person_user_links l WHERE l.user_id = u.id AND l.status = 'ACTIVE')
      AND NOT core.has_permission(u.id, 'ONBOARDING_MANAGE')
      AND NOT core.has_permission(u.id, 'ONBOARDING_VIEW_ALL')
    ORDER BY u.id
    LIMIT 1;
    IF v_other IS NULL THEN
        RAISE EXCEPTION 'SETUP: no clean fixture user (no role, no ACTIVE link) available for the negative case';
    END IF;
    IF core.has_permission(v_viewer,'ONBOARDING_MANAGE') OR core.has_permission(v_viewer,'ONBOARDING_VIEW_ALL') THEN
        RAISE EXCEPTION 'SETUP: the viewer already holds an onboarding permission - the test would not be clean';
    END IF;
    IF EXISTS (SELECT 1 FROM core.person_user_links WHERE user_id = v_viewer AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'SETUP: the viewer has an ACTIVE person link - self-view would mask the result';
    END IF;
    IF EXISTS (SELECT 1 FROM core.roles WHERE name = 'TEMP_TEST_ONBOARDING_VIEW_ALL') THEN
        RAISE EXCEPTION 'SETUP: leftover TEMP_TEST_ONBOARDING_VIEW_ALL role exists - investigate manually';
    END IF;
    SELECT count(*) INTO v_total FROM onboarding.onboarding_records;
    IF v_total = 0 THEN RAISE EXCEPTION 'SETUP: no onboarding records exist to view'; END IF;

    INSERT INTO core.roles (name, display_name, description)
    VALUES ('TEMP_TEST_ONBOARDING_VIEW_ALL', 'TEMP test view-all', 'TEMPORARY scratch role for ONBOARDING_VIEW_ALL evidence - revoked by the same script')
    RETURNING id INTO v_role;
    INSERT INTO core.role_permissions (role_id, permission_id) VALUES (v_role, v_perm) RETURNING id INTO v_rp;
    INSERT INTO core.user_roles (user_id, role_id) VALUES (v_viewer, v_role) RETURNING id INTO v_ur;

    INSERT INTO "_va_ids" VALUES ('role_id', v_role::text), ('rp_id', v_rp::text), ('ur_id', v_ur::text), ('total', v_total::text), ('other_id', v_other::text);
    INSERT INTO "_va_results" VALUES ('0-setup', 'temporary role granted ONBOARDING_VIEW_ALL (and nothing else) to the viewer; total onboarding_records=' || v_total::text || '; negative-case user=' || (SELECT email FROM auth.users WHERE id = v_other));
END;
$$;

-- POSITIVE + read-only checks (as the viewer) ---------------------------
SET ROLE "authenticated";
DO $$
DECLARE
    v_viewer uuid := '00000000-0000-0000-0000-0000000000fa';
    v_total int := (SELECT "value"::int FROM "_va_ids" WHERE "key" = 'total');
    v_seen int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer::text, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_seen FROM onboarding.onboarding_records;
    INSERT INTO "_va_results" VALUES ('1-viewall-positive',
        CASE WHEN v_seen = v_total THEN 'PASS: ONBOARDING_VIEW_ALL holder (no MANAGE, no link) sees all ' || v_seen::text || ' records'
             ELSE 'FAIL: sees ' || v_seen::text || ' of ' || v_total::text END);

    BEGIN
        UPDATE onboarding.onboarding_records SET status = status;
        INSERT INTO "_va_results" VALUES ('2-viewall-cannot-write-raw', 'FAIL: raw UPDATE succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_va_results" VALUES ('2-viewall-cannot-write-raw',
            CASE WHEN SQLSTATE = '42501' THEN 'PASS: raw write denied, SQLSTATE 42501'
                 ELSE 'FAIL: wrong error ' || SQLSTATE || ': ' || SQLERRM END);
    END;

    BEGIN
        PERFORM onboarding.create_and_submit_onboarding_request('View All Probe', 'view-all-probe@example.invalid',
            'view-all-probe-' || extract(epoch from now())::text, 'Probe', NULL, CURRENT_DATE + 14);
        INSERT INTO "_va_results" VALUES ('3-viewall-cannot-create', 'FAIL: create succeeded');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_va_results" VALUES ('3-viewall-cannot-create',
            CASE WHEN SQLERRM LIKE 'ONBOARDING_NOT_AUTHORIZED%' THEN 'PASS: create denied - ' || SQLERRM
                 ELSE 'FAIL: wrong error ' || SQLSTATE || ': ' || SQLERRM END);
    END;
END;
$$;

-- NEGATIVE (as an unrelated user) ---------------------------------------
DO $$
DECLARE
    v_other uuid := (SELECT "value"::uuid FROM "_va_ids" WHERE "key" = 'other_id');
    v_seen int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_other::text, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_seen FROM onboarding.onboarding_records;
    INSERT INTO "_va_results" VALUES ('4-other-user-negative',
        CASE WHEN v_seen = 0 THEN 'PASS: user without MANAGE/VIEW_ALL/link sees 0 records'
             ELSE 'FAIL: unrelated user sees ' || v_seen::text END);
END;
$$;
RESET ROLE;

-- REVOKE only what this script created (by captured id) ------------------
DO $$
DECLARE
    v_role uuid := (SELECT "value"::uuid FROM "_va_ids" WHERE "key" = 'role_id');
    v_rp   uuid := (SELECT "value"::uuid FROM "_va_ids" WHERE "key" = 'rp_id');
    v_ur   uuid := (SELECT "value"::uuid FROM "_va_ids" WHERE "key" = 'ur_id');
    v_n int;
BEGIN
    DELETE FROM core.user_roles WHERE id = v_ur;
    DELETE FROM core.role_permissions WHERE id = v_rp;
    DELETE FROM core.roles WHERE id = v_role;
    SELECT (SELECT count(*) FROM core.roles WHERE name = 'TEMP_TEST_ONBOARDING_VIEW_ALL')
         + (SELECT count(*) FROM core.role_permissions rp JOIN core.permissions p ON p.id = rp.permission_id WHERE p.code = 'ONBOARDING_VIEW_ALL')
         + (SELECT count(*) FROM core.user_roles WHERE id = v_ur)
    INTO v_n;
    INSERT INTO "_va_results" VALUES ('5-revoked',
        CASE WHEN v_n = 0 AND EXISTS (SELECT 1 FROM core.permissions WHERE code = 'ONBOARDING_VIEW_ALL')
             THEN 'PASS: temp role, grant and assignment removed; permission row ONBOARDING_VIEW_ALL itself untouched'
             ELSE 'FAIL: ' || v_n::text || ' leftover row(s)' END);
END;
$$;

-- POST-REVOKE: viewer is back to seeing nothing ---------------------------
SET ROLE "authenticated";
DO $$
DECLARE
    v_viewer uuid := '00000000-0000-0000-0000-0000000000fa';
    v_seen int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer::text, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_seen FROM onboarding.onboarding_records;
    INSERT INTO "_va_results" VALUES ('6-post-revoke',
        CASE WHEN v_seen = 0 THEN 'PASS: viewer sees 0 records after revoke'
             ELSE 'FAIL: viewer still sees ' || v_seen::text END);
END;
$$;
RESET ROLE;

-- FINAL GATE -------------------------------------------------------------
DO $$
DECLARE v_fail int; v_pass int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE "result" LIKE 'FAIL%'), count(*) FILTER (WHERE "result" LIKE 'PASS%'),
           string_agg("step" || ' => ' || "result", E'\n') FILTER (WHERE "result" LIKE 'FAIL%')
    INTO v_fail, v_pass, v_list FROM "_va_results";
    IF v_fail > 0 THEN RAISE EXCEPTION 'VIEW_ALL_TEST_FAILED: % FAIL, % PASS:%', v_fail, v_pass, E'\n' || v_list; END IF;
    INSERT INTO "_va_results" VALUES ('99-summary', 'ALL PASS: FAIL count = 0, PASS count = ' || v_pass::text);
END;
$$;

SELECT * FROM "_va_results" ORDER BY "step";
