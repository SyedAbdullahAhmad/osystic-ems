-- ========================================================================
-- P05_privilege_hygiene_and_request_insert_closure.sql  (v2 - lead review applied)
-- Do not apply until the three pre-fix bypass evidence results are captured.
--
-- Part A (hygiene): REVOKE TRUNCATE, TRIGGER, REFERENCES from authenticated on 14 tables.
-- Part B (hygiene): 5 approval/balance views become SELECT-only.
-- Part C (bypass):  drop direct INSERT policy + INSERT grant on
--                   leave.leave_requests, attendance.correction_requests, assets.asset_requests.
--
-- ATOMIC: one explicit transaction. The pre-flight asserts the exact baseline that was
-- reviewed (policy name/command/roles/check, privileges, RLS state, exact RPC signatures);
-- any mismatch aborts before a single change. A post-check inside the same
-- transaction aborts (rolling everything back) if the end state is not as intended.
--
-- NOT CHANGED: SELECT anywhere; INSERT/UPDATE/DELETE elsewhere; any other policy,
-- trigger or function; Finance RBAC tables; assets.assets visibility (separate change);
-- workflow._test_results (fixed in test 007).
-- ========================================================================
BEGIN;

DO $$
DECLARE
    v_rel text; v_priv text; v_sig text; v_n int; v_pol record;
    v_tables text[] := ARRAY['assets.asset_categories','assets.asset_requests','attendance.attendance_days',
        'attendance.correction_requests','core.departments','core.organizations','core.people',
        'core.person_user_links','hr.contract_requests','leave.leave_accruals','leave.leave_adjustments',
        'leave.leave_ledger','leave.leave_requests','leave.leave_types'];
    v_views  text[] := ARRAY['leave.v_leave_balances','leave.v_leave_request_approvals',
        'attendance.v_correction_request_approvals','assets.v_asset_request_approvals','hr.v_contract_approvals'];
    v_req    text[] := ARRAY['leave.leave_requests','attendance.correction_requests','assets.asset_requests'];
BEGIN
    -- 1. every relation exists
    FOREACH v_rel IN ARRAY v_tables || v_views LOOP
        IF to_regclass(v_rel) IS NULL THEN RAISE EXCEPTION 'P05 PRE-FLIGHT: relation % missing', v_rel; END IF;
    END LOOP;

    -- 2. EXACT routine signatures used by the application, SECURITY DEFINER, and no overloads
    FOREACH v_sig IN ARRAY ARRAY[
        'leave.submit_leave_request(uuid,date,date,numeric,text,character varying)',
        'attendance.submit_correction_request(date,timestamp with time zone,timestamp with time zone,text,character varying)',
        'assets.submit_asset_request(uuid,text,character varying)'] LOOP
        IF to_regprocedure(v_sig) IS NULL THEN
            RAISE EXCEPTION 'P05 PRE-FLIGHT: exact signature % not found', v_sig; END IF;
        IF NOT (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = to_regprocedure(v_sig)::oid) THEN
            RAISE EXCEPTION 'P05 PRE-FLIGHT: % is not SECURITY DEFINER', v_sig; END IF;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE (n.nspname, p.proname) IN (('leave','submit_leave_request'),
            ('attendance','submit_correction_request'),('assets','submit_asset_request'));
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'P05 PRE-FLIGHT: found % routines named like the submit RPCs, expected exactly 3 (overload?)', v_n; END IF;

    -- 3. RLS enabled and NOT forced on request tables (owner-run RPCs bypass policies)
    FOREACH v_rel IN ARRAY v_req LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v_rel::regclass AND relrowsecurity AND NOT relforcerowsecurity) THEN
            RAISE EXCEPTION 'P05 PRE-FLIGHT: RLS state on % is not (enabled, not forced)', v_rel; END IF;
    END LOOP;

    -- 4. INSERT policy baseline: exactly one INSERT/ALL policy per table, exact definition
    FOR v_pol IN SELECT * FROM (VALUES
        ('leave','leave_requests','leave_requests_insert'),
        ('attendance','correction_requests','correction_requests_insert'),
        ('assets','asset_requests','asset_requests_insert')) AS t(s, tb, pn) LOOP
        SELECT count(*) INTO v_n FROM pg_policies
         WHERE schemaname = v_pol.s AND tablename = v_pol.tb AND cmd IN ('INSERT','ALL');
        IF v_n <> 1 THEN
            RAISE EXCEPTION 'P05 PRE-FLIGHT: %.% has % INSERT/ALL policies, expected 1', v_pol.s, v_pol.tb, v_n; END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_policies
             WHERE schemaname = v_pol.s AND tablename = v_pol.tb AND policyname = v_pol.pn
               AND cmd = 'INSERT' AND permissive = 'PERMISSIVE'
               AND roles = '{public}'::name[] AND qual IS NULL
               AND with_check = '(employee_id = auth.uid())') THEN
            RAISE EXCEPTION 'P05 PRE-FLIGHT: policy %.%.% differs from reviewed baseline (name/cmd/roles/check)',
                v_pol.s, v_pol.tb, v_pol.pn; END IF;
    END LOOP;

    -- 5. privilege baseline (so the rollback can never grant what was not there before)
    FOREACH v_rel IN ARRAY v_tables LOOP
        FOREACH v_priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF NOT has_table_privilege('authenticated', v_rel, v_priv) THEN
                RAISE EXCEPTION 'P05 PRE-FLIGHT: authenticated expected to hold % on %', v_priv, v_rel; END IF;
        END LOOP;
    END LOOP;
    FOREACH v_rel IN ARRAY v_views LOOP
        FOREACH v_priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF NOT has_table_privilege('authenticated', v_rel, v_priv) THEN
                RAISE EXCEPTION 'P05 PRE-FLIGHT: authenticated expected to hold % on view %', v_priv, v_rel; END IF;
        END LOOP;
    END LOOP;
    FOREACH v_rel IN ARRAY v_req LOOP
        IF NOT has_table_privilege('authenticated', v_rel, 'INSERT') THEN
            RAISE EXCEPTION 'P05 PRE-FLIGHT: authenticated expected to hold INSERT on %', v_rel; END IF;
    END LOOP;
    -- anon baseline (role form) and PUBLIC baseline (ACL form): none of the privileges P05 touches.
    -- PUBLIC is a pseudo-role: it is detected as the ACL grantee with oid 0 via aclexplode(),
    -- not through has_table_privilege()'s role-name form.
    FOREACH v_rel IN ARRAY v_tables || v_views LOOP
        FOREACH v_priv IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('anon', v_rel, v_priv) THEN
                RAISE EXCEPTION 'P05 PRE-FLIGHT: anon unexpectedly holds % on %', v_priv, v_rel; END IF;
            IF EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
                        WHERE c.oid = v_rel::regclass AND a.grantee = 0 AND a.privilege_type = v_priv) THEN
                RAISE EXCEPTION 'P05 PRE-FLIGHT: PUBLIC (ACL grantee 0) unexpectedly holds % on %', v_priv, v_rel; END IF;
        END LOOP;
    END LOOP;
END;
$$;

-- ---------------- Part A ----------------
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."asset_categories"        FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."asset_requests"          FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "attendance"."attendance_days"     FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "attendance"."correction_requests" FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "core"."departments"               FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "core"."organizations"             FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "core"."people"                    FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "core"."person_user_links"         FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."contract_requests"           FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_accruals"           FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_adjustments"        FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_ledger"             FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_requests"           FROM "authenticated";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_types"              FROM "authenticated";

-- ---------------- Part B ----------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."v_leave_balances"                    FROM "authenticated";
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."v_leave_request_approvals"           FROM "authenticated";
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "attendance"."v_correction_request_approvals" FROM "authenticated";
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."v_asset_request_approvals"          FROM "authenticated";
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."v_contract_approvals"                  FROM "authenticated";

-- ---------------- Part C ----------------
DROP POLICY "leave_requests_insert"      ON "leave"."leave_requests";
DROP POLICY "correction_requests_insert" ON "attendance"."correction_requests";
DROP POLICY "asset_requests_insert"      ON "assets"."asset_requests";
REVOKE INSERT ON TABLE "leave"."leave_requests"            FROM "authenticated";
REVOKE INSERT ON TABLE "attendance"."correction_requests"  FROM "authenticated";
REVOKE INSERT ON TABLE "assets"."asset_requests"           FROM "authenticated";

-- ---------------- Post-check (same transaction: failure rolls everything back) ----------------
DO $$
DECLARE v_rel text; v_priv text;
BEGIN
    FOREACH v_rel IN ARRAY ARRAY['assets.asset_categories','assets.asset_requests','attendance.attendance_days',
        'attendance.correction_requests','core.departments','core.organizations','core.people',
        'core.person_user_links','hr.contract_requests','leave.leave_accruals','leave.leave_adjustments',
        'leave.leave_ledger','leave.leave_requests','leave.leave_types'] LOOP
        FOREACH v_priv IN ARRAY ARRAY['TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('authenticated', v_rel, v_priv) THEN
                RAISE EXCEPTION 'P05 POST-CHECK: authenticated still holds % on %', v_priv, v_rel; END IF;
        END LOOP;
        IF NOT has_table_privilege('authenticated', v_rel, 'SELECT') THEN
            RAISE EXCEPTION 'P05 POST-CHECK: authenticated lost SELECT on %', v_rel; END IF;
    END LOOP;
    FOREACH v_rel IN ARRAY ARRAY['leave.v_leave_balances','leave.v_leave_request_approvals',
        'attendance.v_correction_request_approvals','assets.v_asset_request_approvals','hr.v_contract_approvals'] LOOP
        FOREACH v_priv IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('authenticated', v_rel, v_priv) THEN
                RAISE EXCEPTION 'P05 POST-CHECK: authenticated still holds % on view %', v_priv, v_rel; END IF;
        END LOOP;
        IF NOT has_table_privilege('authenticated', v_rel, 'SELECT') THEN
            RAISE EXCEPTION 'P05 POST-CHECK: authenticated lost SELECT on view %', v_rel; END IF;
    END LOOP;
    FOREACH v_rel IN ARRAY ARRAY['leave.leave_requests','attendance.correction_requests','assets.asset_requests'] LOOP
        IF has_table_privilege('authenticated', v_rel, 'INSERT') THEN
            RAISE EXCEPTION 'P05 POST-CHECK: authenticated still holds INSERT on %', v_rel; END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE cmd IN ('INSERT','ALL')
               AND schemaname||'.'||tablename IN ('leave.leave_requests','attendance.correction_requests','assets.asset_requests')) THEN
        RAISE EXCEPTION 'P05 POST-CHECK: an INSERT/ALL policy still exists on a request table'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END P05_privilege_hygiene_and_request_insert_closure.sql
-- ========================================================================
