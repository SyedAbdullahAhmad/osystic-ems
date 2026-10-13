-- ========================================================================
-- 005_onboarding_permissions_seed_ROLLBACK.sql  (v3 - corrected per
-- Arslan's round-2 review, item 3)
-- Deletes ONLY the exact core.permissions row ids this migration's own
-- provenance rows name - never inferred from code match or from
-- current absence of role_permissions references. If 005 never
-- actually inserted a row for a given code (it already existed), no
-- provenance row exists for it, and this script correctly leaves it
-- alone.
--
-- The role_permissions safety check from round 1 is KEPT as an
-- additional guard on top of provenance, not replaced by it - even a
-- permission this migration genuinely created should not be deleted
-- out from under an active grant.
--
-- Run as part of the corrected order (round 2, item 4): AFTER 004's
-- rollback, not before - 004's rollback is what actually removes the
-- workflow rows that reference 'ONBOARDING_MANAGE' by code.
-- ========================================================================

DO $$
DECLARE
    v_permission_ids uuid[];
BEGIN
    SELECT array_agg(DISTINCT "record_id") INTO v_permission_ids
    FROM "workflow"."_seed_provenance"
    WHERE "seeded_by_migration" = '005_onboarding_permissions_seed'
      AND "schema_name" = 'core' AND "table_name" = 'permissions';

    IF v_permission_ids IS NULL OR array_length(v_permission_ids, 1) IS NULL THEN
        RAISE NOTICE 'No workflow._seed_provenance rows recorded for 005_onboarding_permissions_seed - nothing to roll back.';
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM "core"."role_permissions"
        WHERE "permission_id" = ANY(v_permission_ids)
    ) THEN
        RAISE EXCEPTION 'ONBOARDING_PERMISSIONS_ROLLBACK_BLOCKED: at least one of this migration''s own permission rows is still granted to a role via core.role_permissions. Revoke those grants first, then re-run this rollback.';
    END IF;

    DELETE FROM "core"."permissions" WHERE "id" = ANY(v_permission_ids);

    DELETE FROM "workflow"."_seed_provenance"
    WHERE "seeded_by_migration" = '005_onboarding_permissions_seed';

    RAISE NOTICE 'ONBOARDING_MANAGE/ONBOARDING_VIEW_ALL permission row(s) removed (ids: %).', v_permission_ids;
END;
$$;

-- ========================================================================
-- END 005_onboarding_permissions_seed_ROLLBACK.sql
-- ========================================================================
