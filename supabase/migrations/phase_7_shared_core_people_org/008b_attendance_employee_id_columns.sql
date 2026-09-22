-- ========================================================================
-- 008b_attendance_employee_id_columns.sql
-- Phase 7: Add new NULLABLE hr_employee_id columns to Attendance's 2
-- tables, backfilled via the chain built in 006. ADDITIVE ONLY - same
-- reasoning as 008a, applied to attendance.attendance_days and
-- attendance.correction_requests.
-- ========================================================================

ALTER TABLE "attendance"."attendance_days" ADD COLUMN IF NOT EXISTS "hr_employee_id" uuid REFERENCES "hr"."employees"("id");
ALTER TABLE "attendance"."correction_requests" ADD COLUMN IF NOT EXISTS "hr_employee_id" uuid REFERENCES "hr"."employees"("id");

UPDATE "attendance"."attendance_days" ad
SET "hr_employee_id" = e."id"
FROM "hr"."employees" e
JOIN "core"."person_user_links" pul ON pul."person_id" = e."person_id" AND pul."status" = 'ACTIVE'
WHERE pul."user_id" = ad."employee_id" AND ad."hr_employee_id" IS NULL;

UPDATE "attendance"."correction_requests" cr
SET "hr_employee_id" = e."id"
FROM "hr"."employees" e
JOIN "core"."person_user_links" pul ON pul."person_id" = e."person_id" AND pul."status" = 'ACTIVE'
WHERE pul."user_id" = cr."employee_id" AND cr."hr_employee_id" IS NULL;

CREATE INDEX IF NOT EXISTS "idx_attendance_days_hr_employee" ON "attendance"."attendance_days"("hr_employee_id");
CREATE INDEX IF NOT EXISTS "idx_correction_requests_hr_employee" ON "attendance"."correction_requests"("hr_employee_id");

SELECT 'attendance_days' AS "table", count(*) FROM "attendance"."attendance_days" WHERE "hr_employee_id" IS NULL
UNION ALL SELECT 'correction_requests', count(*) FROM "attendance"."correction_requests" WHERE "hr_employee_id" IS NULL;
-- expect zero rows from each

-- ========================================================================
-- END 008b_attendance_employee_id_columns.sql
-- ========================================================================
