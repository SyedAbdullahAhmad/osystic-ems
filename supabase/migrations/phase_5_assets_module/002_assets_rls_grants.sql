-- ========================================================================
-- 002_assets_rls_grants.sql
-- Phase 5: Assets Module - RLS, actor-integrity, views
-- Same pattern as 002_attendance_corrections_rls_grants.sql /
-- 002_leave_rls_grants.sql.
-- ========================================================================

GRANT USAGE ON SCHEMA "assets" TO "authenticated";

ALTER TABLE "assets"."asset_categories" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "assets"."assets" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "assets"."asset_requests" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "assets"."asset_assignments" ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION "assets"."_force_created_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "assets"
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'ASSETS_CREATED_BY_REQUIRES_AUTHENTICATED_SESSION: % requires an authenticated session', TG_TABLE_NAME;
    END IF;
    NEW."created_by" := auth.uid();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "assets"."_force_updated_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "assets"
AS $$
BEGIN
    NEW."updated_by" := auth.uid();
    NEW."updated_at" := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_asset_categories_created_by" ON "assets"."asset_categories";
CREATE TRIGGER "trg_asset_categories_created_by" BEFORE INSERT ON "assets"."asset_categories"
    FOR EACH ROW EXECUTE FUNCTION "assets"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_asset_categories_updated_by" ON "assets"."asset_categories";
CREATE TRIGGER "trg_asset_categories_updated_by" BEFORE UPDATE ON "assets"."asset_categories"
    FOR EACH ROW EXECUTE FUNCTION "assets"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_assets_created_by" ON "assets"."assets";
CREATE TRIGGER "trg_assets_created_by" BEFORE INSERT ON "assets"."assets"
    FOR EACH ROW EXECUTE FUNCTION "assets"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_assets_updated_by" ON "assets"."assets";
CREATE TRIGGER "trg_assets_updated_by" BEFORE UPDATE ON "assets"."assets"
    FOR EACH ROW EXECUTE FUNCTION "assets"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_asset_requests_created_by" ON "assets"."asset_requests";
CREATE TRIGGER "trg_asset_requests_created_by" BEFORE INSERT ON "assets"."asset_requests"
    FOR EACH ROW EXECUTE FUNCTION "assets"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_asset_requests_updated_by" ON "assets"."asset_requests";
CREATE TRIGGER "trg_asset_requests_updated_by" BEFORE UPDATE ON "assets"."asset_requests"
    FOR EACH ROW EXECUTE FUNCTION "assets"."_force_updated_by"();

-- ------------------------------------------------------------------------
-- RLS policies
-- ------------------------------------------------------------------------

-- Categories and inventory are readable by any authenticated employee
-- (needed to populate the request form's category picker); writes are
-- gated to ASSET_MANAGE.
CREATE POLICY "asset_categories_select" ON "assets"."asset_categories" FOR SELECT USING (true);
CREATE POLICY "asset_categories_manage" ON "assets"."asset_categories" FOR ALL
    USING (core.has_permission(auth.uid(), 'ASSET_MANAGE'));

CREATE POLICY "assets_select" ON "assets"."assets" FOR SELECT USING (true);
CREATE POLICY "assets_manage" ON "assets"."assets" FOR ALL
    USING (core.has_permission(auth.uid(), 'ASSET_MANAGE'));

CREATE POLICY "asset_requests_select" ON "assets"."asset_requests"
    FOR SELECT USING (
        "employee_id" = auth.uid()
        OR ("workflow_request_id" IS NOT NULL AND workflow.can_view_request("workflow_request_id"))
        OR core.has_permission(auth.uid(), 'ASSET_VIEW_ALL')
        OR core.has_permission(auth.uid(), 'ASSET_MANAGE')
    );
CREATE POLICY "asset_requests_insert" ON "assets"."asset_requests"
    FOR INSERT WITH CHECK ("employee_id" = auth.uid());
-- No direct UPDATE/DELETE for ordinary users - status transitions happen
-- exclusively through submit/fulfill RPCs and the workflow-outcome
-- trigger (003, all SECURITY DEFINER).

CREATE POLICY "asset_assignments_select" ON "assets"."asset_assignments"
    FOR SELECT USING (
        "employee_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'ASSET_VIEW_ALL')
        OR core.has_permission(auth.uid(), 'ASSET_MANAGE')
    );

-- ------------------------------------------------------------------------
-- Read-only approval-history view, same alternative to a writable
-- approvals table used for leave/attendance.
-- ------------------------------------------------------------------------
CREATE OR REPLACE VIEW "assets"."v_asset_request_approvals"
WITH (security_invoker = true) AS
SELECT
    ar."id" AS "asset_request_id",
    ar."employee_id",
    sh."from_status",
    sh."to_status",
    sh."changed_at",
    sh."reason",
    aa."actor_user_id",
    aa."action",
    aa."comments" AS "action_comments"
FROM "assets"."asset_requests" ar
JOIN "workflow"."status_history" sh ON sh."approval_request_id" = ar."workflow_request_id"
LEFT JOIN "workflow"."approval_actions" aa ON aa."id" = sh."triggered_by_approval_action_id"
ORDER BY sh."changed_at";

-- ========================================================================
-- END 002_assets_rls_grants.sql
-- ========================================================================
