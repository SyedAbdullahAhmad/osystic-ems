-- ========================================================================
-- 002_contracts_rls_grants.sql
-- Phase 6: Contracts Module - RLS, actor-integrity, view
-- Same pattern as 002_assets_rls_grants.sql / 002_attendance_corrections_
-- rls_grants.sql / 002_leave_rls_grants.sql.
-- ========================================================================

GRANT USAGE ON SCHEMA "hr" TO "authenticated";

ALTER TABLE "hr"."contracts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "hr"."contract_versions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "hr"."contract_requests" ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION "hr"."_force_created_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "hr"
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'CONTRACTS_CREATED_BY_REQUIRES_AUTHENTICATED_SESSION: % requires an authenticated session', TG_TABLE_NAME;
    END IF;
    NEW."created_by" := auth.uid();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "hr"."_force_updated_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "hr"
AS $$
BEGIN
    NEW."updated_by" := auth.uid();
    NEW."updated_at" := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_contracts_created_by" ON "hr"."contracts";
CREATE TRIGGER "trg_contracts_created_by" BEFORE INSERT ON "hr"."contracts"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_contracts_updated_by" ON "hr"."contracts";
CREATE TRIGGER "trg_contracts_updated_by" BEFORE UPDATE ON "hr"."contracts"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_contract_requests_created_by" ON "hr"."contract_requests";
CREATE TRIGGER "trg_contract_requests_created_by" BEFORE INSERT ON "hr"."contract_requests"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_contract_requests_updated_by" ON "hr"."contract_requests";
CREATE TRIGGER "trg_contract_requests_updated_by" BEFORE UPDATE ON "hr"."contract_requests"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_force_updated_by"();

-- contract_versions has no updated_by/updated_at (rows are immutable
-- once written - a new version is a new row, never an edit), so only
-- created_by is forced here.
DROP TRIGGER IF EXISTS "trg_contract_versions_created_by" ON "hr"."contract_versions";
CREATE TRIGGER "trg_contract_versions_created_by" BEFORE INSERT ON "hr"."contract_versions"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_force_created_by"();

-- ------------------------------------------------------------------------
-- RLS policies
-- ------------------------------------------------------------------------

-- The employee a contract is FOR can see their own contract (read-only)
-- even though they didn't create it (HR/Admin-initiated, per design) -
-- same as how an employee can see their own leave/attendance/asset
-- records without having approval rights over them.
CREATE POLICY "contracts_select" ON "hr"."contracts"
    FOR SELECT USING (
        "employee_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'CONTRACT_VIEW_ALL')
        OR core.has_permission(auth.uid(), 'CONTRACT_MANAGE')
        OR EXISTS (
            SELECT 1 FROM "hr"."contract_requests" cr
            WHERE cr."contract_id" = "hr"."contracts"."id"
              AND cr."workflow_request_id" IS NOT NULL
              AND workflow.can_view_request(cr."workflow_request_id")
        )
    );
CREATE POLICY "contracts_manage" ON "hr"."contracts" FOR ALL
    USING (core.has_permission(auth.uid(), 'CONTRACT_MANAGE'));
-- No direct INSERT/UPDATE for ordinary users - creation and status
-- transitions happen exclusively through the create-and-submit RPC (003)
-- and the workflow-outcome trigger, both SECURITY DEFINER.

CREATE POLICY "contract_versions_select" ON "hr"."contract_versions"
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM "hr"."contracts" c
            WHERE c."id" = "hr"."contract_versions"."contract_id"
              AND (
                  c."employee_id" = auth.uid()
                  OR core.has_permission(auth.uid(), 'CONTRACT_VIEW_ALL')
                  OR core.has_permission(auth.uid(), 'CONTRACT_MANAGE')
              )
        )
    );
CREATE POLICY "contract_versions_manage" ON "hr"."contract_versions" FOR ALL
    USING (core.has_permission(auth.uid(), 'CONTRACT_MANAGE'));

CREATE POLICY "contract_requests_select" ON "hr"."contract_requests"
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM "hr"."contracts" c
            WHERE c."id" = "hr"."contract_requests"."contract_id"
              AND c."employee_id" = auth.uid()
        )
        OR ("workflow_request_id" IS NOT NULL AND workflow.can_view_request("workflow_request_id"))
        OR core.has_permission(auth.uid(), 'CONTRACT_VIEW_ALL')
        OR core.has_permission(auth.uid(), 'CONTRACT_MANAGE')
    );
-- No direct INSERT/UPDATE for ordinary users - same reasoning as contracts.

-- ------------------------------------------------------------------------
-- Read-only approval-history view, same pattern as
-- assets.v_asset_request_approvals. Joined through contract_requests
-- since contracts itself carries no workflow_request_id column.
-- ------------------------------------------------------------------------
CREATE OR REPLACE VIEW "hr"."v_contract_approvals"
WITH (security_invoker = true) AS
SELECT
    cr."contract_id",
    cr."id" AS "contract_request_id",
    c."employee_id",
    sh."from_status",
    sh."to_status",
    sh."changed_at",
    sh."reason",
    aa."actor_user_id",
    aa."action",
    aa."comments" AS "action_comments"
FROM "hr"."contract_requests" cr
JOIN "hr"."contracts" c ON c."id" = cr."contract_id"
JOIN "workflow"."status_history" sh ON sh."approval_request_id" = cr."workflow_request_id"
LEFT JOIN "workflow"."approval_actions" aa ON aa."id" = sh."triggered_by_approval_action_id"
ORDER BY sh."changed_at";

-- ========================================================================
-- END 002_contracts_rls_grants.sql
-- ========================================================================
