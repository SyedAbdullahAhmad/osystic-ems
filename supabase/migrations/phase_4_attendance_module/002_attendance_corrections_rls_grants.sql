-- ========================================================================
-- 002_attendance_corrections_rls_grants.sql
-- Phase 4: Attendance Corrections Module - RLS, actor-integrity, views
-- Mirrors 002_leave_rls_grants.sql's proven pattern exactly.
-- ========================================================================

GRANT USAGE ON SCHEMA "attendance" TO "authenticated";

ALTER TABLE "attendance"."attendance_days" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "attendance"."correction_requests" ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------------
-- Actor integrity - same pattern as leave._force_created_by()/
-- _force_updated_by() and workflow._force_created_by(): created_by/
-- updated_by are ALWAYS the real caller, never client-supplied.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "attendance"."_force_created_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "attendance"
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_CREATED_BY_REQUIRES_AUTHENTICATED_SESSION: % requires an authenticated session, not a bare service-role write', TG_TABLE_NAME;
    END IF;
    NEW."created_by" := auth.uid();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "attendance"."_force_updated_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "attendance"
AS $$
BEGIN
    NEW."updated_by" := auth.uid();
    NEW."updated_at" := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_attendance_days_created_by" ON "attendance"."attendance_days";
CREATE TRIGGER "trg_attendance_days_created_by" BEFORE INSERT ON "attendance"."attendance_days"
    FOR EACH ROW EXECUTE FUNCTION "attendance"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_attendance_days_updated_by" ON "attendance"."attendance_days";
CREATE TRIGGER "trg_attendance_days_updated_by" BEFORE UPDATE ON "attendance"."attendance_days"
    FOR EACH ROW EXECUTE FUNCTION "attendance"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_correction_requests_created_by" ON "attendance"."correction_requests";
CREATE TRIGGER "trg_correction_requests_created_by" BEFORE INSERT ON "attendance"."correction_requests"
    FOR EACH ROW EXECUTE FUNCTION "attendance"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_correction_requests_updated_by" ON "attendance"."correction_requests";
CREATE TRIGGER "trg_correction_requests_updated_by" BEFORE UPDATE ON "attendance"."correction_requests"
    FOR EACH ROW EXECUTE FUNCTION "attendance"."_force_updated_by"();

-- ------------------------------------------------------------------------
-- RLS policies
-- ------------------------------------------------------------------------

-- attendance_days: an employee sees their own record; ATTENDANCE_VIEW_ALL
-- holders (e.g. HR/managers) see everyone's. No direct INSERT/UPDATE
-- policy for "authenticated" - rows are only created/mutated via
-- attendance.submit_correction_request() and the workflow-outcome
-- trigger (both SECURITY DEFINER), same pattern as leave_requests never
-- being directly writable either. A future check-in/NFC pipeline would
-- write here via service_role.
CREATE POLICY "attendance_days_select" ON "attendance"."attendance_days"
    FOR SELECT USING (
        "employee_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'ATTENDANCE_VIEW_ALL')
    );

-- correction_requests: an employee can see/create their own; an approver
-- can see any request currently assigned to them via the workflow engine
-- (workflow.can_view_request, same proven visibility rule leave_requests
-- reuses); ATTENDANCE_VIEW_ALL holders see everything.
CREATE POLICY "correction_requests_select" ON "attendance"."correction_requests"
    FOR SELECT USING (
        "employee_id" = auth.uid()
        OR ("workflow_request_id" IS NOT NULL AND workflow.can_view_request("workflow_request_id"))
        OR core.has_permission(auth.uid(), 'ATTENDANCE_VIEW_ALL')
    );
CREATE POLICY "correction_requests_insert" ON "attendance"."correction_requests"
    FOR INSERT WITH CHECK ("employee_id" = auth.uid());
-- No direct UPDATE/DELETE policy for ordinary authenticated users - status
-- transitions happen exclusively through
-- attendance.submit_correction_request() and the reaction to workflow
-- outcomes below (both SECURITY DEFINER / service_role-executed).

-- ------------------------------------------------------------------------
-- Read-only approval-history view, joining the workflow tables - same
-- alternative to a writable approvals table used for leave
-- (leave.v_leave_request_approvals). security_invoker so workflow's own
-- proven RLS governs visibility, not this view's owner.
-- ------------------------------------------------------------------------
CREATE OR REPLACE VIEW "attendance"."v_correction_request_approvals"
WITH (security_invoker = true) AS
SELECT
    cr."id" AS "correction_request_id",
    cr."employee_id",
    sh."from_status",
    sh."to_status",
    sh."changed_at",
    sh."reason",
    aa."actor_user_id",
    aa."action",
    aa."comments" AS "action_comments"
FROM "attendance"."correction_requests" cr
JOIN "workflow"."status_history" sh ON sh."approval_request_id" = cr."workflow_request_id"
LEFT JOIN "workflow"."approval_actions" aa ON aa."id" = sh."triggered_by_approval_action_id"
ORDER BY sh."changed_at";

-- ========================================================================
-- END 002_attendance_corrections_rls_grants.sql
-- ========================================================================
