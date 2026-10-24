-- ========================================================================
-- TEST_P01_shared_privilege_hardening.sql
-- Read-only verification (changes nothing, never attempts TRUNCATE).
-- Run AFTER P01. Ends with a zero-failure gate.
-- ========================================================================
DROP TABLE IF EXISTS "_p01_results";
CREATE TEMP TABLE "_p01_results" ("step" text, "result" text);
GRANT ALL ON "_p01_results" TO "authenticated";

DO $$
DECLARE
    v_t text; v_role text; v_priv text; v_bad text;
    v_tables text[] := ARRAY['hr.employees','hr.contracts','hr.contract_versions','assets.asset_assignments','assets.assets'];
BEGIN
    -- 1: removed privileges are gone
    v_bad := '';
    FOREACH v_t IN ARRAY v_tables LOOP
        FOREACH v_role IN ARRAY ARRAY['authenticated','anon'] LOOP
            FOREACH v_priv IN ARRAY ARRAY['TRUNCATE','TRIGGER','REFERENCES'] LOOP
                IF has_table_privilege(v_role, v_t, v_priv) THEN v_bad := v_bad || ' ' || v_role || ':' || v_priv || '@' || v_t; END IF;
            END LOOP;
        END LOOP;
    END LOOP;
    INSERT INTO "_p01_results" VALUES ('1-removed-privileges-gone',
        CASE WHEN v_bad = '' THEN 'PASS: authenticated and anon hold no TRUNCATE / TRIGGER / REFERENCES on the five tables'
             ELSE 'FAIL: still granted:' || v_bad END);

    -- 2: preserved privileges are untouched for authenticated
    v_bad := '';
    FOREACH v_t IN ARRAY v_tables LOOP
        FOREACH v_priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE'] LOOP
            IF NOT has_table_privilege('authenticated', v_t, v_priv) THEN v_bad := v_bad || ' ' || v_priv || '@' || v_t; END IF;
        END LOOP;
    END LOOP;
    INSERT INTO "_p01_results" VALUES ('2-preserved-privileges-intact',
        CASE WHEN v_bad = '' THEN 'PASS: SELECT / INSERT / UPDATE / DELETE still granted to authenticated (current behaviour preserved)'
             ELSE 'FAIL: missing:' || v_bad END);

    -- 3: row-level security still enabled on all five
    SELECT string_agg(n.nspname || '.' || c.relname, ' ') INTO v_bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE (n.nspname || '.' || c.relname) = ANY(v_tables) AND NOT c.relrowsecurity;
    INSERT INTO "_p01_results" VALUES ('3-rls-still-enabled',
        CASE WHEN v_bad IS NULL THEN 'PASS: RLS enabled on all five tables'
             ELSE 'FAIL: RLS disabled on: ' || v_bad END);

    -- 4: policies are unchanged in number (assets_assignments 1, assets 2, contracts 2, contract_versions 2, employees 3)
    INSERT INTO "_p01_results" VALUES ('4-policy-counts',
        CASE WHEN (SELECT count(*) FROM pg_policies WHERE schemaname='assets' AND tablename='asset_assignments') = 1
              AND (SELECT count(*) FROM pg_policies WHERE schemaname='assets' AND tablename='assets') = 2
              AND (SELECT count(*) FROM pg_policies WHERE schemaname='hr' AND tablename='contracts') = 2
              AND (SELECT count(*) FROM pg_policies WHERE schemaname='hr' AND tablename='contract_versions') = 2
              AND (SELECT count(*) FROM pg_policies WHERE schemaname='hr' AND tablename='employees') = 3
             THEN 'PASS: policy counts match the reconnaissance (1/2/2/2/3) - no policy touched'
             ELSE 'FAIL: policy counts differ from the reconnaissance' END);
END;
$$;

-- 5: the existing modules still read normally as an authenticated user
SET ROLE "authenticated";
DO $$
DECLARE v_n bigint;
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','2d48e4e3-fee2-4034-8b8d-a3cce8298ce2','role','authenticated')::text, true);
    SELECT (SELECT count(*) FROM hr.employees) + (SELECT count(*) FROM hr.contracts) + (SELECT count(*) FROM hr.contract_versions)
         + (SELECT count(*) FROM assets.asset_assignments) + (SELECT count(*) FROM assets.assets) INTO v_n;
    INSERT INTO "_p01_results" VALUES ('5-authenticated-reads-work',
        CASE WHEN v_n > 0 THEN 'PASS: LOCAL_TEST_ADMIN still reads all five tables (' || v_n::text || ' rows in total)'
             ELSE 'FAIL: reads returned nothing' END);
END;
$$;
RESET ROLE;

DO $$
DECLARE v_fail int; v_pass int; v_list text;
BEGIN
    SELECT count(*) FILTER (WHERE "result" LIKE 'FAIL%'), count(*) FILTER (WHERE "result" LIKE 'PASS%'),
           string_agg("step" || ' => ' || "result", E'\n') FILTER (WHERE "result" LIKE 'FAIL%')
    INTO v_fail, v_pass, v_list FROM "_p01_results";
    IF v_fail > 0 THEN RAISE EXCEPTION 'P01_TEST_FAILED: % FAIL, % PASS:%', v_fail, v_pass, E'\n' || v_list; END IF;
    INSERT INTO "_p01_results" VALUES ('99-summary', 'ALL PASS: FAIL count = 0, PASS count = ' || v_pass::text);
END;
$$;

SELECT * FROM "_p01_results" ORDER BY "step";
