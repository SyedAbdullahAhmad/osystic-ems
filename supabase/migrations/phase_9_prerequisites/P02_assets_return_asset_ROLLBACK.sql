-- ========================================================================
-- P02_assets_return_asset_ROLLBACK.sql
-- Pure function drop. Returns already recorded by the function stay recorded
-- (returned_at values are business data, not part of the function). Roll back
-- P03/P04/offboarding first if they depend on this function.
-- ========================================================================
REVOKE ALL ON FUNCTION "assets"."return_asset"(uuid) FROM "authenticated";
DROP FUNCTION IF EXISTS "assets"."return_asset"(uuid);
