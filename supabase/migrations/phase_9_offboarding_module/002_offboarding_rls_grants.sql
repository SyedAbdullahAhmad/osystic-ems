-- ========================================================================
-- 002_offboarding_rls_grants.sql  -  default-deny: no direct table access for app roles
-- All reads go through SECURITY DEFINER projections (009) so reason visibility is enforced
-- in the database, never only in the UI. All writes go through RPCs (005-008).
-- RLS is ENABLED (defence in depth) but, like the other modules, NOT forced: owner-run
-- SECURITY DEFINER functions must keep working. No policies exist => app roles see nothing.
-- ========================================================================
BEGIN;

DO $$
DECLARE v_t text;
BEGIN
    IF to_regnamespace('offboarding') IS NULL THEN RAISE EXCEPTION '002 PRE-FLIGHT: run 001 first'; END IF;
    FOREACH v_t IN ARRAY ARRAY['cases','clearance_tasks','request_idempotency','case_history','outbox_events','outbox_delivery'] LOOP
        IF to_regclass('offboarding.' || v_t) IS NULL THEN RAISE EXCEPTION '002 PRE-FLIGHT: offboarding.% missing', v_t; END IF;
        IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'offboarding' AND tablename = v_t) THEN
            RAISE EXCEPTION '002 PRE-FLIGHT: unexpected policy on offboarding.%', v_t; END IF;
    END LOOP;
    -- 001 already closed the internal functions; assert that baseline (the REVOKE below is defensive only)
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname LIKE E'\\_%'
                  AND (p.proacl IS NULL OR has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))) THEN
        RAISE EXCEPTION '002 PRE-FLIGHT: an internal trigger function is still executable by an app role - 001 must harden it'; END IF;
END;
$$;

REVOKE ALL ON SCHEMA "offboarding" FROM PUBLIC, "anon";
GRANT USAGE ON SCHEMA "offboarding" TO "authenticated";

ALTER TABLE "offboarding"."cases"               ENABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."clearance_tasks"     ENABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."request_idempotency" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."case_history"        ENABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."outbox_events"       ENABLE ROW LEVEL SECURITY;
ALTER TABLE "offboarding"."outbox_delivery"     ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON ALL TABLES    IN SCHEMA "offboarding" FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA "offboarding" FROM PUBLIC, "anon", "authenticated";

DO $$
DECLARE v_t text; v_priv text;
BEGIN
    IF NOT has_schema_privilege('authenticated', 'offboarding', 'USAGE') THEN RAISE EXCEPTION '002 POST-CHECK: authenticated lacks USAGE on schema'; END IF;
    IF has_schema_privilege('anon', 'offboarding', 'USAGE') OR has_schema_privilege('anon', 'offboarding', 'CREATE')
       OR has_schema_privilege('authenticated', 'offboarding', 'CREATE') THEN RAISE EXCEPTION '002 POST-CHECK: unexpected schema privilege'; END IF;
    FOREACH v_t IN ARRAY ARRAY['cases','clearance_tasks','request_idempotency','case_history','outbox_events','outbox_delivery'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = ('offboarding.' || v_t)::regclass AND relrowsecurity AND NOT relforcerowsecurity) THEN
            RAISE EXCEPTION '002 POST-CHECK: RLS on offboarding.% is not (enabled, not forced)', v_t; END IF;
        FOREACH v_priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('authenticated', 'offboarding.' || v_t, v_priv) OR has_table_privilege('anon', 'offboarding.' || v_t, v_priv) THEN
                RAISE EXCEPTION '002 POST-CHECK: an app role holds % on offboarding.%', v_priv, v_t; END IF;
            IF EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
                        WHERE c.oid = ('offboarding.' || v_t)::regclass AND a.grantee = 0 AND a.privilege_type = v_priv) THEN
                RAISE EXCEPTION '002 POST-CHECK: PUBLIC holds % on offboarding.%', v_priv, v_t; END IF;
        END LOOP;
    END LOOP;
END;
$$;

COMMIT;
-- ========================================================================
-- END 002_offboarding_rls_grants.sql
-- ========================================================================
