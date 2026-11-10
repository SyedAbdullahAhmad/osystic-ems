-- ========================================================================
-- 009_offboarding_read_projections.sql  -  controlled read APIs (no raw table SELECT is ever granted)
--   offboarding.list_cases(...)               paged list: status, case type, last-working-date range, search, "awaiting my approval"
--   offboarding.get_case(case)                header + identity + (gated) reasons + (MANAGE/VIEW_ALL) integration-event delivery state
--   offboarding.get_case_tasks(case)          clearance tasks, shaped by the viewer
--   offboarding.get_case_history(case)        timeline, detail whitelisted by the viewer
--   offboarding.get_case_identities(ids)      name / employee number / (gated) email for visible cases
--   offboarding.get_completion_readiness(c)   OFFBOARDING_MANAGE only: what still blocks completion
--   offboarding._case_access(actor, case)     internal: the single visibility decision
-- Visibility (team lead C1/B4):
--   OFFBOARDING_MANAGE and OFFBOARDING_VIEW_ALL see every case; the employee sees their own case through an ACTIVE person link;
--   a workflow approver sees cases the engine actually assigned them; a clearance-permission holder sees APPROVED / IN_CLEARANCE cases
--   and only their own domain's task. No automatic line-manager visibility. A case the viewer may not see is reported exactly like a
--   case that does not exist.
-- Sensitivity:
--   TERMINATION reason_category / reason_detail / cancellation_reason: OFFBOARDING_MANAGE only, forever (also after REJECTED/CANCELLED).
--   RESIGNATION reason_category / reason_detail / withdrawal_reason: OFFBOARDING_MANAGE, and the employee on their own resignation.
--   Waiver / clearance notes: MANAGE (all) or the holder of that domain. Email: MANAGE, VIEW_ALL, own case only.
--   History detail for everyone but MANAGE is a whitelist of non-sensitive keys (the SUBMITTED event stores reason_category!).
--   department / position are always NULL until HR owns an authoritative current-department/position model.
-- Search covers name, employee number and (only where the viewer may see email) email - never reason text.
-- ATOMIC: one transaction; strict pre-flight; post-check.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regprocedure('offboarding.complete_offboarding(uuid,character varying)') IS NULL THEN
        RAISE EXCEPTION '009 PRE-FLIGHT: apply 008 first'; END IF;
    IF to_regclass('workflow.approval_step_assignees') IS NULL OR to_regclass('workflow.approval_steps') IS NULL THEN
        RAISE EXCEPTION '009 PRE-FLIGHT: workflow approval step / assignee tables are missing'; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname IN ('list_cases', 'get_case', 'get_case_tasks', 'get_case_history', 'get_case_identities', 'get_completion_readiness', '_case_access')) THEN
        RAISE EXCEPTION '009 PRE-FLIGHT: 009 objects already exist (already applied?)'; END IF;
END;
$$;

CREATE FUNCTION "offboarding"."_case_access"(p_actor uuid, p_case_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_case record; v_mgr boolean; v_all boolean; v_own boolean; v_appr boolean; v_dom text[]; v_holder boolean;
BEGIN
    SELECT c."id", c."hr_employee_id", c."case_type", c."status", c."workflow_request_id" INTO v_case FROM "offboarding"."cases" c WHERE c."id" = p_case_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    v_mgr := core.has_permission(p_actor, 'OFFBOARDING_MANAGE');
    v_all := core.has_permission(p_actor, 'OFFBOARDING_VIEW_ALL');
    v_own := EXISTS (SELECT 1 FROM "core"."person_user_links" l JOIN "hr"."employees" e ON e."person_id" = l."person_id"
                      WHERE l."user_id" = p_actor AND l."status" = 'ACTIVE' AND e."id" = v_case."hr_employee_id");
    v_appr := v_case."workflow_request_id" IS NOT NULL AND EXISTS (
                SELECT 1 FROM "workflow"."approval_step_assignees" a JOIN "workflow"."approval_steps" s ON s."id" = a."approval_step_id"
                 WHERE s."approval_request_id" = v_case."workflow_request_id" AND a."assignee_user_id" = p_actor);
    SELECT coalesce(array_agg(d ORDER BY d), ARRAY[]::text[]) INTO v_dom
      FROM unnest(ARRAY['ASSETS', 'ACCESS', 'FINANCE', 'HANDOVER', 'HR']) AS d WHERE core.has_permission(p_actor, 'OFFBOARDING_CLEARANCE_' || d);
    v_holder := v_case."status" IN ('APPROVED', 'IN_CLEARANCE') AND cardinality(v_dom) > 0;
    RETURN jsonb_build_object('visible', (v_mgr OR v_all OR v_own OR v_appr OR v_holder), 'is_manager', v_mgr, 'is_view_all', v_all, 'is_own', v_own,
        'is_approver', v_appr, 'is_holder', v_holder, 'domains', to_jsonb(v_dom), 'case_type', v_case."case_type", 'status', v_case."status",
        'hr_employee_id', v_case."hr_employee_id");
END;
$$;

CREATE FUNCTION "offboarding"."get_case"(p_case_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_actor uuid := auth.uid(); v_ctx jsonb; v_case record; v_p record; v_mgr boolean; v_all boolean; v_own boolean; v_res boolean; v_events jsonb;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: get_case requires an authenticated session'; END IF;
    v_ctx := "offboarding"."_case_access"(v_actor, p_case_id);
    IF v_ctx IS NULL OR NOT (v_ctx->>'visible')::boolean THEN RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_FOUND: no such case'; END IF;
    v_mgr := (v_ctx->>'is_manager')::boolean; v_all := (v_ctx->>'is_view_all')::boolean; v_own := (v_ctx->>'is_own')::boolean;
    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id;
    SELECT p."full_name", p."primary_email", e."employee_number" INTO v_p
      FROM "hr"."employees" e JOIN "core"."people" p ON p."id" = e."person_id" WHERE e."id" = v_case."hr_employee_id";
    v_res := v_mgr OR (v_own AND v_case."case_type" = 'RESIGNATION');
    IF v_mgr OR v_all THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('event_type', ev."event_type", 'delivery_status', d."delivery_status", 'created_at', ev."created_at")
                                  ORDER BY ev."created_at", ev."event_type"), '[]'::jsonb) INTO v_events
          FROM "offboarding"."outbox_events" ev LEFT JOIN "offboarding"."outbox_delivery" d ON d."event_id" = ev."id" WHERE ev."case_id" = v_case."id";
    END IF;
    RETURN jsonb_build_object(
        'case_id', v_case."id", 'case_type', v_case."case_type", 'status', v_case."status", 'last_working_date', v_case."last_working_date",
        'hr_employee_id', v_case."hr_employee_id", 'employee_name', v_p."full_name", 'employee_number', v_p."employee_number",
        'employee_email', CASE WHEN v_mgr OR v_all OR v_own THEN v_p."primary_email" END,
        'department', NULL::text, 'position', NULL::text,
        'on_behalf', v_case."on_behalf", 'workflow_request_id', v_case."workflow_request_id",
        'submitted_at', v_case."submitted_at", 'approved_at', v_case."approved_at", 'clearance_started_at', v_case."clearance_started_at",
        'completed_at', v_case."completed_at", 'withdrawn_at', v_case."withdrawn_at", 'cancelled_at', v_case."cancelled_at",
        'created_at', v_case."created_at", 'version', v_case."version",
        'reason_category', CASE WHEN v_res THEN v_case."reason_category" END,
        'reason_detail', CASE WHEN v_res THEN v_case."reason_detail" END,
        'withdrawal_reason', CASE WHEN v_res THEN v_case."withdrawal_reason" END,
        'cancellation_reason', CASE WHEN v_mgr THEN v_case."cancellation_reason" END,
        'integration_events', v_events,
        'viewer', jsonb_build_object('is_manager', v_mgr, 'is_view_all', v_all, 'is_own', v_own, 'is_assigned_approver', (v_ctx->>'is_approver')::boolean,
                                     'is_clearance_holder', (v_ctx->>'is_holder')::boolean, 'clearance_domains', v_ctx->'domains', 'can_see_reasons', v_res));
END;
$$;

CREATE FUNCTION "offboarding"."get_case_tasks"(p_case_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_actor uuid := auth.uid(); v_ctx jsonb; v_res jsonb;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: get_case_tasks requires an authenticated session'; END IF;
    v_ctx := "offboarding"."_case_access"(v_actor, p_case_id);
    IF v_ctx IS NULL OR NOT (v_ctx->>'visible')::boolean THEN RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_FOUND: no such case'; END IF;
    IF (v_ctx->>'is_manager')::boolean THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('domain', t."domain", 'status', t."status", 'cleared_at', t."cleared_at", 'cleared_by', t."cleared_by",
               'clearance_note', t."clearance_note", 'waived_at', t."waived_at", 'waived_by', t."waived_by", 'waiver_reason', t."waiver_reason", 'version', t."version")
               ORDER BY t."domain"::text), '[]'::jsonb) INTO v_res FROM "offboarding"."clearance_tasks" t WHERE t."case_id" = p_case_id;
    ELSIF (v_ctx->>'is_view_all')::boolean THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('domain', t."domain", 'status', t."status", 'cleared_at', t."cleared_at", 'waived_at', t."waived_at")
               ORDER BY t."domain"::text), '[]'::jsonb) INTO v_res FROM "offboarding"."clearance_tasks" t WHERE t."case_id" = p_case_id;
    ELSIF (v_ctx->>'is_own')::boolean THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('domain', t."domain", 'status', t."status") ORDER BY t."domain"::text), '[]'::jsonb)
          INTO v_res FROM "offboarding"."clearance_tasks" t WHERE t."case_id" = p_case_id;
    ELSIF (v_ctx->>'is_holder')::boolean THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('domain', t."domain", 'status', t."status", 'cleared_at', t."cleared_at", 'clearance_note', t."clearance_note",
               'waived_at', t."waived_at", 'waiver_reason', t."waiver_reason", 'version', t."version") ORDER BY t."domain"::text), '[]'::jsonb)
          INTO v_res FROM "offboarding"."clearance_tasks" t WHERE t."case_id" = p_case_id AND t."domain"::text IN (SELECT jsonb_array_elements_text(v_ctx->'domains'));
    ELSE
        v_res := '[]'::jsonb;     -- an approver alone needs no clearance information
    END IF;
    RETURN v_res;
END;
$$;

CREATE FUNCTION "offboarding"."get_case_history"(p_case_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_actor uuid := auth.uid(); v_ctx jsonb; v_mgr boolean; v_own_res boolean; v_res jsonb;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: get_case_history requires an authenticated session'; END IF;
    v_ctx := "offboarding"."_case_access"(v_actor, p_case_id);
    IF v_ctx IS NULL OR NOT (v_ctx->>'visible')::boolean THEN RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_FOUND: no such case'; END IF;
    v_mgr := (v_ctx->>'is_manager')::boolean;
    v_own_res := (v_ctx->>'is_own')::boolean AND v_ctx->>'case_type' = 'RESIGNATION';
    -- timeline for MANAGE, VIEW_ALL and the employee on their own case; approvers and clearance holders do not need it
    IF NOT (v_mgr OR (v_ctx->>'is_view_all')::boolean OR (v_ctx->>'is_own')::boolean) THEN RETURN '[]'::jsonb; END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'id', h."id", 'event_type', h."event_type", 'from_status', h."from_status", 'to_status', h."to_status", 'actor_id', h."actor",
               'actor_name', (SELECT p."full_name" FROM "core"."person_user_links" l JOIN "core"."people" p ON p."id" = l."person_id"
                               WHERE l."user_id" = h."actor" AND l."status" = 'ACTIVE' ORDER BY l."created_at" LIMIT 1),
               'created_at', h."created_at",
               'detail', CASE WHEN v_mgr THEN h."detail" ELSE
                   (SELECT coalesce(jsonb_object_agg(kv."key", kv."value"), '{}'::jsonb) FROM jsonb_each(h."detail") kv
                     WHERE kv."key" IN ('domain', 'case_type', 'last_working_date', 'on_behalf', 'workflow_cancelled')
                        OR (v_own_res AND kv."key" IN ('reason_category', 'reason'))) END
           ) ORDER BY h."created_at", h."id"), '[]'::jsonb) INTO v_res
      FROM "offboarding"."case_history" h WHERE h."case_id" = p_case_id;
    RETURN v_res;
END;
$$;

CREATE FUNCTION "offboarding"."get_case_identities"(p_case_ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE v_actor uuid := auth.uid(); v_id uuid; v_ctx jsonb; v_p record; v_out jsonb := '[]'::jsonb; v_hr uuid;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: get_case_identities requires an authenticated session'; END IF;
    IF p_case_ids IS NULL THEN RETURN v_out; END IF;
    IF cardinality(p_case_ids) > 200 THEN RAISE EXCEPTION 'OFFBOARDING_TOO_MANY_IDS: at most 200 case ids per call'; END IF;
    FOREACH v_id IN ARRAY p_case_ids LOOP
        v_ctx := "offboarding"."_case_access"(v_actor, v_id);
        CONTINUE WHEN v_ctx IS NULL OR NOT (v_ctx->>'visible')::boolean;
        v_hr := (v_ctx->>'hr_employee_id')::uuid;
        SELECT p."full_name", p."primary_email", e."employee_number" INTO v_p
          FROM "hr"."employees" e JOIN "core"."people" p ON p."id" = e."person_id" WHERE e."id" = v_hr;
        v_out := v_out || jsonb_build_array(jsonb_build_object('case_id', v_id, 'employee_name', v_p."full_name", 'employee_number', v_p."employee_number",
            'employee_email', CASE WHEN (v_ctx->>'is_manager')::boolean OR (v_ctx->>'is_view_all')::boolean OR (v_ctx->>'is_own')::boolean THEN v_p."primary_email" END));
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE FUNCTION "offboarding"."list_cases"(
    p_status text DEFAULT NULL, p_case_type text DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_search text DEFAULT NULL,
    p_awaiting_my_approval boolean DEFAULT false, p_limit integer DEFAULT 25, p_offset integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr"
AS $$
DECLARE
    v_actor uuid := auth.uid(); v_mgr boolean; v_all boolean; v_dom text[]; v_limit int; v_offset int; v_pat text;
    v_status "offboarding"."case_status"; v_type "offboarding"."case_type"; v_result jsonb;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: list_cases requires an authenticated session'; END IF;
    IF nullif(btrim(coalesce(p_status, '')), '') IS NOT NULL THEN
        BEGIN v_status := upper(btrim(p_status))::"offboarding"."case_status";
        EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'OFFBOARDING_INVALID_FILTER: unknown status %', p_status; END;
    END IF;
    IF nullif(btrim(coalesce(p_case_type, '')), '') IS NOT NULL THEN
        BEGIN v_type := upper(btrim(p_case_type))::"offboarding"."case_type";
        EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'OFFBOARDING_INVALID_FILTER: unknown case type %', p_case_type; END;
    END IF;
    IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN RAISE EXCEPTION 'OFFBOARDING_INVALID_FILTER: the date range start is after its end'; END IF;
    v_limit := least(greatest(coalesce(p_limit, 25), 1), 100);
    v_offset := greatest(coalesce(p_offset, 0), 0);
    v_pat := CASE WHEN nullif(btrim(coalesce(p_search, '')), '') IS NULL THEN NULL
                  ELSE '%' || replace(replace(replace(left(btrim(p_search), 100), '\', '\\'), '%', '\%'), '_', '\_') || '%' END;
    v_mgr := core.has_permission(v_actor, 'OFFBOARDING_MANAGE');
    v_all := core.has_permission(v_actor, 'OFFBOARDING_VIEW_ALL');
    SELECT coalesce(array_agg(d ORDER BY d), ARRAY[]::text[]) INTO v_dom
      FROM unnest(ARRAY['ASSETS', 'ACCESS', 'FINANCE', 'HANDOVER', 'HR']) AS d WHERE core.has_permission(v_actor, 'OFFBOARDING_CLEARANCE_' || d);

    WITH base AS (
        SELECT c."id" AS case_id, c."case_type", c."status", c."last_working_date", c."hr_employee_id", c."workflow_request_id", c."submitted_at",
               c."completed_at", c."withdrawn_at", c."cancelled_at", c."created_at", c."version",
               c."reason_category", p."full_name", p."primary_email", e."employee_number",
               EXISTS (SELECT 1 FROM "core"."person_user_links" l WHERE l."person_id" = e."person_id" AND l."user_id" = v_actor AND l."status" = 'ACTIVE') AS is_own,
               (c."workflow_request_id" IS NOT NULL AND EXISTS (SELECT 1 FROM "workflow"."approval_step_assignees" a JOIN "workflow"."approval_steps" s ON s."id" = a."approval_step_id"
                    WHERE s."approval_request_id" = c."workflow_request_id" AND a."assignee_user_id" = v_actor)) AS is_appr,
               (c."status" = 'SUBMITTED' AND c."workflow_request_id" IS NOT NULL AND EXISTS (SELECT 1 FROM "workflow"."approval_step_assignees" a JOIN "workflow"."approval_steps" s ON s."id" = a."approval_step_id"
                    WHERE s."approval_request_id" = c."workflow_request_id" AND a."assignee_user_id" = v_actor AND a."status" = 'PENDING' AND s."status" IN ('PENDING', 'IN_PROGRESS'))) AS awaiting,
               (c."status" IN ('APPROVED', 'IN_CLEARANCE') AND cardinality(v_dom) > 0) AS is_holder
          FROM "offboarding"."cases" c
          JOIN "hr"."employees" e ON e."id" = c."hr_employee_id"
          JOIN "core"."people" p ON p."id" = e."person_id"
    ), vis AS (
        SELECT * FROM base
         WHERE (v_mgr OR v_all OR is_own OR is_appr OR is_holder)
           AND (v_status IS NULL OR status = v_status) AND (v_type IS NULL OR case_type = v_type)
           AND (p_from IS NULL OR last_working_date >= p_from) AND (p_to IS NULL OR last_working_date <= p_to)
           AND (NOT coalesce(p_awaiting_my_approval, false) OR awaiting)
           AND (v_pat IS NULL OR full_name ILIKE v_pat OR employee_number ILIKE v_pat OR ((v_mgr OR v_all OR is_own) AND primary_email ILIKE v_pat))
    ), page AS (
        SELECT *, count(*) OVER () AS total FROM vis ORDER BY created_at DESC, case_id DESC LIMIT v_limit OFFSET v_offset
    )
    SELECT jsonb_build_object(
               'total', coalesce((SELECT max(total) FROM page), (SELECT count(*) FROM vis)), 'limit', v_limit, 'offset', v_offset,
               'items', coalesce(jsonb_agg(jsonb_build_object(
                   'case_id', case_id, 'case_type', case_type, 'status', status, 'last_working_date', last_working_date, 'hr_employee_id', hr_employee_id,
                   'employee_name', full_name, 'employee_number', employee_number,
                   'employee_email', CASE WHEN v_mgr OR v_all OR is_own THEN primary_email END,
                   'department', NULL::text, 'position', NULL::text,
                   'workflow_request_id', workflow_request_id, 'submitted_at', submitted_at, 'completed_at', completed_at,
                   'withdrawn_at', withdrawn_at, 'cancelled_at', cancelled_at, 'created_at', created_at, 'version', version,
                   'reason_category', CASE WHEN v_mgr OR (is_own AND case_type = 'RESIGNATION') THEN reason_category END,
                   'is_own', is_own, 'awaiting_my_approval', awaiting) ORDER BY created_at DESC, case_id DESC), '[]'::jsonb))
      INTO v_result FROM page;
    RETURN v_result;
END;
$$;

CREATE FUNCTION "offboarding"."get_completion_readiness"(p_case_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, "offboarding", "workflow", "core", "hr", "assets"
AS $$
DECLARE
    v_actor uuid := auth.uid(); v_case record; v_today date; v_reached boolean; v_ready boolean; v_out int; v_blockers jsonb; v_own boolean;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'OFFBOARDING_UNAUTHENTICATED: get_completion_readiness requires an authenticated session'; END IF;
    IF NOT core.has_permission(v_actor, 'OFFBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'OFFBOARDING_NOT_AUTHORIZED: OFFBOARDING_MANAGE required to see completion readiness'; END IF;
    SELECT * INTO v_case FROM "offboarding"."cases" WHERE "id" = p_case_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'OFFBOARDING_CASE_NOT_FOUND: no such case'; END IF;
    v_today := "offboarding"."_business_date"();
    v_reached := v_today >= v_case."last_working_date";
    SELECT coalesce(count(*) = 5 AND bool_and(t."status" = 'CLEARED' OR (t."status" = 'WAIVED' AND t."domain" <> 'ASSETS')), false) INTO v_ready
      FROM "offboarding"."clearance_tasks" t WHERE t."case_id" = v_case."id";
    SELECT count(*) INTO v_out FROM "assets"."asset_assignments" WHERE "hr_employee_id" = v_case."hr_employee_id" AND "returned_at" IS NULL;
    v_blockers := "offboarding"."_completion_blockers"(v_case."hr_employee_id");
    v_own := EXISTS (SELECT 1 FROM "core"."person_user_links" l JOIN "hr"."employees" e ON e."person_id" = l."person_id"
                      WHERE l."user_id" = v_actor AND l."status" = 'ACTIVE' AND e."id" = v_case."hr_employee_id");
    RETURN jsonb_build_object('case_id', v_case."id", 'status', v_case."status", 'last_working_date', v_case."last_working_date",
        'business_date', v_today, 'date_reached', v_reached,
        'clearance', (SELECT coalesce(jsonb_object_agg(t."domain"::text, t."status"), '{}'::jsonb) FROM "offboarding"."clearance_tasks" t WHERE t."case_id" = v_case."id"),
        'clearance_ready', v_ready, 'assets_outstanding', v_out, 'blockers', v_blockers, 'is_own_case', v_own,
        'can_complete', (v_case."status" = 'IN_CLEARANCE' AND v_reached AND v_ready AND v_out = 0 AND jsonb_array_length(v_blockers) = 0 AND NOT v_own));
END;
$$;

REVOKE ALL ON FUNCTION "offboarding"."_case_access"(uuid, uuid) FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."get_case"(uuid) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "offboarding"."get_case_tasks"(uuid) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "offboarding"."get_case_history"(uuid) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "offboarding"."get_case_identities"(uuid[]) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "offboarding"."list_cases"(text, text, date, date, text, boolean, integer, integer) FROM PUBLIC, "anon";
REVOKE ALL ON FUNCTION "offboarding"."get_completion_readiness"(uuid) FROM PUBLIC, "anon";
GRANT EXECUTE ON FUNCTION "offboarding"."get_case"(uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "offboarding"."get_case_tasks"(uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "offboarding"."get_case_history"(uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "offboarding"."get_case_identities"(uuid[]) TO "authenticated";
GRANT EXECUTE ON FUNCTION "offboarding"."list_cases"(text, text, date, date, text, boolean, integer, integer) TO "authenticated";
GRANT EXECUTE ON FUNCTION "offboarding"."get_completion_readiness"(uuid) TO "authenticated";

DO $$
DECLARE v_sig text; v_oid oid;
BEGIN
    FOREACH v_sig IN ARRAY ARRAY['offboarding.get_case(uuid)', 'offboarding.get_case_tasks(uuid)', 'offboarding.get_case_history(uuid)', 'offboarding.get_case_identities(uuid[])',
                                 'offboarding.list_cases(text,text,date,date,text,boolean,integer,integer)', 'offboarding.get_completion_readiness(uuid)'] LOOP
        v_oid := to_regprocedure(v_sig)::oid;
        IF v_oid IS NULL THEN RAISE EXCEPTION '009 POST-CHECK: % missing', v_sig; END IF;
        IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) OR NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND p.proconfig::text LIKE '%search_path%') THEN
            RAISE EXCEPTION '009 POST-CHECK: % must be SECURITY DEFINER with a pinned search_path', v_sig; END IF;
        IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
           OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
            RAISE EXCEPTION '009 POST-CHECK: % must be executable by authenticated only', v_sig; END IF;
    END LOOP;
    v_oid := to_regprocedure('offboarding._case_access(uuid,uuid)')::oid;
    IF v_oid IS NULL OR has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_oid AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))) THEN
        RAISE EXCEPTION '009 POST-CHECK: _case_access must exist and be closed to app roles'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 009_offboarding_read_projections.sql
-- ========================================================================
