-- ========================================================================
-- TEST_onboarding_008_identity_projection.sql
-- Proves migration 008 (onboarding.get_candidate_identities) against the
-- seven checks in the team-lead's round-8 decision. Run as ONE paste, in
-- the seeded Track B database, AFTER applying 008. If anything raises, the
-- whole script rolls back (temporary roles included).
--
-- PRECONDITIONS
--   * 001-008 applied; workflow seeded; some onboarding records exist.
--   * syednafees1965@gmail.com (38358631-...) has an ACTIVE person link to
--     its CANDIDATE person (done by logging in with the provisioning fix).
--   * LOCAL_TEST_ADMIN (2d48e4e3-...) holds ONBOARDING_MANAGE.
--   * a6 (00000000-...-0a6, TEST_WORKFLOW_ADMIN) holds ONBOARDING_MANAGE
--     but NOT PEOPLE_MANAGE - this is the "cannot read core.people" user.
--   * test-outsider (00000000-...-0fa) has no onboarding permission and
--     no ACTIVE link; it gets a TEMPORARY ONBOARDING_VIEW_ALL role below.
--
-- Everything temporary (two roles, their grants and assignments) is
-- removed by captured id before the end and verified gone.
-- ========================================================================
DROP TABLE IF EXISTS "_t8_results";
CREATE TEMP TABLE "_t8_results" ("step" text, "result" text);
GRANT ALL ON "_t8_results" TO "authenticated";
DROP TABLE IF EXISTS "_t8_ids";
CREATE TEMP TABLE "_t8_ids" ("key" text PRIMARY KEY, "value" text);
GRANT ALL ON "_t8_ids" TO "authenticated";

-- SETUP (privileged) ------------------------------------------------------
DO $$
DECLARE
    v_manage    uuid := '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2';
    v_manage_only uuid := '00000000-0000-0000-0000-0000000000a6';
    v_candidate uuid := '38358631-cbc4-481a-9ab6-e769204837ba';
    v_viewer    uuid := '00000000-0000-0000-0000-0000000000fa';
    v_unrelated uuid; v_adminish uuid;
    v_cand_person uuid; v_cand_record uuid; v_other_record uuid;
    v_exp_name text; v_exp_email text;
    v_role1 uuid; v_role2 uuid; v_ur1 uuid; v_ur2 uuid;
    v_rp_ids uuid[] := ARRAY[]::uuid[]; v_rp uuid; v_code text; v_perm uuid;
    v_total int;
BEGIN
    IF NOT core.has_permission(v_manage, 'ONBOARDING_MANAGE') THEN RAISE EXCEPTION 'SETUP: LOCAL_TEST_ADMIN lacks ONBOARDING_MANAGE'; END IF;
    IF NOT core.has_permission(v_manage_only, 'ONBOARDING_MANAGE') OR core.has_permission(v_manage_only, 'PEOPLE_MANAGE') THEN
        RAISE EXCEPTION 'SETUP: a6 must hold ONBOARDING_MANAGE and NOT PEOPLE_MANAGE';
    END IF;
    IF core.has_permission(v_viewer, 'ONBOARDING_MANAGE') OR core.has_permission(v_viewer, 'ONBOARDING_VIEW_ALL')
       OR EXISTS (SELECT 1 FROM core.person_user_links WHERE user_id = v_viewer AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'SETUP: viewer fixture is not clean';
    END IF;
    IF EXISTS (SELECT 1 FROM core.roles WHERE name LIKE 'TEMP_TEST_008%') THEN
        RAISE EXCEPTION 'SETUP: leftover TEMP_TEST_008 role exists - investigate manually';
    END IF;

    SELECT pul.person_id INTO v_cand_person FROM core.person_user_links pul
    WHERE pul.user_id = v_candidate AND pul.status = 'ACTIVE';
    IF v_cand_person IS NULL THEN RAISE EXCEPTION 'SETUP: candidate has no ACTIVE person link (log in as the candidate first)'; END IF;

    SELECT o.id INTO v_cand_record FROM onboarding.onboarding_records o
    WHERE o.person_id = v_cand_person ORDER BY o.created_at DESC LIMIT 1;
    IF v_cand_record IS NULL THEN RAISE EXCEPTION 'SETUP: candidate person has no onboarding record'; END IF;

    SELECT o.id INTO v_other_record FROM onboarding.onboarding_records o
    WHERE o.person_id <> v_cand_person ORDER BY o.created_at LIMIT 1;
    IF v_other_record IS NULL THEN RAISE EXCEPTION 'SETUP: need at least one other person''s onboarding record'; END IF;

    SELECT p.full_name::text, p.primary_email::text INTO v_exp_name, v_exp_email
    FROM core.people p WHERE p.id = v_cand_person;

    SELECT u.id INTO v_unrelated FROM auth.users u
    WHERE u.email LIKE '%@example.invalid' AND u.id NOT IN (v_viewer, v_manage_only)
      AND NOT EXISTS (SELECT 1 FROM core.user_roles ur WHERE ur.user_id = u.id AND ur.is_active)
      AND NOT EXISTS (SELECT 1 FROM core.person_user_links l WHERE l.user_id = u.id AND l.status = 'ACTIVE')
    ORDER BY u.id LIMIT 1;
    SELECT u.id INTO v_adminish FROM auth.users u
    WHERE u.email LIKE '%@example.invalid' AND u.id NOT IN (v_viewer, v_manage_only, v_unrelated)
      AND NOT EXISTS (SELECT 1 FROM core.user_roles ur WHERE ur.user_id = u.id AND ur.is_active)
      AND NOT EXISTS (SELECT 1 FROM core.person_user_links l WHERE l.user_id = u.id AND l.status = 'ACTIVE')
    ORDER BY u.id LIMIT 1;
    IF v_unrelated IS NULL OR v_adminish IS NULL THEN RAISE EXCEPTION 'SETUP: need two clean fixture users (no role, no ACTIVE link)'; END IF;

    -- Temp role 1: ONBOARDING_VIEW_ALL only, to the viewer
    INSERT INTO core.roles (name, display_name, description)
    VALUES ('TEMP_TEST_008_VIEW_ALL', 'TEMP 008 view-all', 'TEMPORARY - removed by the same script') RETURNING id INTO v_role1;
    SELECT id INTO v_perm FROM core.permissions WHERE code = 'ONBOARDING_VIEW_ALL';
    INSERT INTO core.role_permissions (role_id, permission_id) VALUES (v_role1, v_perm) RETURNING id INTO v_rp;
    v_rp_ids := v_rp_ids || v_rp;
    INSERT INTO core.user_roles (user_id, role_id) VALUES (v_viewer, v_role1) RETURNING id INTO v_ur1;

    -- Temp role 2: "admin-ish" - broad non-onboarding permissions, NO onboarding permission
    INSERT INTO core.roles (name, display_name, description)
    VALUES ('TEMP_TEST_008_ADMINISH', 'TEMP 008 admin-ish', 'TEMPORARY - removed by the same script') RETURNING id INTO v_role2;
    FOREACH v_code IN ARRAY ARRAY['PEOPLE_MANAGE','WORKFLOW_VIEW_ALL','WORKFLOW_CONFIG_MANAGE'] LOOP
        SELECT id INTO v_perm FROM core.permissions WHERE code = v_code;
        IF v_perm IS NULL THEN RAISE EXCEPTION 'SETUP: permission % not found', v_code; END IF;
        INSERT INTO core.role_permissions (role_id, permission_id) VALUES (v_role2, v_perm) RETURNING id INTO v_rp;
        v_rp_ids := v_rp_ids || v_rp;
    END LOOP;
    INSERT INTO core.user_roles (user_id, role_id) VALUES (v_adminish, v_role2) RETURNING id INTO v_ur2;

    IF core.has_permission(v_adminish, 'ONBOARDING_MANAGE') OR core.has_permission(v_adminish, 'ONBOARDING_VIEW_ALL') THEN
        RAISE EXCEPTION 'SETUP: admin-ish user unexpectedly holds an onboarding permission';
    END IF;

    SELECT count(*) INTO v_total FROM onboarding.onboarding_records;

    INSERT INTO "_t8_ids" VALUES
        ('cand_person', v_cand_person::text), ('cand_record', v_cand_record::text), ('other_record', v_other_record::text),
        ('exp_name', v_exp_name), ('exp_email', v_exp_email), ('total', v_total::text),
        ('unrelated', v_unrelated::text), ('adminish', v_adminish::text),
        ('role1', v_role1::text), ('role2', v_role2::text), ('ur1', v_ur1::text), ('ur2', v_ur2::text),
        ('rp_ids', array_to_string(v_rp_ids, ',')),
        ('fp_before', (SELECT md5(coalesce(string_agg(o.id::text || ':' || o.version::text, ',' ORDER BY o.id), '')) FROM onboarding.onboarding_records o)
                      || '/' || (SELECT md5(coalesce(string_agg(p.id::text || ':' || p.version::text, ',' ORDER BY p.id), '')) FROM core.people p)),
        ('other_modules_before',
            (SELECT count(*) FROM leave.leave_requests)::text || '/' || (SELECT count(*) FROM attendance.correction_requests)::text || '/' ||
            (SELECT count(*) FROM assets.asset_requests)::text || '/' || (SELECT count(*) FROM hr.contracts)::text);

    INSERT INTO "_t8_results" VALUES ('0-setup',
        'records=' || v_total::text || '; candidate record=' || v_cand_record::text || ' (' || v_exp_name || '); unrelated user and admin-ish user chosen from clean fixtures; temp roles granted');
END;
$$;

-- AS EACH USER ------------------------------------------------------------
SET ROLE "authenticated";

-- 1: ONBOARDING_MANAGE holders resolve the real name/email
DO $$
DECLARE
    v_total int := (SELECT "value"::int FROM "_t8_ids" WHERE "key" = 'total');
    v_rec uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'cand_record');
    v_name text := (SELECT "value" FROM "_t8_ids" WHERE "key" = 'exp_name');
    v_email text := (SELECT "value" FROM "_t8_ids" WHERE "key" = 'exp_email');
    v_u uuid; v_n int; v_ok boolean; v_label text;
BEGIN
    FOREACH v_u IN ARRAY ARRAY['2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','00000000-0000-0000-0000-0000000000a6']::uuid[] LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u::text, 'role', 'authenticated')::text, true);
        SELECT count(*) INTO v_n FROM onboarding.get_candidate_identities(NULL);
        SELECT EXISTS (SELECT 1 FROM onboarding.get_candidate_identities(ARRAY[v_rec]) i
                       WHERE i.full_name = v_name AND i.email = v_email AND i.onboarding_record_id = v_rec) INTO v_ok;
        v_label := CASE WHEN v_u = '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2'::uuid THEN '1a-manage-with-people-manage' ELSE '1b-manage-WITHOUT-people-manage' END;
        INSERT INTO "_t8_results" VALUES (v_label,
            CASE WHEN v_n = v_total AND v_ok THEN 'PASS: sees identity for all ' || v_n::text || ' records; candidate record resolves to the real name and email'
                 ELSE 'FAIL: rows=' || v_n::text || ' of ' || v_total::text || ', candidate resolves=' || v_ok::text END);
    END LOOP;
END;
$$;

-- 2: ONBOARDING_VIEW_ALL holder (temporary role) resolves the real name/email
DO $$
DECLARE
    v_total int := (SELECT "value"::int FROM "_t8_ids" WHERE "key" = 'total');
    v_rec uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'cand_record');
    v_name text := (SELECT "value" FROM "_t8_ids" WHERE "key" = 'exp_name');
    v_email text := (SELECT "value" FROM "_t8_ids" WHERE "key" = 'exp_email');
    v_n int; v_ok boolean;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000fa', 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_n FROM onboarding.get_candidate_identities(NULL);
    SELECT EXISTS (SELECT 1 FROM onboarding.get_candidate_identities(ARRAY[v_rec]) i WHERE i.full_name = v_name AND i.email = v_email) INTO v_ok;
    INSERT INTO "_t8_results" VALUES ('2-view-all-holder',
        CASE WHEN v_n = v_total AND v_ok THEN 'PASS: ONBOARDING_VIEW_ALL holder (no MANAGE, no link) resolves all ' || v_n::text || ' records incl. the real name/email'
             ELSE 'FAIL: rows=' || v_n::text || ' of ' || v_total::text || ', candidate resolves=' || v_ok::text END);
END;
$$;

-- 3: unrelated user and an admin-ish user (broad permissions, none onboarding) get nothing
DO $$
DECLARE
    v_rec uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'cand_record');
    v_u uuid; v_n int; v_n2 int; v_label text;
BEGIN
    FOREACH v_u IN ARRAY ARRAY[(SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'unrelated'),
                               (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'adminish')] LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u::text, 'role', 'authenticated')::text, true);
        SELECT count(*) INTO v_n FROM onboarding.get_candidate_identities(NULL);
        SELECT count(*) INTO v_n2 FROM onboarding.get_candidate_identities(ARRAY[v_rec]);
        v_label := CASE WHEN v_u = (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'unrelated') THEN '3a-unrelated-user' ELSE '3b-admin-ish-user-no-onboarding-permission' END;
        INSERT INTO "_t8_results" VALUES (v_label,
            CASE WHEN v_n = 0 AND v_n2 = 0 THEN 'PASS: zero rows, also when the record id is asked for explicitly'
                 ELSE 'FAIL: rows=' || v_n::text || ' / explicit=' || v_n2::text END);
    END LOOP;
END;
$$;

-- 4: the candidate resolves only their own record
DO $$
DECLARE
    v_rec uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'cand_record');
    v_other uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'other_record');
    v_name text := (SELECT "value" FROM "_t8_ids" WHERE "key" = 'exp_name');
    v_email text := (SELECT "value" FROM "_t8_ids" WHERE "key" = 'exp_email');
    v_all int; v_mixed int; v_other_only int; v_own boolean;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '38358631-cbc4-481a-9ab6-e769204837ba', 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_all FROM onboarding.get_candidate_identities(NULL);
    SELECT count(*) INTO v_mixed FROM onboarding.get_candidate_identities(ARRAY[v_rec, v_other]);
    SELECT count(*) INTO v_other_only FROM onboarding.get_candidate_identities(ARRAY[v_other]);
    SELECT EXISTS (SELECT 1 FROM onboarding.get_candidate_identities(NULL) i
                   WHERE i.onboarding_record_id = v_rec AND i.full_name = v_name AND i.email = v_email) INTO v_own;
    INSERT INTO "_t8_results" VALUES ('4-candidate-own-identity-only',
        CASE WHEN v_all = 1 AND v_mixed = 1 AND v_other_only = 0 AND v_own THEN 'PASS: exactly 1 row (own record, real name/email); asking for another person''s record returns nothing'
             ELSE 'FAIL: all=' || v_all::text || ', mixed=' || v_mixed::text || ', other_only=' || v_other_only::text || ', own_ok=' || v_own::text END);
END;
$$;

-- 5: direct core.people access is unchanged: still blocked for these users
DO $$
DECLARE
    v_person uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'cand_person');
    v_u uuid; v_n int; v_label text; v_outcome text;
BEGIN
    FOREACH v_u IN ARRAY ARRAY['00000000-0000-0000-0000-0000000000a6','00000000-0000-0000-0000-0000000000fa']::uuid[] LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u::text, 'role', 'authenticated')::text, true);
        v_label := CASE WHEN v_u = '00000000-0000-0000-0000-0000000000a6'::uuid THEN '5a-direct-people-select-MANAGE-user' ELSE '5b-direct-people-select-VIEW_ALL-user' END;
        BEGIN
            SELECT count(*) INTO v_n FROM core.people WHERE id = v_person;
            v_outcome := CASE WHEN v_n = 0 THEN 'PASS: 0 rows from core.people (RLS)' ELSE 'FAIL: direct core.people SELECT returned ' || v_n::text || ' row(s)' END;
        EXCEPTION WHEN insufficient_privilege THEN
            v_outcome := 'PASS: permission denied on core.people (42501)';
        END;
        INSERT INTO "_t8_results" VALUES (v_label, v_outcome);
    END LOOP;
END;
$$;

-- 6c: no session -> rejected, not silently empty
DO $$
BEGIN
    PERFORM set_config('request.jwt.claims', '{}', true);
    BEGIN
        PERFORM * FROM onboarding.get_candidate_identities(NULL);
        INSERT INTO "_t8_results" VALUES ('6c-unauthenticated', 'FAIL: call without a session did not raise');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO "_t8_results" VALUES ('6c-unauthenticated',
            CASE WHEN SQLERRM LIKE 'ONBOARDING_UNAUTHENTICATED%' THEN 'PASS: ' || SQLERRM ELSE 'FAIL: wrong error ' || SQLSTATE || ': ' || SQLERRM END);
    END;
END;
$$;
RESET ROLE;

-- 6: read-only / hardening, 7: other modules unaffected, then revoke -------
DO $$
DECLARE
    v_oid oid := 'onboarding.get_candidate_identities(uuid[])'::regprocedure;
    v_ok boolean;
    v_fp_after text;
    v_mods_after text;
BEGIN
    SELECT p.prosecdef AND p.provolatile = 's'
           AND coalesce(p.proconfig::text LIKE '%search_path=%', false)
           AND pg_get_function_result(p.oid) = 'TABLE(onboarding_record_id uuid, person_id uuid, full_name text, email text)'
    INTO v_ok FROM pg_proc p WHERE p.oid = v_oid;
    INSERT INTO "_t8_results" VALUES ('6a-function-shape',
        CASE WHEN v_ok THEN 'PASS: SECURITY DEFINER, STABLE (read-only), search_path pinned, returns exactly record id / person id / full_name / email'
             ELSE 'FAIL: function definition does not match the approved shape' END);

    INSERT INTO "_t8_results" VALUES ('6b-execute-grants',
        CASE WHEN has_function_privilege('authenticated', v_oid, 'EXECUTE')
              AND NOT has_function_privilege('anon', v_oid, 'EXECUTE')
              AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                              WHERE p.oid = v_oid AND a.grantee = 0 AND a.privilege_type = 'EXECUTE')
             THEN 'PASS: EXECUTE for authenticated only (PUBLIC and anon revoked)'
             ELSE 'FAIL: unexpected EXECUTE grants' END);

    v_fp_after := (SELECT md5(coalesce(string_agg(o.id::text || ':' || o.version::text, ',' ORDER BY o.id), '')) FROM onboarding.onboarding_records o)
                  || '/' || (SELECT md5(coalesce(string_agg(p.id::text || ':' || p.version::text, ',' ORDER BY p.id), '')) FROM core.people p);
    INSERT INTO "_t8_results" VALUES ('6d-no-writes',
        CASE WHEN v_fp_after = (SELECT "value" FROM "_t8_ids" WHERE "key" = 'fp_before')
             THEN 'PASS: onboarding_records and core.people (ids and versions) identical before and after all calls'
             ELSE 'FAIL: data changed while the identity function was being exercised' END);

    v_mods_after := (SELECT count(*) FROM leave.leave_requests)::text || '/' || (SELECT count(*) FROM attendance.correction_requests)::text || '/' ||
                    (SELECT count(*) FROM assets.asset_requests)::text || '/' || (SELECT count(*) FROM hr.contracts)::text;
    INSERT INTO "_t8_results" VALUES ('7-other-modules-unaffected',
        CASE WHEN v_mods_after = (SELECT "value" FROM "_t8_ids" WHERE "key" = 'other_modules_before')
             THEN 'PASS: Leave/Attendance/Assets/Contracts row counts unchanged (' || v_mods_after || ')'
             ELSE 'FAIL: counts moved from ' || (SELECT "value" FROM "_t8_ids" WHERE "key" = 'other_modules_before') || ' to ' || v_mods_after END);
END;
$$;

-- REVOKE the temporary roles (by captured id) and verify they are gone ----
DO $$
DECLARE
    v_ur1 uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'ur1');
    v_ur2 uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'ur2');
    v_role1 uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'role1');
    v_role2 uuid := (SELECT "value"::uuid FROM "_t8_ids" WHERE "key" = 'role2');
    v_rp_ids uuid[] := string_to_array((SELECT "value" FROM "_t8_ids" WHERE "key" = 'rp_ids'), ',')::uuid[];
    v_left int;
BEGIN
    DELETE FROM core.user_roles WHERE id IN (v_ur1, v_ur2);
    DELETE FROM core.role_permissions WHERE id = ANY(v_rp_ids);
    DELETE FROM core.roles WHERE id IN (v_role1, v_role2);
    SELECT (SELECT count(*) FROM core.roles WHERE name LIKE 'TEMP_TEST_008%')
         + (SELECT count(*) FROM core.role_permissions WHERE id = ANY(v_rp_ids))
         + (SELECT count(*) FROM core.user_roles WHERE id IN (v_ur1, v_ur2)) INTO v_left;
    INSERT INTO "_t8_results" VALUES ('8-temp-roles-removed',
        CASE WHEN v_left = 0 THEN 'PASS: both temporary roles, their grants and assignments removed by captured id'
             ELSE 'FAIL: ' || v_left::text || ' leftover row(s)' END);
END;
$$;

-- POST-REVOKE: the former VIEW_ALL holder is back to nothing ---------------
SET ROLE "authenticated";
DO $$
DECLARE v_n int;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000fa', 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_n FROM onboarding.get_candidate_identities(NULL);
    INSERT INTO "_t8_results" VALUES ('9-post-revoke',
        CASE WHEN v_n = 0 THEN 'PASS: former VIEW_ALL holder resolves nothing after revoke' ELSE 'FAIL: still resolves ' || v_n::text END);
END;
$$;
RESET ROLE;

-- FINAL GATE ----------------------------------------------------------------
DO $$
DECLARE v_fail int; v_pass int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE "result" LIKE 'FAIL%'), count(*) FILTER (WHERE "result" LIKE 'PASS%'),
           string_agg("step" || ' => ' || "result", E'\n') FILTER (WHERE "result" LIKE 'FAIL%')
    INTO v_fail, v_pass, v_list FROM "_t8_results";
    IF v_fail > 0 THEN RAISE EXCEPTION 'IDENTITY_PROJECTION_TEST_FAILED: % FAIL, % PASS:%', v_fail, v_pass, E'\n' || v_list; END IF;
    IF v_pass = 0 THEN RAISE EXCEPTION 'IDENTITY_PROJECTION_TEST_EMPTY: no PASS results recorded'; END IF;
    INSERT INTO "_t8_results" VALUES ('99-summary', 'ALL PASS: FAIL count = 0, PASS count = ' || v_pass::text);
END;
$$;

SELECT * FROM "_t8_results" ORDER BY "step";
