-- ========================================================================
-- P02_assets_return_asset.sql   (Phase 9 prerequisite 2 of 4) - ASSETS-OWNED
--
-- Live schema finding: nothing in Assets can record a return - no function
-- sets asset_assignments.returned_at, and asset_assignments has a SELECT
-- policy only. Team-lead decision: add an Assets-owned controlled function
-- (not under offboarding).
--
-- assets.return_asset(p_assignment_id uuid) returns jsonb
--   * SECURITY DEFINER, pinned search_path (same as fulfill_asset_request)
--   * actor from auth.uid(); requires ASSET_MANAGE
--   * locks the assignment row, then the asset row
--   * assignment already returned  -> idempotent replay (returns the recorded
--     returned_at, changes nothing)
--   * assignment open but the asset is not ASSIGNED -> rejected as inconsistent
--     (two OPEN assignments for one asset cannot exist: the live unique index
--     idx_asset_assignments_one_active_per_asset forbids it, so no extra
--     function-level check is needed)
--   * otherwise sets returned_at = now() and the asset to AVAILABLE in one
--     transaction
--   * PUBLIC revoked, EXECUTE for authenticated only
--
-- Recording a return stays an Assets action (ASSET_MANAGE). It is NOT
-- delegated to any offboarding clearance permission; offboarding only
-- CONFIRMS that no unreturned assignment remains.
--
-- Version handling (team-lead rule): a real state-changing mutation increments
-- "version" exactly once on every row it changes - the assignment AND the
-- asset. An idempotent replay changes nothing (no increment); a rejected call
-- rolls back (no change). (fulfill_asset_request, an older function, does not
-- bump version; that is not the standard for new lifecycle functions.)
-- Uses FOUND, never a whole-record IS NULL / IS NOT NULL test.
-- Rollback: P02_assets_return_asset_ROLLBACK.sql
-- ========================================================================

CREATE OR REPLACE FUNCTION "assets"."return_asset"("p_assignment_id" uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "assets", "core", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_assignment "assets"."asset_assignments";
    v_asset "assets"."assets";
    v_returned_at timestamptz;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'ASSETS_UNAUTHENTICATED: return_asset requires an authenticated session';
    END IF;
    IF NOT core.has_permission(v_actor, 'ASSET_MANAGE') THEN
        RAISE EXCEPTION 'ASSETS_NOT_AUTHORIZED: ASSET_MANAGE required to record an asset return';
    END IF;

    SELECT * INTO v_assignment FROM "assets"."asset_assignments" WHERE "id" = p_assignment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSETS_ASSIGNMENT_NOT_FOUND: no such asset assignment';
    END IF;

    -- Idempotent replay: already returned -> report the recorded fact, change nothing.
    IF v_assignment."returned_at" IS NOT NULL THEN
        RETURN jsonb_build_object(
            'assignment_id', v_assignment."id",
            'asset_id', v_assignment."asset_id",
            'returned_at', v_assignment."returned_at",
            'status', 'RETURNED',
            'idempotent_replay', true
        );
    END IF;

    SELECT * INTO v_asset FROM "assets"."assets" WHERE "id" = v_assignment."asset_id" FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSETS_ASSET_NOT_FOUND: the assignment references a missing asset';
    END IF;
    IF v_asset."current_status" <> 'ASSIGNED' THEN
        RAISE EXCEPTION 'ASSETS_ASSET_STATE_INCONSISTENT: assignment % is open but its asset is % (expected ASSIGNED) - investigate manually', p_assignment_id, v_asset."current_status";
    END IF;
    v_returned_at := now();
    UPDATE "assets"."asset_assignments" SET "returned_at" = v_returned_at, "version" = "version" + 1 WHERE "id" = v_assignment."id";
    UPDATE "assets"."assets" SET "current_status" = 'AVAILABLE', "version" = "version" + 1 WHERE "id" = v_assignment."asset_id";

    RETURN jsonb_build_object(
        'assignment_id', v_assignment."id",
        'asset_id', v_assignment."asset_id",
        'returned_at', v_returned_at,
        'status', 'RETURNED',
        'idempotent_replay', false
    );
END;
$$;

REVOKE ALL ON FUNCTION "assets"."return_asset"(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION "assets"."return_asset"(uuid) FROM "anon";
GRANT EXECUTE ON FUNCTION "assets"."return_asset"(uuid) TO "authenticated";

-- ========================================================================
-- END P02_assets_return_asset.sql
-- ========================================================================
