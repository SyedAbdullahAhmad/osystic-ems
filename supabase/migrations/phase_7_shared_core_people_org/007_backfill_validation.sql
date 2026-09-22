-- ========================================================================
-- 007_backfill_validation.sql
-- Phase 7: Backfill validation - READ-ONLY. Run every query below and
-- paste the output back before proceeding to 008a+. Per proposal v2 S5
-- rollback criterion: if ANY check here fails, STOP - do not proceed.
-- Since 001-006 only add new rows/tables, rollback at this point is
-- simply dropping what 006 added; the four live modules are completely
-- unaffected either way, since they haven't been touched yet.
--
-- Check 0 added in this revision - direct evidence that 006's
-- deterministic, id-keyed backfill produced exactly one person/link
-- per eligible user, with no email-based ambiguity anywhere in the
-- result (the team lead's review concern on the original version).
-- ========================================================================

-- Check 0 - determinism evidence: every ACTIVE person_user_links row
-- backfilled maps to exactly one core.people row, and no two distinct
-- eligible users ended up pointing at the same person record.
SELECT "person_id", count(*) AS "n_users_pointing_at_this_person"
FROM "core"."person_user_links"
WHERE "status" = 'ACTIVE'
GROUP BY "person_id"
HAVING count(*) > 1;
-- expect: zero rows (duplicated by Check 2 below, kept here too since
-- this is the specific evidence the team lead asked for)

-- Check 1 - row-count / no-orphans / no-duplicates: one core.people row
-- and one ACTIVE person_user_links row per distinct employee_id
-- referenced across all 9 tables. Expect eligible_count,
-- linked_people_count, and hr_employees_count to all be equal.
WITH "eligible" AS (
    SELECT DISTINCT "employee_id" FROM "leave"."leave_requests"
    UNION SELECT DISTINCT "employee_id" FROM "leave"."leave_ledger"
    UNION SELECT DISTINCT "employee_id" FROM "leave"."leave_accruals"
    UNION SELECT DISTINCT "employee_id" FROM "leave"."leave_adjustments"
    UNION SELECT DISTINCT "employee_id" FROM "attendance"."attendance_days"
    UNION SELECT DISTINCT "employee_id" FROM "attendance"."correction_requests"
    UNION SELECT DISTINCT "employee_id" FROM "assets"."asset_requests"
    UNION SELECT DISTINCT "employee_id" FROM "assets"."asset_assignments"
    UNION SELECT DISTINCT "employee_id" FROM "hr"."contracts"
)
SELECT
    (SELECT count(*) FROM "eligible" e JOIN "auth"."users" u ON u."id" = e."employee_id") AS "eligible_count",
    (SELECT count(*) FROM "core"."person_user_links" WHERE "status" = 'ACTIVE'
        AND "user_id" IN (SELECT "employee_id" FROM "eligible")) AS "linked_people_count",
    (SELECT count(*) FROM "hr"."employees" e
        JOIN "core"."person_user_links" pul ON pul."person_id" = e."person_id" AND pul."status" = 'ACTIVE'
        WHERE pul."user_id" IN (SELECT "employee_id" FROM "eligible")) AS "hr_employees_count";

-- Check 2 - zero duplicate ACTIVE links per person, and per user
-- (should already be impossible given the partial unique indexes from
-- 001, but confirmed here with real data, not assumed).
SELECT "person_id", count(*) FROM "core"."person_user_links"
WHERE "status" = 'ACTIVE' GROUP BY "person_id" HAVING count(*) > 1;
-- expect: zero rows
SELECT "user_id", count(*) FROM "core"."person_user_links"
WHERE "status" = 'ACTIVE' GROUP BY "user_id" HAVING count(*) > 1;
-- expect: zero rows

-- Check 3 - spot-check the test employee (ed761a27-...) resolves back
-- through the full chain to the same auth.users id.
SELECT
    u."id" AS "auth_user_id",
    u."email",
    pul."person_id",
    pul."status" AS "link_status",
    p."full_name",
    e."id" AS "hr_employee_id",
    e."employment_status"
FROM "auth"."users" u
JOIN "core"."person_user_links" pul ON pul."user_id" = u."id" AND pul."status" = 'ACTIVE'
JOIN "core"."people" p ON p."id" = pul."person_id"
JOIN "hr"."employees" e ON e."person_id" = p."id"
WHERE u."id" = 'ed761a27-783e-43d2-8fcd-ac2f64b29249';
-- expect: exactly one row, hr_employee_id populated

-- Check 4 - confirm LOCAL_TEST_ADMIN was correctly EXCLUDED (per the
-- confirmed backfill-eligibility rule - it never appears as employee_id
-- in any of the 9 tables, only as an actor/approver).
SELECT count(*) AS "should_be_zero" FROM "core"."person_user_links"
WHERE "user_id" = '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2';
-- expect: 0

-- ========================================================================
-- END 007_backfill_validation.sql
-- ========================================================================
