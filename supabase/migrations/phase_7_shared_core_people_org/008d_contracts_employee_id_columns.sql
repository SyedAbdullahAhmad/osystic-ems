-- ========================================================================
-- 008d_contracts_employee_id_columns.sql
-- Phase 7: Add new NULLABLE hr_employee_id column to hr.contracts,
-- backfilled via the chain built in 006. ADDITIVE ONLY - same reasoning
-- as 008a. Only 1 table in this module's slice of the 9.
-- ========================================================================

ALTER TABLE "hr"."contracts" ADD COLUMN IF NOT EXISTS "hr_employee_id" uuid REFERENCES "hr"."employees"("id");

UPDATE "hr"."contracts" c
SET "hr_employee_id" = e."id"
FROM "hr"."employees" e
JOIN "core"."person_user_links" pul ON pul."person_id" = e."person_id" AND pul."status" = 'ACTIVE'
WHERE pul."user_id" = c."employee_id" AND c."hr_employee_id" IS NULL;

CREATE INDEX IF NOT EXISTS "idx_contracts_hr_employee" ON "hr"."contracts"("hr_employee_id");

SELECT count(*) AS "unresolved_contracts" FROM "hr"."contracts" WHERE "hr_employee_id" IS NULL;
-- expect zero

-- ========================================================================
-- END 008d_contracts_employee_id_columns.sql
-- ========================================================================
