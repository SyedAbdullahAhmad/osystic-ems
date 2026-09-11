-- ========================================================================
-- 006_asset_categories_seed.sql
-- Starter categories so the request form has something to populate
-- immediately. Same actor-integrity constraint as everything else in
-- assets.* applies (created_by forced to auth.uid() by
-- assets._force_created_by(), which raises if auth.uid() IS NULL) - this
-- needs a real admin session too, same as 004/leave's 005_leave_types_seed.sql.
-- NOT a bare migration, despite category rows seeming like static data.
-- ========================================================================

-- SELECT set_config('request.jwt.claims', json_build_object('sub', '<YOUR_ADMIN_USER_ID>', 'role', 'authenticated')::text, true);
   SELECT set_config('request.jwt.claims', json_build_object('sub', '2d48e4e3-fee2-4034-8b8d-a3cce8298ce2', 'role', 'authenticated')::text, true);
INSERT INTO "assets"."asset_categories" ("category_code", "category_name", "description")
SELECT * FROM (VALUES
    ('LAPTOP', 'Laptop', 'Company-issued laptop or notebook computer'),
    ('MONITOR', 'Monitor', 'External display'),
    ('PHONE', 'Mobile Phone', 'Company-issued mobile phone'),
    ('ACCESSORY', 'Accessory', 'Peripherals - keyboard, mouse, headset, dock, etc.')
) AS v("category_code", "category_name", "description")
WHERE NOT EXISTS (
    SELECT 1 FROM "assets"."asset_categories" WHERE "asset_categories"."category_code" = v."category_code"
);

-- A couple of sample inventory units so there's something real to
-- fulfill a request with during testing. Not fictional test-fixture
-- data in the same sense as test-admin - these are meant to become real
-- inventory rows; adjust asset_code/serial_number to your actual stock,
-- or delete these and add real ones via the UI once it exists.
INSERT INTO "assets"."assets" ("asset_category_id", "asset_code", "asset_name", "serial_number")
SELECT ac."id", v."asset_code", v."asset_name", v."serial_number"
FROM (VALUES
    ('LAPTOP', 'LAP-0001', 'Dell Latitude 5440', 'SN-LAP-0001'),
    ('LAPTOP', 'LAP-0002', 'Dell Latitude 5440', 'SN-LAP-0002'),
    ('MONITOR', 'MON-0001', 'Dell 24" Monitor', 'SN-MON-0001')
) AS v("category_code", "asset_code", "asset_name", "serial_number")
JOIN "assets"."asset_categories" ac ON ac."category_code" = v."category_code"
WHERE NOT EXISTS (
    SELECT 1 FROM "assets"."assets" WHERE "assets"."asset_code" = v."asset_code"
);

-- ========================================================================
-- END 006_asset_categories_seed.sql
-- ========================================================================
