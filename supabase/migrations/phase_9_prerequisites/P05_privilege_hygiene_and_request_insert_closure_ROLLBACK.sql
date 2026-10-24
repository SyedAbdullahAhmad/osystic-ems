-- ========================================================================
-- P05_privilege_hygiene_and_request_insert_closure_ROLLBACK.sql  (v2 - exact)
-- Restores the pre-P05 state EXACTLY as asserted by P05's pre-flight:
--   * grants go to "authenticated" only (anon/PUBLIC held none before);
--   * policies are recreated as PERMISSIVE, FOR INSERT, TO public (the reviewed
--     baseline; P05's pre-flight aborts if the live roles were anything else),
--     with WITH CHECK ("employee_id" = auth.uid()).
-- This RE-OPENS the direct-insert bypass; it exists only to prove reversibility.
-- Atomic: one transaction; pre-flight requires the post-P05 state, post-check
-- requires the restored baseline.
-- ========================================================================
BEGIN;

DO $$
DECLARE v_rel text; v_priv text;
BEGIN
    FOREACH v_rel IN ARRAY ARRAY['assets.asset_categories','assets.asset_requests','attendance.attendance_days',
        'attendance.correction_requests','core.departments','core.organizations','core.people',
        'core.person_user_links','hr.contract_requests','leave.leave_accruals','leave.leave_adjustments',
        'leave.leave_ledger','leave.leave_requests','leave.leave_types'] LOOP
        FOREACH v_priv IN ARRAY ARRAY['TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('authenticated', v_rel, v_priv) THEN
                RAISE EXCEPTION 'ROLLBACK PRE-FLIGHT: % already held on % - P05 not applied?', v_priv, v_rel; END IF;
        END LOOP;
    END LOOP;
    FOREACH v_rel IN ARRAY ARRAY['leave.leave_requests','attendance.correction_requests','assets.asset_requests'] LOOP
        IF has_table_privilege('authenticated', v_rel, 'INSERT') THEN
            RAISE EXCEPTION 'ROLLBACK PRE-FLIGHT: INSERT already held on %', v_rel; END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE cmd IN ('INSERT','ALL')
               AND schemaname||'.'||tablename IN ('leave.leave_requests','attendance.correction_requests','assets.asset_requests')) THEN
        RAISE EXCEPTION 'ROLLBACK PRE-FLIGHT: an INSERT/ALL policy already exists on a request table'; END IF;
END;
$$;

GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."asset_categories"        TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."asset_requests"          TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "attendance"."attendance_days"     TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "attendance"."correction_requests" TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "core"."departments"               TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "core"."organizations"             TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "core"."people"                    TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "core"."person_user_links"         TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."contract_requests"           TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_accruals"           TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_adjustments"        TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_ledger"             TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_requests"           TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."leave_types"              TO "authenticated";

GRANT INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."v_leave_balances"                    TO "authenticated";
GRANT INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "leave"."v_leave_request_approvals"           TO "authenticated";
GRANT INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "attendance"."v_correction_request_approvals" TO "authenticated";
GRANT INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."v_asset_request_approvals"          TO "authenticated";
GRANT INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."v_contract_approvals"                  TO "authenticated";

GRANT INSERT ON TABLE "leave"."leave_requests"           TO "authenticated";
GRANT INSERT ON TABLE "attendance"."correction_requests" TO "authenticated";
GRANT INSERT ON TABLE "assets"."asset_requests"          TO "authenticated";

CREATE POLICY "leave_requests_insert"      ON "leave"."leave_requests"
    AS PERMISSIVE FOR INSERT TO public WITH CHECK ("employee_id" = auth.uid());
CREATE POLICY "correction_requests_insert" ON "attendance"."correction_requests"
    AS PERMISSIVE FOR INSERT TO public WITH CHECK ("employee_id" = auth.uid());
CREATE POLICY "asset_requests_insert"      ON "assets"."asset_requests"
    AS PERMISSIVE FOR INSERT TO public WITH CHECK ("employee_id" = auth.uid());

DO $$
DECLARE v_pol record;
BEGIN
    FOR v_pol IN SELECT * FROM (VALUES
        ('leave','leave_requests','leave_requests_insert'),
        ('attendance','correction_requests','correction_requests_insert'),
        ('assets','asset_requests','asset_requests_insert')) AS t(s, tb, pn) LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_policies
             WHERE schemaname = v_pol.s AND tablename = v_pol.tb AND policyname = v_pol.pn
               AND cmd = 'INSERT' AND permissive = 'PERMISSIVE'
               AND roles = '{public}'::name[] AND qual IS NULL
               AND with_check = '(employee_id = auth.uid())') THEN
            RAISE EXCEPTION 'ROLLBACK POST-CHECK: %.% not restored exactly', v_pol.tb, v_pol.pn; END IF;
    END LOOP;
    IF has_table_privilege('anon', 'leave.leave_requests', 'INSERT') THEN
        RAISE EXCEPTION 'ROLLBACK POST-CHECK: anon holds INSERT (it must not)'; END IF;
END;
$$;

-- Exact restoration evidence across EVERY touched relation (14 tables + 5 views):
-- authenticated must again hold all 7 privileges (the reviewed pre-P05 baseline),
-- and anon / PUBLIC must hold none of the 6 write-class privileges (nothing extra granted).
DO $$
DECLARE v_rel text; v_priv text; v_checked int := 0;
BEGIN
    FOREACH v_rel IN ARRAY ARRAY['assets.asset_categories','assets.asset_requests','attendance.attendance_days',
        'attendance.correction_requests','core.departments','core.organizations','core.people',
        'core.person_user_links','hr.contract_requests','leave.leave_accruals','leave.leave_adjustments',
        'leave.leave_ledger','leave.leave_requests','leave.leave_types',
        'leave.v_leave_balances','leave.v_leave_request_approvals','attendance.v_correction_request_approvals',
        'assets.v_asset_request_approvals','hr.v_contract_approvals'] LOOP
        FOREACH v_priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF NOT has_table_privilege('authenticated', v_rel, v_priv) THEN
                RAISE EXCEPTION 'ROLLBACK POST-CHECK: authenticated missing % on % (not restored)', v_priv, v_rel; END IF;
            v_checked := v_checked + 1;
        END LOOP;
        FOREACH v_priv IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('anon', v_rel, v_priv) THEN
                RAISE EXCEPTION 'ROLLBACK POST-CHECK: anon holds % on % (must not)', v_priv, v_rel; END IF;
            IF EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
                        WHERE c.oid = v_rel::regclass AND a.grantee = 0 AND a.privilege_type = v_priv) THEN
                RAISE EXCEPTION 'ROLLBACK POST-CHECK: PUBLIC holds % on % (must not)', v_priv, v_rel; END IF;
        END LOOP;
    END LOOP;
    RAISE NOTICE 'ROLLBACK POST-CHECK PASSED: % authenticated privilege/relation pairs restored; anon and PUBLIC clean on 19 relations', v_checked;
END;
$$;

COMMIT;
-- ========================================================================
-- END P05_privilege_hygiene_and_request_insert_closure_ROLLBACK.sql
-- ========================================================================
