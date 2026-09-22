-- ========================================================================
-- 004_hr_employees_schema.sql
-- Phase 7: hr.employees - EMS-owned, not shared-core (per proposal v2
-- S6: no separate Umar/Arslan sign-off needed for this table
-- specifically, sequenced here because it's a real dependency for the
-- 9-table cutover).
--
-- Matches EMS_part2_revised_v2.dbml's hr.employees definition, with one
-- deliberate omission and one deliberate addition:
--   - OMITTED: sensitive_profile_id (-> hr.employee_sensitive_profiles).
--     That table doesn't exist anywhere in this project yet and nothing
--     in the four live modules needs it - not built speculatively here,
--     same "a slice, not the whole draft" approach as every module.
--   - employment_status enum values (ACTIVE / ON_LEAVE / TERMINATED)
--     are NOT specified anywhere in the DBML or either proposal
--     document - this is my own reasonable default, flagged explicitly
--     rather than silently invented, since nothing upstream defines it.
--     Confirm or adjust before applying if a different set is wanted.
--
-- hr schema already exists (created in phase_1_foundation and reused by
-- phase_6_contracts_module) - this file only adds one new table to it.
-- ADDITIVE ONLY.
-- ========================================================================

CREATE SCHEMA IF NOT EXISTS "hr";

CREATE TYPE "hr"."employment_status" AS ENUM ('ACTIVE', 'ON_LEAVE', 'TERMINATED');

CREATE TABLE IF NOT EXISTS "hr"."employees" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "person_id" uuid NOT NULL REFERENCES "core"."people"("id"),
    "employee_number" varchar(50) UNIQUE,
    "hire_date" date,
    "termination_date" date,
    "employment_status" "hr"."employment_status" NOT NULL DEFAULT 'ACTIVE',
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

-- One hr.employees row per core.people row at most - a person who is
-- an employee has exactly one employee record, never more than one.
CREATE UNIQUE INDEX IF NOT EXISTS "idx_employees_person_unique" ON "hr"."employees"("person_id");

CREATE INDEX IF NOT EXISTS "idx_employees_status" ON "hr"."employees"("employment_status");

GRANT USAGE ON SCHEMA "hr" TO "authenticated";

ALTER TABLE "hr"."employees" ENABLE ROW LEVEL SECURITY;

-- Reuses hr._force_created_by()/hr._force_updated_by() - already exist
-- from phase_6_contracts_module/002_contracts_rls_grants.sql, no need
-- to redefine them for this schema.
DROP TRIGGER IF EXISTS "trg_employees_created_by" ON "hr"."employees";
CREATE TRIGGER "trg_employees_created_by" BEFORE INSERT ON "hr"."employees"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_employees_updated_by" ON "hr"."employees";
CREATE TRIGGER "trg_employees_updated_by" BEFORE UPDATE ON "hr"."employees"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_force_updated_by"();

-- Confirmed: reuses PEOPLE_MANAGE, no separate EMPLOYEE_MANAGE
-- permission (team lead's review-reply confirmation).
CREATE POLICY "employees_select" ON "hr"."employees"
    FOR SELECT USING (
        core.has_permission(auth.uid(), 'PEOPLE_MANAGE')
        OR core.has_permission(auth.uid(), 'PEOPLE_VIEW_ALL')
        OR "person_id" IN (
            SELECT "person_id" FROM "core"."person_user_links"
            WHERE "user_id" = auth.uid() AND "status" = 'ACTIVE'
        )
    );
CREATE POLICY "employees_insert" ON "hr"."employees"
    FOR INSERT WITH CHECK (core.has_permission(auth.uid(), 'PEOPLE_MANAGE'));
CREATE POLICY "employees_update" ON "hr"."employees"
    FOR UPDATE USING (core.has_permission(auth.uid(), 'PEOPLE_MANAGE'));

-- ========================================================================
-- END 004_hr_employees_schema.sql
-- ========================================================================
