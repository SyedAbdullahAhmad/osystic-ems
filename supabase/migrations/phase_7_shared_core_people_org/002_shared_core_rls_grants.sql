-- ========================================================================
-- 002_shared_core_rls_grants.sql
-- Phase 7: Shared-Core People/Organization Model - RLS, actor-integrity
-- Same pattern as 002_assets_rls_grants.sql / 002_contracts_rls_grants.sql
-- / 002_attendance_corrections_rls_grants.sql / 002_leave_rls_grants.sql.
-- Policies match SHARED_CORE_PEOPLE_ORG_PROPOSAL_v2.md S3 exactly.
-- ========================================================================

GRANT USAGE ON SCHEMA "core" TO "authenticated";

ALTER TABLE "core"."organizations" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "core"."people" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "core"."person_user_links" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "core"."departments" ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION "core"."_force_created_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "core"
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'SHARED_CORE_CREATED_BY_REQUIRES_AUTHENTICATED_SESSION: % requires an authenticated session', TG_TABLE_NAME;
    END IF;
    NEW."created_by" := auth.uid();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "core"."_force_updated_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "core"
AS $$
BEGIN
    NEW."updated_by" := auth.uid();
    NEW."updated_at" := now();
    RETURN NEW;
END;
$$;

-- NOTE: the seed row inserted at the end of 001 (core.organizations,
-- code = 'OSYSTIC') was written BEFORE these triggers existed and
-- necessarily has created_by = NULL - there is no authenticated session
-- at that point in a fresh migration run. This is expected and matches
-- the same allowance every prior module's own bootstrap/seed data has
-- had (e.g. assets.asset_categories seeded with created_by populated
-- only because 006_asset_categories_seed.sql runs as an admin session
-- AFTER its trigger exists; this seed row runs INSIDE 001, before 002's
-- trigger exists, so it is the one deliberate exception).

DROP TRIGGER IF EXISTS "trg_organizations_created_by" ON "core"."organizations";
CREATE TRIGGER "trg_organizations_created_by" BEFORE INSERT ON "core"."organizations"
    FOR EACH ROW EXECUTE FUNCTION "core"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_organizations_updated_by" ON "core"."organizations";
CREATE TRIGGER "trg_organizations_updated_by" BEFORE UPDATE ON "core"."organizations"
    FOR EACH ROW EXECUTE FUNCTION "core"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_people_created_by" ON "core"."people";
CREATE TRIGGER "trg_people_created_by" BEFORE INSERT ON "core"."people"
    FOR EACH ROW EXECUTE FUNCTION "core"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_people_updated_by" ON "core"."people";
CREATE TRIGGER "trg_people_updated_by" BEFORE UPDATE ON "core"."people"
    FOR EACH ROW EXECUTE FUNCTION "core"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_person_user_links_created_by" ON "core"."person_user_links";
CREATE TRIGGER "trg_person_user_links_created_by" BEFORE INSERT ON "core"."person_user_links"
    FOR EACH ROW EXECUTE FUNCTION "core"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_person_user_links_updated_by" ON "core"."person_user_links";
CREATE TRIGGER "trg_person_user_links_updated_by" BEFORE UPDATE ON "core"."person_user_links"
    FOR EACH ROW EXECUTE FUNCTION "core"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_departments_created_by" ON "core"."departments";
CREATE TRIGGER "trg_departments_created_by" BEFORE INSERT ON "core"."departments"
    FOR EACH ROW EXECUTE FUNCTION "core"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_departments_updated_by" ON "core"."departments";
CREATE TRIGGER "trg_departments_updated_by" BEFORE UPDATE ON "core"."departments"
    FOR EACH ROW EXECUTE FUNCTION "core"."_force_updated_by"();

-- ------------------------------------------------------------------------
-- RLS policies - exactly per proposal v2 S3
-- ------------------------------------------------------------------------

-- core.organizations - SELECT: all authenticated (low-sensitivity
-- reference data). INSERT/UPDATE: PEOPLE_MANAGE, expected rare.
CREATE POLICY "organizations_select" ON "core"."organizations" FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "organizations_manage" ON "core"."organizations" FOR ALL
    USING (core.has_permission(auth.uid(), 'PEOPLE_MANAGE'));

-- core.people - SELECT: PEOPLE_MANAGE/PEOPLE_VIEW_ALL holders, or a
-- person viewing their own record (resolved via person_user_links).
-- INSERT/UPDATE: PEOPLE_MANAGE only.
CREATE POLICY "people_select" ON "core"."people"
    FOR SELECT USING (
        core.has_permission(auth.uid(), 'PEOPLE_MANAGE')
        OR core.has_permission(auth.uid(), 'PEOPLE_VIEW_ALL')
        OR "id" IN (
            SELECT "person_id" FROM "core"."person_user_links"
            WHERE "user_id" = auth.uid() AND "status" = 'ACTIVE'
        )
    );
CREATE POLICY "people_insert" ON "core"."people"
    FOR INSERT WITH CHECK (core.has_permission(auth.uid(), 'PEOPLE_MANAGE'));
CREATE POLICY "people_update" ON "core"."people"
    FOR UPDATE USING (core.has_permission(auth.uid(), 'PEOPLE_MANAGE'));

-- core.person_user_links - the security-critical table. SELECT: own
-- link row, or PEOPLE_MANAGE holders. INSERT/UPDATE: PEOPLE_MANAGE
-- holders OR the provisioning RPC (003) only - a SECURITY DEFINER
-- function bypasses RLS entirely by design, so these policies are what
-- stop a plain authenticated client from ever writing this table
-- directly (e.g. linking themselves to an arbitrary person_id and
-- inheriting that person's historical records - the exact risk Umar's
-- review called out). No INSERT/UPDATE policy exists here for an
-- ordinary user at all; only PEOPLE_MANAGE holders get one, everyone
-- else's only path to a row in this table is through the RPC.
CREATE POLICY "person_user_links_select" ON "core"."person_user_links"
    FOR SELECT USING (
        "user_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'PEOPLE_MANAGE')
    );
CREATE POLICY "person_user_links_manage" ON "core"."person_user_links"
    FOR INSERT WITH CHECK (core.has_permission(auth.uid(), 'PEOPLE_MANAGE'));
CREATE POLICY "person_user_links_update" ON "core"."person_user_links"
    FOR UPDATE USING (core.has_permission(auth.uid(), 'PEOPLE_MANAGE'));

-- core.departments - SELECT: all authenticated. INSERT/UPDATE:
-- PEOPLE_MANAGE, consistent with EMS's write-ownership decision.
CREATE POLICY "departments_select" ON "core"."departments" FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "departments_manage" ON "core"."departments" FOR ALL
    USING (core.has_permission(auth.uid(), 'PEOPLE_MANAGE'));

-- ========================================================================
-- END 002_shared_core_rls_grants.sql
-- ========================================================================
