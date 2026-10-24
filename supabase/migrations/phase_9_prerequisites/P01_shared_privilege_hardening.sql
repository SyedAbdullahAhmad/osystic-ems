-- ========================================================================
-- P01_shared_privilege_hardening.sql   (Phase 9 prerequisite 1 of 4)
--
-- Team-lead decision (Phase 9 reply, item 8): the live schema shows
-- "authenticated" holding EVERY table privilege (DELETE, INSERT,
-- REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE) on five shared tables.
-- TRUNCATE is not subject to row-level security. This migration removes,
-- from "authenticated" (and defensively "anon"), only the privileges the
-- application never needs:
--
--     TRUNCATE, TRIGGER, REFERENCES
--
-- on exactly these tables:
--     hr.employees, hr.contracts, hr.contract_versions,
--     assets.asset_assignments, assets.assets
--
-- DELIBERATELY NOT CHANGED: SELECT, INSERT, UPDATE, DELETE. Narrowing those
-- could regress Leave/Assets/Contracts/People paths; they are tightened
-- separately once usage is proven. No RLS policy, trigger or function is
-- touched.
--
-- Why this is safe for the application:
--   * Nothing in the app issues TRUNCATE (PostgREST cannot).
--   * TRIGGER privilege is only needed to CREATE a trigger on the table
--     (owner/migration time); firing existing triggers needs no privilege.
--   * REFERENCES is only needed to CREATE a foreign key; enforcing an
--     existing FK at DML time runs with the owner's rights.
--
-- Rollback: P01_shared_privilege_hardening_ROLLBACK.sql restores exactly
-- the three removed privileges to "authenticated".
-- ========================================================================

DO $$
DECLARE
    v_t text;
BEGIN
    FOREACH v_t IN ARRAY ARRAY['hr.employees','hr.contracts','hr.contract_versions','assets.asset_assignments','assets.assets'] LOOP
        IF to_regclass(v_t) IS NULL THEN
            RAISE EXCEPTION 'P01: expected table % does not exist - refusing to continue', v_t;
        END IF;
    END LOOP;
END;
$$;

REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."employees"               FROM "authenticated", "anon";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."contracts"               FROM "authenticated", "anon";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."contract_versions"       FROM "authenticated", "anon";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."asset_assignments"   FROM "authenticated", "anon";
REVOKE TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."assets"              FROM "authenticated", "anon";

-- ========================================================================
-- END P01_shared_privilege_hardening.sql
-- ========================================================================
