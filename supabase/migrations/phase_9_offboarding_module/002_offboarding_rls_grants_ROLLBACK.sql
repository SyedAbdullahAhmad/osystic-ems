-- ========================================================================
-- 002_offboarding_rls_grants_ROLLBACK.sql  -  restores the state right after 001
-- (RLS disabled, schema USAGE as created: owner only). Default privileges on new tables
-- gave app roles nothing, so there is nothing to re-grant on tables. The internal trigger
-- functions were already closed by 001, so their ACL is the same before and after 002 and is
-- deliberately NOT re-opened here; the post-check proves it.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regnamespace('offboarding') IS NULL THEN RAISE EXCEPTION '002 ROLLBACK PRE-FLIGHT: schema offboarding missing'; END IF;
    IF NOT has_schema_privilege('authenticated', 'offboarding', 'USAGE') THEN RAISE EXCEPTION '002 ROLLBACK PRE-FLIGHT: 002 does not appear to be applied'; END IF;
END;
$$;

REVOKE USAGE ON SCHEMA "offboarding" FROM "authenticated";
ALTER TABLE "offboarding"."cases"               DISABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."clearance_tasks"     DISABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."request_idempotency" DISABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."case_history"        DISABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."outbox_events"       DISABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."outbox_delivery"     DISABLE ROW LEVEL SECURITY;

DO $$
DECLARE v_t text;
BEGIN
    IF has_schema_privilege('authenticated', 'offboarding', 'USAGE') THEN RAISE EXCEPTION '002 ROLLBACK POST-CHECK: authenticated still has USAGE'; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding'
                  AND (p.proacl IS NULL
                       OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
                       OR has_function_privilege('anon', p.oid, 'EXECUTE')
                       OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))) THEN
        RAISE EXCEPTION '002 ROLLBACK POST-CHECK: function ACLs differ from the post-001 baseline'; END IF;
    FOREACH v_t IN ARRAY ARRAY['cases','clearance_tasks','request_idempotency','case_history','outbox_events','outbox_delivery'] LOOP
        IF EXISTS (SELECT 1 FROM pg_class WHERE oid = ('offboarding.' || v_t)::regclass AND relrowsecurity) THEN
            RAISE EXCEPTION '002 ROLLBACK POST-CHECK: RLS still enabled on offboarding.%', v_t; END IF;
    END LOOP;
END;
$$;

COMMIT;
-- ========================================================================
-- END 002_offboarding_rls_grants_ROLLBACK.sql
-- ========================================================================
