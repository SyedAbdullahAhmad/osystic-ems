-- ========================================================================
-- 008a_leave_employee_id_columns.sql
-- Phase 7: Add new NULLABLE hr_employee_id columns to Leave's 4 tables,
-- backfilled via the chain built in 006. ADDITIVE ONLY - the existing
-- employee_id (-> auth.users.id) column is untouched, still NOT NULL,
-- still fully functional. Nothing reads the new column yet (that's
-- 009a); this file only creates and populates it.
--
-- Named hr_employee_id (not employee_id) deliberately - the legacy
-- employee_id column already occupies that name on each of these
-- tables, and cannot be renamed until 011.
--
-- IMPORTANT: leave.leave_ledger is NOT backfilled here, deliberately.
-- Discovered on first live run: leave_ledger has a BEFORE UPDATE OR
-- DELETE trigger (trg_leave_ledger_immutable /
-- leave._prevent_ledger_mutation(), from
-- phase_3_leave_module/002_leave_rls_grants.sql) that unconditionally
-- rejects any UPDATE - "balances must never be editable after the
-- fact, only correctable via a new ADJUSTMENT row", by explicit design.
-- Bypassing that trigger (ALTER TABLE ... DISABLE TRIGGER) just to
-- backfill a new column was considered and rejected - it defeats a
-- deliberate audit-integrity guarantee for a cosmetic backfill benefit,
-- and isn't necessary: the column is still added below, still
-- nullable, and any EXISTING ledger row simply keeps hr_employee_id =
-- NULL permanently - which is the historically correct state for a
-- row that predates the shared-core model existing at all. Every NEW
-- ledger row from 009a onward DOES get it populated (009a inserts it
-- directly at creation time, never via UPDATE). See 010's Check 1 note
-- for the corresponding validation-expectation update.
-- ========================================================================

ALTER TABLE "leave"."leave_requests" ADD COLUMN IF NOT EXISTS "hr_employee_id" uuid REFERENCES "hr"."employees"("id");
ALTER TABLE "leave"."leave_ledger" ADD COLUMN IF NOT EXISTS "hr_employee_id" uuid REFERENCES "hr"."employees"("id");
ALTER TABLE "leave"."leave_accruals" ADD COLUMN IF NOT EXISTS "hr_employee_id" uuid REFERENCES "hr"."employees"("id");
ALTER TABLE "leave"."leave_adjustments" ADD COLUMN IF NOT EXISTS "hr_employee_id" uuid REFERENCES "hr"."employees"("id");

UPDATE "leave"."leave_requests" lr
SET "hr_employee_id" = e."id"
FROM "hr"."employees" e
JOIN "core"."person_user_links" pul ON pul."person_id" = e."person_id" AND pul."status" = 'ACTIVE'
WHERE pul."user_id" = lr."employee_id" AND lr."hr_employee_id" IS NULL;

-- leave_ledger: NO backfill UPDATE here - see header. Column added
-- above (so 009a's future inserts have somewhere to write), existing
-- rows stay NULL, permanently, by design.

UPDATE "leave"."leave_accruals" la
SET "hr_employee_id" = e."id"
FROM "hr"."employees" e
JOIN "core"."person_user_links" pul ON pul."person_id" = e."person_id" AND pul."status" = 'ACTIVE'
WHERE pul."user_id" = la."employee_id" AND la."hr_employee_id" IS NULL;

UPDATE "leave"."leave_adjustments" ladj
SET "hr_employee_id" = e."id"
FROM "hr"."employees" e
JOIN "core"."person_user_links" pul ON pul."person_id" = e."person_id" AND pul."status" = 'ACTIVE'
WHERE pul."user_id" = ladj."employee_id" AND ladj."hr_employee_id" IS NULL;

CREATE INDEX IF NOT EXISTS "idx_leave_requests_hr_employee" ON "leave"."leave_requests"("hr_employee_id");
CREATE INDEX IF NOT EXISTS "idx_leave_ledger_hr_employee" ON "leave"."leave_ledger"("hr_employee_id");
CREATE INDEX IF NOT EXISTS "idx_leave_accruals_hr_employee" ON "leave"."leave_accruals"("hr_employee_id");
CREATE INDEX IF NOT EXISTS "idx_leave_adjustments_hr_employee" ON "leave"."leave_adjustments"("hr_employee_id");

-- Row-level check - leave_requests/leave_accruals/leave_adjustments
-- should all show zero unresolved. leave_ledger is EXPECTED to show
-- its full existing row count here (every pre-cutover row is
-- permanently NULL, by design) - that is a pass, not a failure, for
-- this one table only. See header.
SELECT 'leave_requests' AS "table", count(*) FROM "leave"."leave_requests" WHERE "hr_employee_id" IS NULL
UNION ALL SELECT 'leave_ledger (EXPECTED: pre-existing row count, see header)', count(*) FROM "leave"."leave_ledger" WHERE "hr_employee_id" IS NULL
UNION ALL SELECT 'leave_accruals', count(*) FROM "leave"."leave_accruals" WHERE "hr_employee_id" IS NULL
UNION ALL SELECT 'leave_adjustments', count(*) FROM "leave"."leave_adjustments" WHERE "hr_employee_id" IS NULL;

-- ========================================================================
-- END 008a_leave_employee_id_columns.sql
-- ========================================================================
