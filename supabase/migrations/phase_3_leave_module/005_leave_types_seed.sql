-- ========================================================================
-- 005_leave_types_seed.sql
-- Reasonable default leave types. Same actor-integrity constraint as
-- everything else in leave.* applies (created_by forced to auth.uid()),
-- so this ALSO needs to run as an authenticated admin, same as 004 -
-- not a bare migration. Safe to adjust/extend these defaults before
-- running; nothing else in the schema depends on these exact rows.
-- ========================================================================

-- SELECT set_config('request.jwt.claims', json_build_object('sub', '<YOUR_ADMIN_USER_ID>', 'role', 'authenticated')::text, true);
   SELECT set_config('request.jwt.claims', json_build_object('sub', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'role', 'authenticated')::text, true);
INSERT INTO "leave"."leave_types" ("leave_code", "leave_name", "description", "requires_approval", "is_paid", "max_days_per_year")
SELECT * FROM (VALUES
    ('ANNUAL', 'Annual Leave', 'Standard yearly paid leave entitlement', true, true, 20::numeric(6,2)),
    ('SICK', 'Sick Leave', 'Paid leave for illness or medical appointments', true, true, 10::numeric(6,2)),
    ('UNPAID', 'Unpaid Leave', 'Leave without pay, subject to approval', true, false, NULL::numeric(6,2)),
    ('CASUAL', 'Casual Leave', 'Short-notice personal leave', true, true, 5::numeric(6,2))
) AS v("leave_code", "leave_name", "description", "requires_approval", "is_paid", "max_days_per_year")
WHERE NOT EXISTS (
    SELECT 1 FROM "leave"."leave_types" WHERE "leave_types"."leave_code" = v."leave_code"
);

-- ========================================================================
-- END 005_leave_types_seed.sql
-- ========================================================================
