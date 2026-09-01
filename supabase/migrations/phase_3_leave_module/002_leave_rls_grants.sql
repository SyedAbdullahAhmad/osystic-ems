-- ========================================================================
-- 002_leave_rls_grants.sql
-- Phase 2: Leave Module - RLS, actor-integrity, and the balance view
-- ========================================================================

ALTER TABLE "leave"."leave_types" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "leave"."leave_ledger" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "leave"."leave_requests" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "leave"."leave_accruals" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "leave"."leave_adjustments" ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------------
-- Actor integrity - same pattern as workflow._force_created_by()/
-- _force_updated_by(): created_by/updated_by are ALWAYS the real caller,
-- never client-supplied, matching the round-3 fix already proven in the
-- workflow schema.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "leave"."_force_created_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "leave"
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'LEAVE_CREATED_BY_REQUIRES_AUTHENTICATED_SESSION: % requires an authenticated session, not a bare service-role write', TG_TABLE_NAME;
    END IF;
    NEW."created_by" := auth.uid();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "leave"."_force_updated_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "leave"
AS $$
BEGIN
    NEW."updated_by" := auth.uid();
    NEW."updated_at" := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_leave_types_created_by" ON "leave"."leave_types";
CREATE TRIGGER "trg_leave_types_created_by" BEFORE INSERT ON "leave"."leave_types"
    FOR EACH ROW EXECUTE FUNCTION "leave"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_leave_types_updated_by" ON "leave"."leave_types";
CREATE TRIGGER "trg_leave_types_updated_by" BEFORE UPDATE ON "leave"."leave_types"
    FOR EACH ROW EXECUTE FUNCTION "leave"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_leave_requests_created_by" ON "leave"."leave_requests";
CREATE TRIGGER "trg_leave_requests_created_by" BEFORE INSERT ON "leave"."leave_requests"
    FOR EACH ROW EXECUTE FUNCTION "leave"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_leave_requests_updated_by" ON "leave"."leave_requests";
CREATE TRIGGER "trg_leave_requests_updated_by" BEFORE UPDATE ON "leave"."leave_requests"
    FOR EACH ROW EXECUTE FUNCTION "leave"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_leave_ledger_created_by" ON "leave"."leave_ledger";
CREATE TRIGGER "trg_leave_ledger_created_by" BEFORE INSERT ON "leave"."leave_ledger"
    FOR EACH ROW EXECUTE FUNCTION "leave"."_force_created_by"();

-- leave_ledger is APPEND-ONLY, same guarantee as workflow.status_history/
-- workflow.approval_actions - balances must never be editable after the
-- fact, only correctable via a new ADJUSTMENT row.
CREATE OR REPLACE FUNCTION "leave"."_prevent_ledger_mutation"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'LEAVE_LEDGER_IMMUTABLE: % on leave.leave_ledger is not permitted - this table is append-only, correct via a new ADJUSTMENT row instead', TG_OP;
END;
$$;

DROP TRIGGER IF EXISTS "trg_leave_ledger_immutable" ON "leave"."leave_ledger";
CREATE TRIGGER "trg_leave_ledger_immutable"
    BEFORE UPDATE OR DELETE ON "leave"."leave_ledger"
    FOR EACH ROW EXECUTE FUNCTION "leave"."_prevent_ledger_mutation"();

-- ------------------------------------------------------------------------
-- RLS policies
-- ------------------------------------------------------------------------

-- leave_types: everyone authenticated can read; only LEAVE_CONFIG_MANAGE
-- holders can write (mirrors WORKFLOW_CONFIG_MANAGE's pattern exactly).
CREATE POLICY "leave_types_select" ON "leave"."leave_types"
    FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "leave_types_manage" ON "leave"."leave_types"
    FOR ALL USING (core.has_permission(auth.uid(), 'LEAVE_CONFIG_MANAGE'))
    WITH CHECK (core.has_permission(auth.uid(), 'LEAVE_CONFIG_MANAGE'));

-- leave_requests: an employee can see/create their own; an approver can
-- see any request currently assigned to them via the workflow engine
-- (reuses workflow.can_view_request - same visibility rule already
-- proven in 008's rls_visibility suite, just applied to a leave_requests
-- row via its linked workflow_request_id rather than an approval_requests
-- row directly); LEAVE_VIEW_ALL holders (e.g. HR) can see everything.
CREATE POLICY "leave_requests_select" ON "leave"."leave_requests"
    FOR SELECT USING (
        "employee_id" = auth.uid()
        OR ("workflow_request_id" IS NOT NULL AND workflow.can_view_request("workflow_request_id"))
        OR core.has_permission(auth.uid(), 'LEAVE_VIEW_ALL')
    );
CREATE POLICY "leave_requests_insert" ON "leave"."leave_requests"
    FOR INSERT WITH CHECK ("employee_id" = auth.uid());
-- No direct UPDATE/DELETE policy for ordinary authenticated users -
-- status transitions happen exclusively through leave.submit_leave_request()
-- and leave's reaction to workflow outcomes (both SECURITY DEFINER,
-- service_role-executed), matching how workflow.approval_requests itself
-- is never directly writable by "authenticated" either.

-- leave_ledger: an employee can see their own ledger (their balance
-- history); LEAVE_VIEW_ALL holders can see everyone's. No INSERT policy
-- for "authenticated" - only leave.submit_leave_request() and the
-- (future) accrual job write here, both via service_role/SECURITY DEFINER.
CREATE POLICY "leave_ledger_select" ON "leave"."leave_ledger"
    FOR SELECT USING (
        "employee_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'LEAVE_VIEW_ALL')
    );

CREATE POLICY "leave_accruals_select" ON "leave"."leave_accruals"
    FOR SELECT USING (
        "employee_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'LEAVE_VIEW_ALL')
    );
CREATE POLICY "leave_adjustments_select" ON "leave"."leave_adjustments"
    FOR SELECT USING (
        "employee_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'LEAVE_VIEW_ALL')
    );

-- ------------------------------------------------------------------------
-- Balances are ALWAYS derived, never stored - this view is the one
-- correct way to read a balance, per the rule carried from the DBML.
-- security_invoker means it runs with the CALLING user's RLS, not the
-- view owner's - so leave_ledger's own RLS policy above still applies
-- per-row, an employee querying this view only ever sees their own rows
-- summed (or all rows, if they hold LEAVE_VIEW_ALL).
-- ------------------------------------------------------------------------
CREATE OR REPLACE VIEW "leave"."v_leave_balances"
WITH (security_invoker = true) AS
SELECT
    "employee_id",
    "leave_type_id",
    SUM("amount_days") AS "balance_days"
FROM "leave"."leave_ledger"
GROUP BY "employee_id", "leave_type_id";

-- ------------------------------------------------------------------------
-- Read-only approval-history view, joining the workflow tables - this is
-- the explicit alternative to a writable leave.leave_approvals table,
-- per the team lead's instruction. security_invoker so workflow's own
-- RLS (proven in 008) governs visibility, not this view's owner.
-- ------------------------------------------------------------------------
CREATE OR REPLACE VIEW "leave"."v_leave_request_approvals"
WITH (security_invoker = true) AS
SELECT
    lr."id" AS "leave_request_id",
    lr."employee_id",
    sh."from_status",
    sh."to_status",
    sh."changed_at",
    sh."reason",
    aa."actor_user_id",
    aa."action",
    aa."comments" AS "action_comments"
FROM "leave"."leave_requests" lr
JOIN "workflow"."status_history" sh ON sh."approval_request_id" = lr."workflow_request_id"
LEFT JOIN "workflow"."approval_actions" aa ON aa."id" = sh."triggered_by_approval_action_id"
ORDER BY sh."changed_at";

-- ========================================================================
-- END 002_leave_rls_grants.sql
-- ========================================================================
