-- ========================================================================
-- 008c_assets_employee_id_columns.sql
-- Phase 7: Add new NULLABLE hr_employee_id columns to Assets' 2 tables,
-- backfilled via the chain built in 006. ADDITIVE ONLY - same reasoning
-- as 008a, applied to assets.asset_requests and assets.asset_assignments.
-- ========================================================================

ALTER TABLE "assets"."asset_requests" ADD COLUMN IF NOT EXISTS "hr_employee_id" uuid REFERENCES "hr"."employees"("id");
ALTER TABLE "assets"."asset_assignments" ADD COLUMN IF NOT EXISTS "hr_employee_id" uuid REFERENCES "hr"."employees"("id");

UPDATE "assets"."asset_requests" ar
SET "hr_employee_id" = e."id"
FROM "hr"."employees" e
JOIN "core"."person_user_links" pul ON pul."person_id" = e."person_id" AND pul."status" = 'ACTIVE'
WHERE pul."user_id" = ar."employee_id" AND ar."hr_employee_id" IS NULL;

UPDATE "assets"."asset_assignments" aa
SET "hr_employee_id" = e."id"
FROM "hr"."employees" e
JOIN "core"."person_user_links" pul ON pul."person_id" = e."person_id" AND pul."status" = 'ACTIVE'
WHERE pul."user_id" = aa."employee_id" AND aa."hr_employee_id" IS NULL;

CREATE INDEX IF NOT EXISTS "idx_asset_requests_hr_employee" ON "assets"."asset_requests"("hr_employee_id");
CREATE INDEX IF NOT EXISTS "idx_asset_assignments_hr_employee" ON "assets"."asset_assignments"("hr_employee_id");

SELECT 'asset_requests' AS "table", count(*) FROM "assets"."asset_requests" WHERE "hr_employee_id" IS NULL
UNION ALL SELECT 'asset_assignments', count(*) FROM "assets"."asset_assignments" WHERE "hr_employee_id" IS NULL;
-- expect zero rows from each

-- ========================================================================
-- END 008c_assets_employee_id_columns.sql
-- ========================================================================
