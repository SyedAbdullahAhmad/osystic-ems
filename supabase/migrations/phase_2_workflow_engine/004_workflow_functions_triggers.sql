-- ========================================================================
-- 004_workflow_functions_triggers.sql  (CONSOLIDATED BASELINE)
--
-- DEPENDENCY: 001, 002, 003 already applied. Also depends on Finance's
-- existing audit.log_manual() and core.has_permission().
--
-- This is the squashed, final function/trigger set - supersedes and
-- replaces the original 004 plus 004b, 004c, and 004d entirely. Every
-- behavior fix from those three patch rounds is folded in here as the
-- single, final definition of each object - nothing in this migration
-- set has been applied to the shared database yet, so there is no
-- "prior state" to preserve compatibility with.
-- ========================================================================


-- ------------------------------------------------------------------------
-- Generic immutability guard - approval_actions and status_history are
-- append-only. Unconditionally blocks UPDATE and DELETE.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "workflow"."prevent_mutation"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'WORKFLOW_IMMUTABLE_RECORD: % on %.% is not permitted - this table is append-only',
        TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
END;
$$;

DROP TRIGGER IF EXISTS "trg_approval_actions_immutable" ON "workflow"."approval_actions";
CREATE TRIGGER "trg_approval_actions_immutable"
    BEFORE UPDATE OR DELETE ON "workflow"."approval_actions"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."prevent_mutation"();

DROP TRIGGER IF EXISTS "trg_status_history_immutable" ON "workflow"."status_history";
CREATE TRIGGER "trg_status_history_immutable"
    BEFORE UPDATE OR DELETE ON "workflow"."status_history"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."prevent_mutation"();


-- ------------------------------------------------------------------------
-- A runtime approval_step must belong to the same workflow_version_id
-- as its parent approval_request (the composite FK in 003 only checks
-- the step points at SOME valid pair in workflow_steps, not that it
-- matches THIS request's version).
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "workflow"."check_approval_step_version"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_request_version_id uuid;
BEGIN
    SELECT "workflow_version_id" INTO v_request_version_id
    FROM "workflow"."approval_requests" WHERE "id" = NEW."approval_request_id";

    IF v_request_version_id IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_PARENT_REQUEST_NOT_FOUND: %', NEW."approval_request_id";
    END IF;
    IF NEW."workflow_version_id" <> v_request_version_id THEN
        RAISE EXCEPTION 'WORKFLOW_STEP_VERSION_MISMATCH: step version % does not match parent request version %',
            NEW."workflow_version_id", v_request_version_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_approval_steps_version_check" ON "workflow"."approval_steps";
CREATE TRIGGER "trg_approval_steps_version_check"
    BEFORE INSERT OR UPDATE OF "workflow_version_id", "approval_request_id" ON "workflow"."approval_steps"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."check_approval_step_version"();


-- ------------------------------------------------------------------------
-- A supplied approval_actions.approval_step_id must belong to the
-- same approval_request_id on the same row. Only needs BEFORE INSERT -
-- UPDATE is already blocked entirely by the immutability trigger above.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "workflow"."check_approval_action_step_request"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_step_request_id uuid;
BEGIN
    IF NEW."approval_step_id" IS NOT NULL THEN
        SELECT "approval_request_id" INTO v_step_request_id
        FROM "workflow"."approval_steps" WHERE "id" = NEW."approval_step_id";

        IF v_step_request_id IS NULL THEN
            RAISE EXCEPTION 'WORKFLOW_STEP_NOT_FOUND: %', NEW."approval_step_id";
        END IF;
        IF v_step_request_id <> NEW."approval_request_id" THEN
            RAISE EXCEPTION 'WORKFLOW_STEP_REQUEST_MISMATCH: step % belongs to request %, not %',
                NEW."approval_step_id", v_step_request_id, NEW."approval_request_id";
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_approval_actions_step_request_check" ON "workflow"."approval_actions";
CREATE TRIGGER "trg_approval_actions_step_request_check"
    BEFORE INSERT ON "workflow"."approval_actions"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."check_approval_action_step_request"();


-- ------------------------------------------------------------------------
-- RLS visibility helper. Final hardened form: REVOKE ALL FROM PUBLIC,
-- pinned search_path with 'public' removed.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "workflow"."can_view_request"("p_request_id" uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, workflow, core, auth
AS $$
    SELECT EXISTS (
        SELECT 1 FROM "workflow"."approval_requests" r
        WHERE r."id" = p_request_id
          AND (
            r."initiated_by_user_id" = auth.uid()
            OR core.has_permission(auth.uid(), 'WORKFLOW_VIEW_ALL')
            OR EXISTS (
                SELECT 1 FROM "workflow"."approval_steps" s
                JOIN "workflow"."approval_step_assignees" a ON a."approval_step_id" = s."id"
                WHERE s."approval_request_id" = r."id" AND a."assignee_user_id" = auth.uid()
            )
          )
    );
$$;

REVOKE ALL ON FUNCTION "workflow"."can_view_request"(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "workflow"."can_view_request"(uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "workflow"."can_view_request"(uuid) TO "service_role";


-- ------------------------------------------------------------------------
-- ACTIVE-version revert/tamper protection.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "workflow"."prevent_active_version_tamper"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Once a version has ever been published (ACTIVE), it must remain
    -- immutable permanently: DRAFT -> ACTIVE -> RETIRED, RETIRED is
    -- terminal. Historical approval_requests stay pinned to whichever
    -- version they ran against, so nothing about that version's
    -- identity/configuration/audit fields may change after
    -- publication.
    --
    -- Item 3 (round 4): effective_to is NOT a generally-mutable field
    -- while ACTIVE or RETIRED - it may ONLY be set by the SPECIFIC
    -- ACTIVE->RETIRED transition statement itself (the retirement
    -- operation). Any other write while remaining ACTIVE, and EVERY
    -- write once already RETIRED (including a second attempt to
    -- change effective_to after retirement), is rejected. Round 3
    -- incorrectly allowed effective_to to keep changing in both
    -- states - this closes that gap.
    IF OLD."status" = 'ACTIVE' THEN
        IF NEW."status" NOT IN ('ACTIVE', 'RETIRED') THEN
            RAISE EXCEPTION 'WORKFLOW_VERSION_REVERT_DENIED: an ACTIVE version may only move to RETIRED, not %', NEW."status";
        END IF;

        IF NEW."workflow_definition_id" <> OLD."workflow_definition_id"
           OR NEW."version_no" <> OLD."version_no"
           OR NEW."effective_from" IS DISTINCT FROM OLD."effective_from"
           OR NEW."created_at" <> OLD."created_at"
           OR NEW."created_by" <> OLD."created_by" THEN
            RAISE EXCEPTION 'WORKFLOW_VERSION_IMMUTABLE_FIELDS: only effective_to (via the controlled ACTIVE->RETIRED retirement operation) may change once ACTIVE';
        END IF;

        -- effective_to may change ONLY as part of THIS statement
        -- actually performing the ACTIVE->RETIRED transition. Staying
        -- ACTIVE while also trying to change effective_to is rejected.
        IF NEW."effective_to" IS DISTINCT FROM OLD."effective_to" AND NEW."status" <> 'RETIRED' THEN
            RAISE EXCEPTION 'WORKFLOW_VERSION_IMMUTABLE_FIELDS: effective_to can only be set by the ACTIVE->RETIRED retirement operation itself';
        END IF;

    ELSIF OLD."status" = 'RETIRED' THEN
        IF NEW."status" <> 'RETIRED' THEN
            RAISE EXCEPTION 'WORKFLOW_VERSION_RETIRED_IS_TERMINAL: a RETIRED version can never move to %', NEW."status";
        END IF;

        -- Fully frozen: not even effective_to may change again once
        -- genuinely RETIRED - that write already happened, exactly
        -- once, as part of the ACTIVE->RETIRED transition above.
        IF NEW."workflow_definition_id" <> OLD."workflow_definition_id"
           OR NEW."version_no" <> OLD."version_no"
           OR NEW."effective_from" IS DISTINCT FROM OLD."effective_from"
           OR NEW."effective_to" IS DISTINCT FROM OLD."effective_to"
           OR NEW."created_at" <> OLD."created_at"
           OR NEW."created_by" <> OLD."created_by" THEN
            RAISE EXCEPTION 'WORKFLOW_VERSION_IMMUTABLE_FIELDS: a RETIRED version is completely immutable, including effective_to';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_workflow_versions_prevent_tamper" ON "workflow"."workflow_versions";
CREATE TRIGGER "trg_workflow_versions_prevent_tamper"
    BEFORE UPDATE ON "workflow"."workflow_versions"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."prevent_active_version_tamper"();

-- ========================================================================
-- END OF PART 1 - see 004_workflow_functions_triggers.sql part 2 for
-- the lifecycle engine and action-processing RPCs (same file,
-- continues below - split into two create_file calls only due to
-- length, not a separate migration file).
-- ========================================================================


-- ========================================================================
-- workflow._materialize_stage(...)
-- Item 3: after resolving/deduplicating runtime assignees, MIN_N steps
-- must have enough resolved assignees to ever reach required_approvals
-- - fail materialization loudly rather than create a step that can
-- never complete. Item 10: sets sla_due_at from workflow_steps.sla_minutes
-- at materialization time.
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."_materialize_stage"(
    "p_approval_request_id" uuid,
    "p_workflow_version_id" uuid,
    "p_step_no" int
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, core
AS $$
DECLARE
    v_tmpl "workflow"."workflow_steps"%ROWTYPE;
    v_new_step_id uuid;
    v_assignee "workflow"."workflow_step_assignees"%ROWTYPE;
    v_user_id uuid;
    v_resolved_count int;
BEGIN
    FOR v_tmpl IN
        SELECT * FROM "workflow"."workflow_steps"
        WHERE "workflow_version_id" = p_workflow_version_id AND "step_no" = p_step_no
    LOOP
        INSERT INTO "workflow"."approval_steps" (
            "approval_request_id", "workflow_step_id", "workflow_version_id",
            "step_no", "sequence_no", "parallel_group", "approval_mode",
            "required_approvals", "status", "sla_due_at"
        ) VALUES (
            p_approval_request_id, v_tmpl."id", p_workflow_version_id,
            v_tmpl."step_no", v_tmpl."sequence_no", v_tmpl."parallel_group", v_tmpl."approval_mode",
            v_tmpl."required_approvals", 'PENDING',
            now() + (v_tmpl."sla_minutes" || ' minutes')::interval
        ) RETURNING "id" INTO v_new_step_id;

        FOR v_assignee IN
            SELECT * FROM "workflow"."workflow_step_assignees" WHERE "workflow_step_id" = v_tmpl."id"
        LOOP
            IF v_assignee."assignee_type" = 'USER' THEN
                INSERT INTO "workflow"."approval_step_assignees" (
                    "approval_step_id", "assignee_user_id", "workflow_step_assignee_id"
                ) VALUES (v_new_step_id, v_assignee."user_id", v_assignee."id")
                ON CONFLICT ("approval_step_id", "assignee_user_id") DO NOTHING;

            ELSIF v_assignee."assignee_type" = 'ROLE' THEN
                FOR v_user_id IN
                    SELECT DISTINCT ur."user_id" FROM "core"."user_roles" ur
                    WHERE ur."role_id" = v_assignee."role_id"
                      AND ur."is_active" = true
                      AND ur."effective_from" <= CURRENT_DATE
                      AND (ur."effective_to" IS NULL OR ur."effective_to" >= CURRENT_DATE)
                LOOP
                    INSERT INTO "workflow"."approval_step_assignees" (
                        "approval_step_id", "assignee_user_id", "workflow_step_assignee_id", "resolved_from_role_id"
                    ) VALUES (v_new_step_id, v_user_id, v_assignee."id", v_assignee."role_id")
                    ON CONFLICT ("approval_step_id", "assignee_user_id") DO NOTHING;
                END LOOP;

            ELSIF v_assignee."assignee_type" = 'PERMISSION' THEN
                FOR v_user_id IN
                    SELECT DISTINCT ur."user_id" FROM "core"."user_roles" ur
                    JOIN "core"."role_permissions" rp ON rp."role_id" = ur."role_id"
                    JOIN "core"."permissions" p ON p."id" = rp."permission_id"
                    WHERE p."code" = v_assignee."permission_code"
                      AND ur."is_active" = true
                      AND ur."effective_from" <= CURRENT_DATE
                      AND (ur."effective_to" IS NULL OR ur."effective_to" >= CURRENT_DATE)
                      AND CURRENT_DATE >= rp."effective_from"
                      AND (rp."effective_to" IS NULL OR rp."effective_to" >= CURRENT_DATE)
                LOOP
                    INSERT INTO "workflow"."approval_step_assignees" (
                        "approval_step_id", "assignee_user_id", "workflow_step_assignee_id", "resolved_from_permission_code"
                    ) VALUES (v_new_step_id, v_user_id, v_assignee."id", v_assignee."permission_code")
                    ON CONFLICT ("approval_step_id", "assignee_user_id") DO NOTHING;
                END LOOP;
            END IF;
        END LOOP;

        SELECT count(*) INTO v_resolved_count
        FROM "workflow"."approval_step_assignees" WHERE "approval_step_id" = v_new_step_id;

        IF v_resolved_count = 0 THEN
            RAISE EXCEPTION 'WORKFLOW_STEP_HAS_NO_RESOLVABLE_ASSIGNEES: step % (template %) resolved to zero eligible users',
                v_new_step_id, v_tmpl."id";
        END IF;

        -- Item 3: MIN_N runtime validation - the activation-time check
        -- only covers USER-type-only steps; this closes the gap for
        -- ROLE/PERMISSION steps, checked against the ACTUAL resolved
        -- (deduplicated) count at the moment it matters.
        IF v_tmpl."approval_mode" = 'MIN_N' AND v_resolved_count < COALESCE(v_tmpl."required_approvals", 1) THEN
            RAISE EXCEPTION 'WORKFLOW_STEP_MIN_N_UNSATISFIABLE: step % (template %) requires % approvals but only % assignee(s) resolved',
                v_new_step_id, v_tmpl."id", v_tmpl."required_approvals", v_resolved_count;
        END IF;
    END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."_materialize_stage"(uuid, uuid, int) FROM PUBLIC, "authenticated", "service_role";


-- ========================================================================
-- workflow._evaluate_step_outcome(...) - unified quorum + configurable
-- rejection-mode evaluation. Unchanged in design from the prior round.
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."_evaluate_step_outcome"("p_approval_step_id" uuid)
RETURNS "workflow"."step_status"
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow
AS $$
DECLARE
    v_step "workflow"."approval_steps"%ROWTYPE;
    v_rejection_mode varchar(20);
    v_approved int;
    v_rejected int;
    v_skipped int;
    v_pending int;
    v_total int;
    v_countable int;
BEGIN
    SELECT * INTO v_step FROM "workflow"."approval_steps" WHERE "id" = p_approval_step_id;

    SELECT ws."rejection_mode" INTO v_rejection_mode
    FROM "workflow"."workflow_steps" ws WHERE ws."id" = v_step."workflow_step_id";

    SELECT
        count(*) FILTER (WHERE "status" = 'APPROVED'),
        count(*) FILTER (WHERE "status" = 'REJECTED'),
        count(*) FILTER (WHERE "status" = 'SKIPPED'),
        count(*) FILTER (WHERE "status" = 'PENDING'),
        count(*)
    INTO v_approved, v_rejected, v_skipped, v_pending, v_total
    FROM "workflow"."approval_step_assignees" WHERE "approval_step_id" = p_approval_step_id;

    v_countable := v_total - v_skipped;

    IF v_rejected > 0 THEN
        IF v_rejection_mode = 'ANY_REJECT' THEN
            RETURN 'REJECTED';
        ELSIF v_step."approval_mode" = 'ALL_OF' THEN
            RETURN 'REJECTED';
        ELSIF v_step."approval_mode" = 'MIN_N' THEN
            IF (v_approved + v_pending) < COALESCE(v_step."required_approvals", 1) THEN
                RETURN 'REJECTED';
            END IF;
        ELSIF v_step."approval_mode" = 'ONE_OF' THEN
            IF v_rejected = v_countable THEN
                RETURN 'REJECTED';
            END IF;
        END IF;
    END IF;

    IF (v_step."approval_mode" = 'ONE_OF' AND v_approved >= 1)
       OR (v_step."approval_mode" = 'ALL_OF' AND v_countable > 0 AND v_approved = v_countable)
       OR (v_step."approval_mode" = 'MIN_N' AND v_approved >= COALESCE(v_step."required_approvals", 1)) THEN
        RETURN 'APPROVED';
    END IF;

    IF v_approved > 0 OR v_rejected > 0 OR v_skipped > 0 THEN
        RETURN 'IN_PROGRESS';
    END IF;

    RETURN 'PENDING';
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."_evaluate_step_outcome"(uuid) FROM PUBLIC, "authenticated", "service_role";


-- ========================================================================
-- workflow._check_skip_quorum_safe(...)  (NEW - item 4)
-- Simulates the assignee moving from PENDING to SKIPPED and returns
-- whether the step's quorum requirement would REMAIN satisfiable
-- afterward. Called BEFORE a SKIP is recorded - a skip that would make
-- the step unresolvable is rejected outright rather than silently
-- creating a deadlocked step.
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."_check_skip_quorum_safe"(
    "p_approval_step_id" uuid,
    "p_assignee_user_id" uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow
AS $$
DECLARE
    v_step "workflow"."approval_steps"%ROWTYPE;
    v_approved int;
    v_pending int;
    v_countable int;
BEGIN
    SELECT * INTO v_step FROM "workflow"."approval_steps" WHERE "id" = p_approval_step_id;

    SELECT
        count(*) FILTER (WHERE "status" = 'APPROVED'),
        count(*) FILTER (WHERE "status" = 'PENDING'),
        count(*) FILTER (WHERE "status" <> 'SKIPPED')
    INTO v_approved, v_pending, v_countable
    FROM "workflow"."approval_step_assignees" WHERE "approval_step_id" = p_approval_step_id;

    -- Simulate: this specific PENDING assignee becomes SKIPPED.
    v_pending := v_pending - 1;
    v_countable := v_countable - 1;

    RETURN CASE v_step."approval_mode"
        WHEN 'ONE_OF' THEN (v_approved >= 1) OR (v_countable > 0)
        WHEN 'MIN_N'  THEN (v_approved + v_pending) >= COALESCE(v_step."required_approvals", 1)
        WHEN 'ALL_OF' THEN v_countable > 0
        ELSE true
    END;
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."_check_skip_quorum_safe"(uuid, uuid) FROM PUBLIC, "authenticated", "service_role";


-- ========================================================================
-- workflow._check_transition_authority(...)
-- Item 7 (delegation authority): checks against the PRINCIPAL, not the
-- acting delegate. Returns to_status. Used for (a) request-level
-- actions, applied immediately, and (b) the per-action gate-check for
-- APPROVE/REJECT (its return value discarded there - see item 1 fix
-- below for why re-checking inside stage advancement was removed).
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."_check_transition_authority"(
    "p_workflow_version_id" uuid,
    "p_from_status" varchar(50),
    "p_trigger_action" "workflow"."approval_action_type",
    "p_principal_user_id" uuid,
    "p_actor_user_id" uuid,
    "p_initiated_by_user_id" uuid
) RETURNS varchar(50)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, core
AS $$
DECLARE
    v_to_status varchar(50);
    v_requires_role_id uuid;
    v_requires_permission_code varchar(100);
    v_maker_checker boolean;
BEGIN
    SELECT tr."to_status", tr."requires_role_id", tr."requires_permission_code", tr."is_maker_checker"
        INTO v_to_status, v_requires_role_id, v_requires_permission_code, v_maker_checker
    FROM "workflow"."transition_rules" tr
    WHERE tr."workflow_version_id" = p_workflow_version_id
      AND tr."from_status" = p_from_status
      AND tr."trigger_action" = p_trigger_action;

    IF v_to_status IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_NO_TRANSITION_FOR_ACTION: no % transition is defined from % for this workflow version',
            p_trigger_action, p_from_status;
    END IF;

    IF v_requires_permission_code IS NOT NULL
       AND NOT core.has_permission(p_principal_user_id, v_requires_permission_code) THEN
        RAISE EXCEPTION 'WORKFLOW_PERMISSION_DENIED: transition requires %', v_requires_permission_code;
    END IF;

    IF v_requires_role_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM "core"."user_roles" ur
        WHERE ur."user_id" = p_principal_user_id AND ur."role_id" = v_requires_role_id AND ur."is_active" = true
    ) THEN
        RAISE EXCEPTION 'WORKFLOW_ROLE_REQUIRED: transition requires role %', v_requires_role_id;
    END IF;

    IF v_maker_checker AND (p_actor_user_id = p_initiated_by_user_id OR p_principal_user_id = p_initiated_by_user_id) THEN
        RAISE EXCEPTION 'WORKFLOW_MAKER_CHECKER_VIOLATION: initiator (directly or via delegation) cannot perform this transition on their own request';
    END IF;

    RETURN v_to_status;
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."_check_transition_authority"(
    uuid, varchar(50), "workflow"."approval_action_type", uuid, uuid, uuid
) FROM PUBLIC, "authenticated", "service_role";


-- ========================================================================
-- workflow._advance_after_step_completion(...)
--
-- Item 1 FIX: this function NO LONGER calls _check_transition_authority.
-- Authority for the transition was already correctly validated at the
-- moment of the DECISIVE individual APPROVE/REJECT action (see the
-- gate-check in _process_action_internal below), against the correct
-- principal/actor at that time. Re-checking here against "whichever
-- actor happened to complete the stage" was the bug your review found
-- - for a multi-step parallel stage, that actor is not necessarily the
-- one whose action was actually decisive, and for delegated actions it
-- collapsed principal and actor into the same value. The fix is to not
-- re-derive authority here at all: just resolve to_status via a plain,
-- unambiguous lookup (the (version, from_status, trigger_action)
-- unique constraint in 003 guarantees exactly one row) and apply it.
-- p_triggering_action_id is recorded on the resulting status_history
-- row via triggered_by_approval_action_id, so the exact decisive,
-- already-authorized action stays traceable (item 1's second ask).
-- ------------------------------------------------------------------------
-- Item 8 FIX: version now increments on the stage-materialization
-- branch, not just on a current_status change.
-- Item 9 FIX: organization_id is copied from the request into the
-- status_history row.
-- Item 2 FIX (this round): status_history.triggered_by_approval_action_id
-- no longer defaults to "whichever action happened to complete the
-- overall stage" (p_triggering_action_id). For a REJECTED stage, it
-- now traces to the specific REJECTED sibling step's own
-- outcome_action_id - the step that finishes LAST is not necessarily
-- the one whose REJECT caused the outcome. For an APPROVED stage, the
-- completing step's own outcome_action_id is used (valid there, since
-- every sibling must independently be APPROVED). p_triggering_action_id
-- is kept only as a last-resort fallback for the rare case where no
-- step's outcome_action_id was resolvable at all.
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."_advance_after_step_completion"(
    "p_approval_request_id" uuid,
    "p_completed_step_id" uuid,
    "p_triggering_action_id" uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow
AS $$
DECLARE
    v_request "workflow"."approval_requests"%ROWTYPE;
    v_completed_step "workflow"."approval_steps"%ROWTYPE;
    v_traced_action "workflow"."approval_actions"%ROWTYPE;
    v_traced_action_id uuid;
    v_stage_step_no int;
    v_incomplete_count int;
    v_rejected_count int;
    v_next_step_no int;
    v_to_status varchar(50);
    v_becomes_terminal boolean;
BEGIN
    SELECT * INTO v_request FROM "workflow"."approval_requests" WHERE "id" = p_approval_request_id FOR UPDATE;
    SELECT * INTO v_completed_step FROM "workflow"."approval_steps" WHERE "id" = p_completed_step_id;
    v_stage_step_no := v_completed_step."step_no";

    SELECT count(*) FILTER (WHERE "status" NOT IN ('APPROVED', 'REJECTED')),
           count(*) FILTER (WHERE "status" = 'REJECTED')
        INTO v_incomplete_count, v_rejected_count
    FROM "workflow"."approval_steps"
    WHERE "approval_request_id" = p_approval_request_id AND "step_no" = v_stage_step_no;

    IF v_incomplete_count > 0 THEN
        RETURN;  -- sibling parallel step(s) still open
    END IF;

    IF v_rejected_count > 0 THEN
        SELECT "to_status" INTO v_to_status
        FROM "workflow"."transition_rules"
        WHERE "workflow_version_id" = v_request."workflow_version_id"
          AND "from_status" = v_request."current_status" AND "trigger_action" = 'REJECT';
        IF v_to_status IS NULL THEN
            RAISE EXCEPTION 'WORKFLOW_NO_TRANSITION_FOR_ACTION: no REJECT transition defined from %', v_request."current_status";
        END IF;

        -- Item 2: trace to the REJECTED sibling's own outcome_action_id,
        -- which may not be p_completed_step_id/p_triggering_action_id -
        -- the step that finished LAST is not necessarily the one whose
        -- REJECT caused the stage's overall rejected outcome.
        SELECT "outcome_action_id" INTO v_traced_action_id
        FROM "workflow"."approval_steps"
        WHERE "approval_request_id" = p_approval_request_id
          AND "step_no" = v_stage_step_no AND "status" = 'REJECTED'
        ORDER BY "completed_at" ASC NULLS LAST
        LIMIT 1;
    ELSE
        SELECT MIN("step_no") INTO v_next_step_no
        FROM "workflow"."workflow_steps"
        WHERE "workflow_version_id" = v_request."workflow_version_id" AND "step_no" > v_stage_step_no;

        IF v_next_step_no IS NOT NULL THEN
            PERFORM "workflow"."_materialize_stage"(p_approval_request_id, v_request."workflow_version_id", v_next_step_no);
            UPDATE "workflow"."approval_requests"
            SET "current_step_no" = v_next_step_no, "updated_at" = now(), "version" = "version" + 1
            WHERE "id" = p_approval_request_id;
            RETURN;  -- current_status unchanged - no status_history row
        END IF;

        SELECT "to_status" INTO v_to_status
        FROM "workflow"."transition_rules"
        WHERE "workflow_version_id" = v_request."workflow_version_id"
          AND "from_status" = v_request."current_status" AND "trigger_action" = 'APPROVE';
        IF v_to_status IS NULL THEN
            RAISE EXCEPTION 'WORKFLOW_NO_TRANSITION_FOR_ACTION: no APPROVE transition defined from %', v_request."current_status";
        END IF;

        -- Item 2: for an approved stage every sibling step must itself
        -- be APPROVED, so the completing step's own outcome_action_id
        -- is a valid trace (unlike the rejected case above, there's no
        -- "wrong sibling" risk here - whichever step finishes last is
        -- itself a genuine APPROVE, not merely a bystander).
        v_traced_action_id := v_completed_step."outcome_action_id";
    END IF;

    -- Fallback: if no specific outcome_action_id was resolvable (e.g.
    -- an ALL_OF step completed purely by SKIPs shrinking the countable
    -- denominator, with no APPROVE action to point to), trace to the
    -- action that actually triggered this call rather than leaving the
    -- field NULL.
    v_traced_action_id := COALESCE(v_traced_action_id, p_triggering_action_id);
    SELECT * INTO v_traced_action FROM "workflow"."approval_actions" WHERE "id" = v_traced_action_id;

    SELECT EXISTS (
        SELECT 1 FROM "workflow"."workflow_statuses" ws
        WHERE ws."workflow_version_id" = v_request."workflow_version_id"
          AND ws."status_code" = v_to_status AND ws."is_terminal" = true
    ) INTO v_becomes_terminal;

    UPDATE "workflow"."approval_requests"
    SET "current_status" = v_to_status,
        "is_open" = NOT v_becomes_terminal,
        "completed_at" = CASE WHEN v_becomes_terminal THEN now() ELSE "completed_at" END,
        "updated_at" = now(),
        "version" = "version" + 1
    WHERE "id" = p_approval_request_id;

    INSERT INTO "workflow"."status_history" (
        "organization_id", "approval_request_id", "approval_step_id", "workflow_version_id",
        "triggered_by_approval_action_id", "from_status", "to_status",
        "changed_by_user_id", "changed_by_actor_type", "reason"
    ) VALUES (
        v_request."organization_id", p_approval_request_id, p_completed_step_id, v_request."workflow_version_id",
        v_traced_action_id, v_request."current_status", v_to_status,
        v_traced_action."actor_user_id", COALESCE(v_traced_action."actor_type", 'SYSTEM'), 'stage advancement'
    );
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."_advance_after_step_completion"(uuid, uuid, uuid) FROM PUBLIC, "authenticated", "service_role";


-- ========================================================================
-- workflow.start_approval_request(...)
-- Item 5 FIX: p_organization_id parameter REMOVED - a caller can no
-- longer supply organization context. Internally NULL, matching the
-- single-tenant convention used throughout this schema until the
-- shared org migration lands.
-- Item 6 FIX: enforces workflow_definitions.initiation_permission_code
-- when set, PLUS (this round) workflow_definitions.is_active and the
-- selected version's effective_from/effective_to window - being
-- authenticated no longer implies being allowed to start a workflow
-- that is inactive, or a version that isn't yet/no-longer effective.
-- Item 7 FIX: durable start-idempotency via
-- workflow.request_start_idempotency, checked BEFORE the open-request
-- lookup and independent of whether that request has since closed.
-- Item 3 FIX (this round): the idempotency key is now bound to BOTH
-- the caller (created_by) AND a payload_hash covering actor/
-- definition/entity/metadata. A key match with a DIFFERENT caller or a
-- DIFFERENT payload no longer silently returns the original request -
-- it raises WORKFLOW_IDEMPOTENCY_KEY_REUSE_MISMATCH. This stops the
-- key from working as a bearer token for someone else's request, and
-- stops the same caller reusing a key against different parameters.
-- Item 4 FIX (this round): current_step_no is now set directly in the
-- INITIAL INSERT (v_first_step_no is resolved before that INSERT),
-- rather than via a separate post-insert UPDATE - so there is no
-- state-changing UPDATE on an already-existing row left un-versioned;
-- it's simply part of the row's creation.
-- Item 9 FIX: status_history row includes organization_id (NULL,
-- consistent with the request row itself).
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."start_approval_request"(
    "p_workflow_definition_id" uuid,
    "p_entity_type" varchar(100),
    "p_entity_id" uuid,
    "p_metadata" jsonb DEFAULT NULL,
    "p_idempotency_key" varchar(255) DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, core, auth, extensions
AS $$
DECLARE
    v_actor_user_id uuid := auth.uid();
    v_definition "workflow"."workflow_definitions"%ROWTYPE;
    v_version "workflow"."workflow_versions"%ROWTYPE;
    v_initial_status varchar(50);
    v_payload_hash text;
    v_existing_key "workflow"."request_start_idempotency"%ROWTYPE;
    v_existing_request "workflow"."approval_requests"%ROWTYPE;
    v_request_id uuid;
    v_first_step_no int;
BEGIN
    IF v_actor_user_id IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_UNAUTHENTICATED';
    END IF;
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_IDEMPOTENCY_KEY_REQUIRED';
    END IF;

    -- Item 3: canonical payload hash, computed BEFORE the idempotency
    -- lookup so it's available to verify against on a key match.
    v_payload_hash := encode(
        digest(
            v_actor_user_id::text || '|' || p_workflow_definition_id::text || '|' ||
            p_entity_type || '|' || p_entity_id::text || '|' || COALESCE(p_metadata::text, ''),
            'sha256'
        ), 'hex'
    );

    -- Item 7: durable start-idempotency, checked first - resolves to
    -- the SAME original request regardless of whether it is still
    -- open, unlike the (now secondary) open-request lookup below.
    -- Item 3: a key match is only honored if it belongs to THIS caller
    -- and carries the SAME payload - otherwise the key is being reused
    -- either by a different user (who must not receive someone else's
    -- request id/status as if it were their own) or against different
    -- parameters, and this is treated as a hard error, not a silent
    -- ALREADY_PROCESSED.
    SELECT * INTO v_existing_key
    FROM "workflow"."request_start_idempotency" WHERE "idempotency_key" = p_idempotency_key;

    IF FOUND THEN
        IF v_existing_key."created_by" <> v_actor_user_id
           OR v_existing_key."payload_hash" <> v_payload_hash THEN
            RAISE EXCEPTION 'WORKFLOW_IDEMPOTENCY_KEY_REUSE_MISMATCH: key % was already used by a different caller or with different parameters',
                p_idempotency_key;
        END IF;
        SELECT * INTO v_existing_request
        FROM "workflow"."approval_requests" WHERE "id" = v_existing_key."approval_request_id";
        RETURN jsonb_build_object(
            'status', 'ALREADY_PROCESSED',
            'approval_request_id', v_existing_request."id",
            'current_status', v_existing_request."current_status",
            'is_open', v_existing_request."is_open"
        );
    END IF;

    SELECT * INTO v_definition
    FROM "workflow"."workflow_definitions" WHERE "id" = p_workflow_definition_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WORKFLOW_DEFINITION_NOT_FOUND: %', p_workflow_definition_id;
    END IF;

    -- Item 6: the definition itself must be active.
    IF NOT v_definition."is_active" THEN
        RAISE EXCEPTION 'WORKFLOW_DEFINITION_INACTIVE: definition % is not active', p_workflow_definition_id;
    END IF;

    -- Item 7: definition-level initiation authorization ONLY.
    -- initiation_permission_code gates "can this user start THIS KIND
    -- of workflow at all" - it says nothing about whether the caller
    -- is entitled to start it against THIS SPECIFIC p_entity_id (e.g.
    -- an employee's own leave record vs. a co-worker's). This generic
    -- engine has no way to validate ownership of an arbitrary module
    -- entity UUID and must not attempt to become the authorization
    -- layer for that. Entity-level ownership/scope checks are the
    -- calling module's responsibility, via a module-owned initiation
    -- RPC (e.g. leave.submit_request()) that validates ownership and
    -- THEN calls this function - never by exposing
    -- start_approval_request() directly to end users for self-service
    -- entity-scoped workflows.
    IF v_definition."initiation_permission_code" IS NOT NULL
       AND NOT core.has_permission(v_actor_user_id, v_definition."initiation_permission_code") THEN
        RAISE EXCEPTION 'WORKFLOW_INITIATION_NOT_AUTHORIZED: missing %', v_definition."initiation_permission_code";
    END IF;

    -- Secondary guard (business-key idempotency for callers who did
    -- not supply a request_start_idempotency-registered key before -
    -- should not normally be reachable given the check above, kept as
    -- defense-in-depth for the open-request case specifically).
    SELECT * INTO v_existing_request
    FROM "workflow"."approval_requests"
    WHERE "organization_id" IS NULL
      AND "entity_type" = p_entity_type AND "entity_id" = p_entity_id AND "is_open" = true;

    IF FOUND THEN
        INSERT INTO "workflow"."request_start_idempotency" ("idempotency_key", "approval_request_id", "created_by", "payload_hash")
        VALUES (p_idempotency_key, v_existing_request."id", v_actor_user_id, v_payload_hash)
        ON CONFLICT ("idempotency_key") DO NOTHING;
        RETURN jsonb_build_object(
            'status', 'ALREADY_OPEN',
            'approval_request_id', v_existing_request."id",
            'current_status', v_existing_request."current_status"
        );
    END IF;

    -- Item 6: version must be ACTIVE AND within its effective window,
    -- if one is configured (effective_from reached, effective_to not
    -- yet passed).
    SELECT * INTO v_version
    FROM "workflow"."workflow_versions"
    WHERE "workflow_definition_id" = p_workflow_definition_id
      AND "status" = 'ACTIVE'
      AND ("effective_from" IS NULL OR "effective_from" <= now())
      AND ("effective_to" IS NULL OR "effective_to" > now());
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WORKFLOW_NO_ACTIVE_VERSION: definition % has no ACTIVE, currently-effective version', p_workflow_definition_id;
    END IF;

    SELECT "status_code" INTO v_initial_status
    FROM "workflow"."workflow_statuses"
    WHERE "workflow_version_id" = v_version."id" AND "is_initial" = true;
    IF v_initial_status IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_NO_INITIAL_STATUS: version % has no initial status configured', v_version."id";
    END IF;

    -- Item 4: resolve the first stage's step_no BEFORE inserting the
    -- request row, so current_step_no can be set directly in the
    -- INSERT below rather than via a separate post-insert UPDATE.
    SELECT MIN("step_no") INTO v_first_step_no
    FROM "workflow"."workflow_steps" WHERE "workflow_version_id" = v_version."id";

    INSERT INTO "workflow"."approval_requests" (
        "organization_id", "workflow_definition_id", "workflow_version_id", "module",
        "entity_type", "entity_id", "initiated_by_user_id", "current_status", "current_step_no"
    ) VALUES (
        NULL, p_workflow_definition_id, v_version."id", v_definition."module",
        p_entity_type, p_entity_id, v_actor_user_id, v_initial_status, v_first_step_no
    ) RETURNING "id" INTO v_request_id;

    INSERT INTO "workflow"."request_start_idempotency" ("idempotency_key", "approval_request_id", "created_by", "payload_hash")
    VALUES (p_idempotency_key, v_request_id, v_actor_user_id, v_payload_hash);

    INSERT INTO "workflow"."status_history" (
        "organization_id", "approval_request_id", "workflow_version_id",
        "from_status", "to_status", "changed_by_user_id", "changed_by_actor_type", "reason"
    ) VALUES (
        NULL, v_request_id, v_version."id", NULL, v_initial_status, v_actor_user_id, 'USER', 'request created'
    );

    IF v_first_step_no IS NOT NULL THEN
        PERFORM "workflow"."_materialize_stage"(v_request_id, v_version."id", v_first_step_no);
    END IF;

    -- Item 5: this SUBMIT row represents "request started/submitted" -
    -- it is inserted internally here ONLY, and is not separately
    -- invocable via process_approval_action() (see
    -- _non_invocable_actions() / _process_action_internal() above).
    INSERT INTO "workflow"."approval_actions" (
        "approval_request_id", "actor_type", "actor_user_id", "action", "idempotency_key", "metadata"
    ) VALUES (
        v_request_id, 'USER', v_actor_user_id, 'SUBMIT', p_idempotency_key, p_metadata
    );

    PERFORM pg_notify('workflow_events', jsonb_build_object(
        'event', 'approval_request_started', 'approval_request_id', v_request_id
    )::text);

    RETURN jsonb_build_object(
        'status', 'CREATED', 'approval_request_id', v_request_id,
        'current_status', v_initial_status, 'current_step_no', v_first_step_no
    );
END;
$$;

-- Item 1 (round 3): start_approval_request() is INTERNAL-ONLY.
-- EXECUTE is deliberately NOT granted to authenticated - the intended
-- call path is:
--   Employee/UI -> module RPC (e.g. leave.submit_request(), its own
--   SECURITY DEFINER function) -> entity ownership/policy validation
--   -> workflow.start_approval_request()
-- A module RPC can call this function directly regardless of its own
-- caller's grants, because PostgreSQL checks EXECUTE privilege against
-- the DEFINER of a SECURITY DEFINER function at each call site, not
-- against the original end-user - so once leave.submit_request() (or
-- any future module RPC) is created as SECURITY DEFINER owned by a
-- sufficiently privileged role, it can call this function without
-- needing its own separate grant here. Exposing this directly to
-- authenticated would let any client bypass entity-level ownership
-- checks entirely by skipping the module RPC layer.
REVOKE ALL ON FUNCTION "workflow"."start_approval_request"(uuid, varchar(100), uuid, jsonb, varchar(255)) FROM PUBLIC, "authenticated";
GRANT EXECUTE ON FUNCTION "workflow"."start_approval_request"(uuid, varchar(100), uuid, jsonb, varchar(255)) TO "service_role";


-- ========================================================================
-- workflow._non_invocable_actions()  (NEW - items 5 & 10)
-- Single source of truth for which approval_action_type values are NOT
-- callable through process_approval_action()/process_system_action():
-- either genuinely unimplemented at runtime, or (SUBMIT, per item 5's
-- resolved lifecycle model) only ever inserted internally by
-- start_approval_request() and never separately invocable. Used by
-- activate_workflow_version()'s reachability check (item 10) below, so
-- a workflow cannot pass activation via a transition edge the runtime
-- can never actually execute, and by _process_action_internal()'s own
-- dispatch guard further down, so the two lists can never silently
-- drift apart.
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."_non_invocable_actions"()
RETURNS "workflow"."approval_action_type"[]
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT ARRAY[
        'SUBMIT', 'VERIFY', 'DELEGATE', 'ESCALATE', 'RESUBMIT', 'CLAIM', 'RELEASE'
    ]::"workflow"."approval_action_type"[];
$$;

REVOKE ALL ON FUNCTION "workflow"."_non_invocable_actions"() FROM PUBLIC, "authenticated", "service_role";


-- ========================================================================
-- workflow.activate_workflow_version(...)
-- Item 11 FIX: trigger_action NULL check removed - the column is now
-- NOT NULL at the schema level (002/003), so no incomplete transition
-- row can exist to begin with. ADDED: minimum-transition-graph
-- reachability check - a configuration with valid FK rows but no
-- actual path from the initial status to any terminal status is now
-- rejected at activation, not discovered later at runtime. Item 10:
-- reachability now only follows runtime-executable trigger_action
-- edges (see _non_invocable_actions() above).
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."activate_workflow_version"("p_workflow_version_id" uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, core, auth
AS $$
DECLARE
    v_version "workflow"."workflow_versions"%ROWTYPE;
    v_initial_count int;
    v_terminal_count int;
    v_steps_without_assignees int;
    v_bad_min_n int;
    v_terminal_reachable boolean;
BEGIN
    IF NOT core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE') THEN
        RAISE EXCEPTION 'WORKFLOW_PERMISSION_DENIED: WORKFLOW_CONFIG_MANAGE required to activate a workflow version';
    END IF;

    SELECT * INTO v_version FROM "workflow"."workflow_versions" WHERE "id" = p_workflow_version_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WORKFLOW_VERSION_NOT_FOUND: %', p_workflow_version_id;
    END IF;
    IF v_version."status" <> 'DRAFT' THEN
        RAISE EXCEPTION 'WORKFLOW_VERSION_NOT_DRAFT: only a DRAFT version can be activated, current status %', v_version."status";
    END IF;

    SELECT count(*) INTO v_initial_count
    FROM "workflow"."workflow_statuses" WHERE "workflow_version_id" = p_workflow_version_id AND "is_initial" = true;
    IF v_initial_count <> 1 THEN
        RAISE EXCEPTION 'WORKFLOW_ACTIVATION_FAILED: exactly one initial status is required, found %', v_initial_count;
    END IF;

    SELECT count(*) INTO v_terminal_count
    FROM "workflow"."workflow_statuses" WHERE "workflow_version_id" = p_workflow_version_id AND "is_terminal" = true;
    IF v_terminal_count < 1 THEN
        RAISE EXCEPTION 'WORKFLOW_ACTIVATION_FAILED: at least one terminal status is required';
    END IF;

    SELECT count(*) INTO v_steps_without_assignees
    FROM "workflow"."workflow_steps" ws
    WHERE ws."workflow_version_id" = p_workflow_version_id
      AND NOT EXISTS (SELECT 1 FROM "workflow"."workflow_step_assignees" a WHERE a."workflow_step_id" = ws."id");
    IF v_steps_without_assignees > 0 THEN
        RAISE EXCEPTION 'WORKFLOW_ACTIVATION_FAILED: % step(s) have no configured assignees', v_steps_without_assignees;
    END IF;

    -- Best-effort, statically-checkable-only MIN_N sanity check
    -- (unchanged scope from before - ROLE/PERMISSION steps are
    -- checked at materialization time instead, in
    -- _materialize_stage() above - your review confirmed this split
    -- is acceptable as long as the runtime check exists, which it now
    -- does).
    SELECT count(*) INTO v_bad_min_n
    FROM "workflow"."workflow_steps" ws
    WHERE ws."workflow_version_id" = p_workflow_version_id
      AND ws."approval_mode" = 'MIN_N'
      AND NOT EXISTS (
          SELECT 1 FROM "workflow"."workflow_step_assignees" a
          WHERE a."workflow_step_id" = ws."id" AND a."assignee_type" <> 'USER'
      )
      AND ws."required_approvals" > (
          SELECT count(DISTINCT COALESCE(a."user_id"::text, a."role_id"::text, a."permission_code"))
          FROM "workflow"."workflow_step_assignees" a WHERE a."workflow_step_id" = ws."id"
      );
    IF v_bad_min_n > 0 THEN
        RAISE EXCEPTION 'WORKFLOW_ACTIVATION_FAILED: % MIN_N step(s) require more approvals than their configured USER assignees can ever provide',
            v_bad_min_n;
    END IF;

    -- Item 11: minimum transition graph - from the initial status,
    -- following trigger_action edges, at least one terminal status
    -- must be reachable.
    WITH RECURSIVE "reachable" AS (
        SELECT ws."status_code" FROM "workflow"."workflow_statuses" ws
        WHERE ws."workflow_version_id" = p_workflow_version_id AND ws."is_initial" = true
        UNION
        SELECT tr."to_status" FROM "workflow"."transition_rules" tr
        JOIN "reachable" r ON r."status_code" = tr."from_status"
        WHERE tr."workflow_version_id" = p_workflow_version_id
          AND NOT (tr."trigger_action" = ANY ("workflow"."_non_invocable_actions"()))
    )
    SELECT EXISTS (
        SELECT 1 FROM "reachable" r
        JOIN "workflow"."workflow_statuses" ws
            ON ws."workflow_version_id" = p_workflow_version_id AND ws."status_code" = r."status_code"
        WHERE ws."is_terminal" = true
    ) INTO v_terminal_reachable;

    IF NOT v_terminal_reachable THEN
        RAISE EXCEPTION 'WORKFLOW_ACTIVATION_FAILED: no terminal status is reachable from the initial status via the configured transitions';
    END IF;

    UPDATE "workflow"."workflow_versions" SET "status" = 'ACTIVE' WHERE "id" = p_workflow_version_id;

    RETURN jsonb_build_object('status', 'ACTIVATED', 'workflow_version_id', p_workflow_version_id);
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."activate_workflow_version"(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "workflow"."activate_workflow_version"(uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "workflow"."activate_workflow_version"(uuid) TO "service_role";


-- ========================================================================
-- workflow._process_action_internal(...)  (FINAL)
--
-- Item 1: gate-checks authority at the moment of the individual
-- action (via _check_transition_authority, return value discarded for
-- step-level APPROVE/REJECT), then passes v_action_id through to
-- _advance_after_step_completion so stage advancement never
-- re-authorizes against the wrong actor.
-- Item 2: step-level workflow_steps.is_maker_checker is enforced here
-- again, alongside (not instead of) transition-level maker-checker.
-- Item 4: SKIP requires skip_allowed + optional skip_permission_code
-- AND passes _check_skip_quorum_safe before being recorded.
-- Item 9: request-level transition status_history rows now include
-- organization_id.
-- Item 12: RESUBMIT moved into the unimplemented-action list - it is
-- not safe to expose while is_open=false unconditionally blocks every
-- action including the one meant to reopen a closed request, and full
-- reopen semantics have not been designed.
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."_process_action_internal"(
    "p_approval_request_id" uuid,
    "p_actor_type" "workflow"."actor_type",
    "p_actor_user_id" uuid,
    "p_action" "workflow"."approval_action_type",
    "p_approval_step_id" uuid DEFAULT NULL,
    "p_comments" text DEFAULT NULL,
    "p_metadata" jsonb DEFAULT NULL,
    "p_idempotency_key" varchar(255) DEFAULT NULL,
    "p_expected_version" int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, core, auth, extensions
AS $$
DECLARE
    v_request "workflow"."approval_requests"%ROWTYPE;
    v_step "workflow"."approval_steps"%ROWTYPE;
    v_step_tmpl "workflow"."workflow_steps"%ROWTYPE;
    v_delegation_id uuid;
    v_principal_user_id uuid;
    v_action_id uuid;
    v_payload_hash text;
    v_existing_action "workflow"."approval_actions"%ROWTYPE;
    v_new_step_status "workflow"."step_status";
    v_request_level_actions "workflow"."approval_action_type"[] := ARRAY['CANCEL','RECALL'];
    v_step_level_actions "workflow"."approval_action_type"[] := ARRAY['APPROVE','REJECT','SKIP'];
    v_system_allowed_actions "workflow"."approval_action_type"[] := ARRAY['CANCEL'];
    v_to_status varchar(50);
    v_is_open_after boolean;
BEGIN
    -- Item 5: SUBMIT is not in v_request_level_actions above - it is
    -- only ever inserted internally by start_approval_request() and is
    -- never separately invocable here, closing the dual-lifecycle
    -- ambiguity (one workflow could otherwise be materialized-but-
    -- still-DRAFT via a separately callable SUBMIT transition).
    -- Item 10: dispatch guard uses the SAME list activation's
    -- reachability check uses, so they can't silently diverge.
    IF p_action = ANY("workflow"."_non_invocable_actions"()) THEN
        RAISE EXCEPTION 'WORKFLOW_ACTION_NOT_IMPLEMENTED: % has no runtime semantics in this RPC yet', p_action;
    END IF;

    IF p_actor_type = 'SYSTEM' AND NOT (p_action = ANY(v_system_allowed_actions)) THEN
        RAISE EXCEPTION 'WORKFLOW_SYSTEM_ACTION_NOT_ALLOWED: SYSTEM may not perform %', p_action;
    END IF;

    IF p_action = ANY(v_request_level_actions) AND p_approval_step_id IS NOT NULL THEN
        RAISE EXCEPTION 'WORKFLOW_ACTION_SHAPE_INVALID: % is request-level and must not specify approval_step_id', p_action;
    END IF;
    IF p_action = ANY(v_step_level_actions) AND p_approval_step_id IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_ACTION_SHAPE_INVALID: % is step-level and requires approval_step_id', p_action;
    END IF;

    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_IDEMPOTENCY_KEY_REQUIRED';
    END IF;
    IF p_actor_type = 'USER' AND p_expected_version IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_EXPECTED_VERSION_REQUIRED';
    END IF;
    IF p_actor_type = 'USER' AND p_actor_user_id IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_ACTOR_USER_ID_REQUIRED';
    END IF;
    IF p_actor_type = 'SYSTEM' AND p_actor_user_id IS NOT NULL THEN
        RAISE EXCEPTION 'WORKFLOW_ACTOR_USER_ID_MUST_BE_NULL_FOR_SYSTEM';
    END IF;

    SELECT * INTO v_request FROM "workflow"."approval_requests" WHERE "id" = p_approval_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WORKFLOW_REQUEST_NOT_FOUND: %', p_approval_request_id;
    END IF;

    v_payload_hash := encode(
        digest(
            p_action::text || '|' || COALESCE(p_approval_step_id::text, '') || '|' ||
            COALESCE(p_comments, '') || '|' || COALESCE(p_metadata::text, ''),
            'sha256'
        ), 'hex'
    );

    SELECT * INTO v_existing_action
    FROM "workflow"."approval_actions"
    WHERE "approval_request_id" = p_approval_request_id AND "idempotency_key" = p_idempotency_key;

    IF FOUND THEN
        IF v_existing_action."actor_user_id" IS DISTINCT FROM p_actor_user_id
           OR v_existing_action."actor_type" <> p_actor_type
           OR v_existing_action."action" <> p_action
           OR v_existing_action."approval_step_id" IS DISTINCT FROM p_approval_step_id
           OR v_existing_action."payload_hash" IS DISTINCT FROM v_payload_hash THEN
            RAISE EXCEPTION 'WORKFLOW_IDEMPOTENCY_KEY_REUSE_MISMATCH: key % was already used for a different actor/action/step/payload on this request',
                p_idempotency_key;
        END IF;
        RETURN jsonb_build_object('status', 'ALREADY_PROCESSED', 'approval_action_id', v_existing_action."id");
    END IF;

    IF p_expected_version IS NOT NULL AND v_request."version" <> p_expected_version THEN
        RAISE EXCEPTION 'WORKFLOW_CONCURRENCY_CONFLICT: expected version %, found %', p_expected_version, v_request."version";
    END IF;

    IF NOT v_request."is_open" THEN
        RAISE EXCEPTION 'WORKFLOW_REQUEST_CLOSED: request % is not open', p_approval_request_id;
    END IF;

    IF p_approval_step_id IS NOT NULL THEN
        SELECT * INTO v_step FROM "workflow"."approval_steps" WHERE "id" = p_approval_step_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WORKFLOW_STEP_NOT_FOUND: %', p_approval_step_id;
        END IF;
        IF v_step."approval_request_id" <> p_approval_request_id THEN
            RAISE EXCEPTION 'WORKFLOW_STEP_REQUEST_MISMATCH';
        END IF;
        IF v_step."status" NOT IN ('PENDING', 'IN_PROGRESS') THEN
            RAISE EXCEPTION 'WORKFLOW_STEP_NOT_ACTIVE: step % is % and cannot be acted on', p_approval_step_id, v_step."status";
        END IF;

        SELECT * INTO v_step_tmpl FROM "workflow"."workflow_steps" WHERE "id" = v_step."workflow_step_id";
    END IF;

    v_delegation_id := NULL;
    v_principal_user_id := p_actor_user_id;

    IF p_actor_type = 'USER' AND p_approval_step_id IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM "workflow"."approval_step_assignees"
            WHERE "approval_step_id" = p_approval_step_id AND "assignee_user_id" = p_actor_user_id
        ) THEN
            v_principal_user_id := p_actor_user_id;
        ELSE
            SELECT d."id", d."delegator_user_id"
                INTO v_delegation_id, v_principal_user_id
            FROM "workflow"."delegations" d
            JOIN "workflow"."approval_step_assignees" asa
                ON asa."assignee_user_id" = d."delegator_user_id" AND asa."approval_step_id" = p_approval_step_id
            WHERE d."delegate_user_id" = p_actor_user_id
              AND d."is_active" = true
              AND now() BETWEEN d."valid_from" AND d."valid_to"
              AND (d."module" IS NULL OR d."module" = v_request."module")
              AND d."organization_id" IS NOT DISTINCT FROM v_request."organization_id"
              AND (d."role_id" IS NULL OR d."role_id" = asa."resolved_from_role_id")
            LIMIT 1;

            IF v_principal_user_id IS NULL THEN
                RAISE EXCEPTION 'WORKFLOW_ACTOR_NOT_ELIGIBLE_ASSIGNEE';
            END IF;
        END IF;

        IF p_action IN ('APPROVE', 'REJECT', 'SKIP') AND EXISTS (
            SELECT 1 FROM "workflow"."approval_step_assignees"
            WHERE "approval_step_id" = p_approval_step_id
              AND "assignee_user_id" = v_principal_user_id AND "status" <> 'PENDING'
        ) THEN
            RAISE EXCEPTION 'WORKFLOW_ASSIGNEE_ALREADY_ACTED';
        END IF;

        -- Item 2: step-level maker-checker, restored - separate from
        -- and enforced IN ADDITION TO transition-level maker-checker.
        IF p_action = 'APPROVE' AND v_step_tmpl."is_maker_checker"
           AND (p_actor_user_id = v_request."initiated_by_user_id" OR v_principal_user_id = v_request."initiated_by_user_id") THEN
            RAISE EXCEPTION 'WORKFLOW_MAKER_CHECKER_VIOLATION: step-level maker-checker blocks the initiator (directly or via delegation)';
        END IF;
    END IF;

    -- Item 4: SKIP authorization + quorum-safety guard.
    IF p_action = 'SKIP' THEN
        IF NOT v_step_tmpl."skip_allowed" THEN
            RAISE EXCEPTION 'WORKFLOW_SKIP_NOT_AUTHORIZED: this step does not permit SKIP';
        END IF;
        IF v_step_tmpl."skip_permission_code" IS NOT NULL
           AND NOT core.has_permission(p_actor_user_id, v_step_tmpl."skip_permission_code") THEN
            RAISE EXCEPTION 'WORKFLOW_SKIP_NOT_AUTHORIZED: missing %', v_step_tmpl."skip_permission_code";
        END IF;
        IF NOT "workflow"."_check_skip_quorum_safe"(p_approval_step_id, v_principal_user_id) THEN
            RAISE EXCEPTION 'WORKFLOW_SKIP_WOULD_MAKE_QUORUM_IMPOSSIBLE: skipping this assignee would make the step unresolvable';
        END IF;
    END IF;

    -- Gate-check authority for APPROVE/REJECT against the CURRENT
    -- status's transition. Return value intentionally discarded here -
    -- application happens only once the whole stage resolves, inside
    -- _advance_after_step_completion (item 1).
    IF p_action IN ('APPROVE', 'REJECT') THEN
        PERFORM "workflow"."_check_transition_authority"(
            v_request."workflow_version_id", v_request."current_status", p_action,
            v_principal_user_id, p_actor_user_id, v_request."initiated_by_user_id"
        );
    END IF;

    IF p_action = ANY(v_request_level_actions) THEN
        v_to_status := "workflow"."_check_transition_authority"(
            v_request."workflow_version_id", v_request."current_status", p_action,
            p_actor_user_id, p_actor_user_id, v_request."initiated_by_user_id"
        );
    END IF;

    INSERT INTO "workflow"."approval_actions" (
        "approval_request_id", "approval_step_id", "actor_type", "actor_user_id",
        "action", "idempotency_key", "delegation_id", "comments", "metadata", "payload_hash"
    ) VALUES (
        p_approval_request_id, p_approval_step_id, p_actor_type, p_actor_user_id,
        p_action, p_idempotency_key, v_delegation_id, p_comments, p_metadata, v_payload_hash
    ) RETURNING "id" INTO v_action_id;

    IF p_approval_step_id IS NOT NULL AND p_action IN ('APPROVE', 'REJECT', 'SKIP') THEN
        UPDATE "workflow"."approval_step_assignees"
        SET "status" = (CASE p_action WHEN 'APPROVE' THEN 'APPROVED' WHEN 'REJECT' THEN 'REJECTED' ELSE 'SKIPPED' END)::"workflow"."assignee_status",
            "responded_at" = now()
        WHERE "approval_step_id" = p_approval_step_id AND "assignee_user_id" = v_principal_user_id;

        v_new_step_status := "workflow"."_evaluate_step_outcome"(p_approval_step_id);

        -- Item 2: outcome_action_id traces the step's APPROVED/REJECTED
        -- result to the SPECIFIC action that caused it - only set when
        -- THIS action's type matches the outcome it just produced
        -- (an APPROVE that resulted in APPROVED, or a REJECT that
        -- resulted in REJECTED). A SKIP never sets it, even when it is
        -- the action that completes an ALL_OF step's quorum by
        -- shrinking the countable denominator - SKIP is not approval
        -- evidence, so the field is left pointing at whatever prior
        -- APPROVE already satisfied quorum, or stays NULL if none did
        -- (a scenario status_history / callers should treat as
        -- "resolved via quorum reduction, not a specific approval").
        UPDATE "workflow"."approval_steps"
        SET "status" = v_new_step_status,
            "outcome_action_id" = CASE
                WHEN p_action = 'APPROVE' AND v_new_step_status = 'APPROVED' THEN v_action_id
                WHEN p_action = 'REJECT' AND v_new_step_status = 'REJECTED' THEN v_action_id
                ELSE "outcome_action_id"
            END,
            "started_at" = COALESCE("started_at", now()),
            "completed_at" = CASE WHEN v_new_step_status IN ('APPROVED', 'REJECTED') THEN now() ELSE "completed_at" END,
            "updated_at" = now(),
            "version" = "version" + 1
        WHERE "id" = p_approval_step_id;

        IF v_new_step_status IN ('APPROVED', 'REJECTED') THEN
            PERFORM "workflow"."_advance_after_step_completion"(p_approval_request_id, p_approval_step_id, v_action_id);
        END IF;
    ELSIF p_action = ANY(v_request_level_actions) THEN
        SELECT EXISTS (
            SELECT 1 FROM "workflow"."workflow_statuses" ws
            WHERE ws."workflow_version_id" = v_request."workflow_version_id"
              AND ws."status_code" = v_to_status AND ws."is_terminal" = true
        ) INTO v_is_open_after;

        UPDATE "workflow"."approval_requests"
        SET "current_status" = v_to_status,
            "is_open" = NOT v_is_open_after,
            "completed_at" = CASE WHEN v_is_open_after THEN now() ELSE "completed_at" END,
            "updated_at" = now(),
            "version" = "version" + 1
        WHERE "id" = p_approval_request_id;

        -- Item 14: a request-level action that closes the request must
        -- not leave stale PENDING/IN_PROGRESS runtime steps behind -
        -- those would otherwise still look "active" to SLA scheduling
        -- and reporting after the parent request is already closed.
        IF v_is_open_after THEN
            UPDATE "workflow"."approval_steps"
            SET "status" = 'CANCELLED',
                "completed_at" = now(),
                "updated_at" = now(),
                "version" = "version" + 1
            WHERE "approval_request_id" = p_approval_request_id
              AND "status" IN ('PENDING', 'IN_PROGRESS');

            UPDATE "workflow"."approval_step_assignees"
            SET "status" = 'CANCELLED'
            WHERE "approval_step_id" IN (
                SELECT "id" FROM "workflow"."approval_steps"
                WHERE "approval_request_id" = p_approval_request_id AND "status" = 'CANCELLED'
            )
            AND "status" = 'PENDING';
        END IF;

        INSERT INTO "workflow"."status_history" (
            "organization_id", "approval_request_id", "approval_step_id", "workflow_version_id",
            "triggered_by_approval_action_id", "from_status", "to_status",
            "changed_by_user_id", "changed_by_actor_type", "reason"
        ) VALUES (
            v_request."organization_id", p_approval_request_id, NULL, v_request."workflow_version_id",
            v_action_id, v_request."current_status", v_to_status, p_actor_user_id, p_actor_type, p_comments
        );
    END IF;

    PERFORM pg_notify('workflow_events', jsonb_build_object(
        'event', 'approval_action_processed',
        'approval_request_id', p_approval_request_id,
        'approval_step_id', p_approval_step_id,
        'action', p_action,
        'actor_type', p_actor_type,
        'actor_user_id', p_actor_user_id,
        'principal_user_id', v_principal_user_id,
        'approval_action_id', v_action_id
    )::text);

    PERFORM "audit"."log_manual"(
        'workflow', 'approval_requests', p_approval_request_id, p_action::text,
        NULL, NULL, p_comments, 'workflow', v_action_id
    );

    RETURN jsonb_build_object(
        'status', 'OK', 'approval_action_id', v_action_id,
        'approval_request_id', p_approval_request_id, 'acted_as_principal', v_principal_user_id
    );
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."_process_action_internal"(
    uuid, "workflow"."actor_type", uuid, "workflow"."approval_action_type",
    uuid, text, jsonb, varchar(255), int
) FROM PUBLIC, "authenticated", "service_role";


CREATE OR REPLACE FUNCTION "workflow"."process_approval_action"(
    "p_approval_request_id" uuid,
    "p_action" "workflow"."approval_action_type",
    "p_approval_step_id" uuid DEFAULT NULL,
    "p_comments" text DEFAULT NULL,
    "p_metadata" jsonb DEFAULT NULL,
    "p_idempotency_key" varchar(255) DEFAULT NULL,
    "p_expected_version" int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, core, auth
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_UNAUTHENTICATED';
    END IF;
    RETURN "workflow"."_process_action_internal"(
        p_approval_request_id, 'USER', auth.uid(), p_action, p_approval_step_id,
        p_comments, p_metadata, p_idempotency_key, p_expected_version
    );
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."process_approval_action"(
    uuid, "workflow"."approval_action_type", uuid, text, jsonb, varchar(255), int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "workflow"."process_approval_action"(
    uuid, "workflow"."approval_action_type", uuid, text, jsonb, varchar(255), int
) TO "authenticated";


CREATE OR REPLACE FUNCTION "workflow"."process_system_action"(
    "p_approval_request_id" uuid,
    "p_action" "workflow"."approval_action_type",
    "p_approval_step_id" uuid DEFAULT NULL,
    "p_comments" text DEFAULT NULL,
    "p_metadata" jsonb DEFAULT NULL,
    "p_idempotency_key" varchar(255) DEFAULT NULL,
    "p_expected_version" int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, core, auth
AS $$
BEGIN
    RETURN "workflow"."_process_action_internal"(
        p_approval_request_id, 'SYSTEM', NULL, p_action, p_approval_step_id,
        p_comments, p_metadata, p_idempotency_key, p_expected_version
    );
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."process_system_action"(
    uuid, "workflow"."approval_action_type", uuid, text, jsonb, varchar(255), int
) FROM PUBLIC, "authenticated";
GRANT EXECUTE ON FUNCTION "workflow"."process_system_action"(
    uuid, "workflow"."approval_action_type", uuid, text, jsonb, varchar(255), int
) TO "service_role";

COMMENT ON FUNCTION "workflow"."process_system_action" IS
  'service_role-only. SYSTEM allowlist is CANCEL only.';


-- ========================================================================
-- workflow.resolve_sla_escalation(...)  (NEW - item 13)
-- Audit-grade replacement for direct UPDATE on sla_escalations.
-- resolved_by_user_id and resolved_at are derived server-side from
-- auth.uid()/now() - a caller can no longer claim that a DIFFERENT
-- person resolved an escalation, which a direct UPDATE (even with a
-- column-restricting trigger) could not prevent since the trigger only
-- controlled WHICH columns changed, not WHAT VALUES the caller
-- supplied for them. 005 revokes direct UPDATE on this table entirely
-- and grants EXECUTE on this function instead.
-- ========================================================================
CREATE OR REPLACE FUNCTION "workflow"."resolve_sla_escalation"(
    "p_sla_escalation_id" uuid,
    "p_resolution_code" varchar(50),
    "p_resolution_notes" text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, core, auth
AS $$
DECLARE
    v_actor_user_id uuid := auth.uid();
    v_escalation "workflow"."sla_escalations"%ROWTYPE;
    v_is_target boolean;
BEGIN
    IF v_actor_user_id IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_UNAUTHENTICATED';
    END IF;

    SELECT * INTO v_escalation FROM "workflow"."sla_escalations" WHERE "id" = p_sla_escalation_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WORKFLOW_SLA_ESCALATION_NOT_FOUND: %', p_sla_escalation_id;
    END IF;

    IF v_escalation."status" IN ('RESOLVED', 'EXPIRED') THEN
        RAISE EXCEPTION 'WORKFLOW_SLA_ESCALATION_ALREADY_CLOSED: escalation % is already %', p_sla_escalation_id, v_escalation."status";
    END IF;

    v_is_target := (
        v_escalation."escalated_to_user_id" = v_actor_user_id
        OR (
            v_escalation."escalated_to_role_id" IS NOT NULL
            AND EXISTS (
                SELECT 1 FROM "core"."user_roles" ur
                WHERE ur."user_id" = v_actor_user_id
                  AND ur."role_id" = v_escalation."escalated_to_role_id"
                  AND ur."is_active" = true
            )
        )
    );

    IF NOT v_is_target AND NOT core.has_permission(v_actor_user_id, 'WORKFLOW_VIEW_ALL') THEN
        RAISE EXCEPTION 'WORKFLOW_SLA_ESCALATION_NOT_AUTHORIZED: not the escalation target and missing WORKFLOW_VIEW_ALL';
    END IF;

    UPDATE "workflow"."sla_escalations"
    SET "status" = 'RESOLVED',
        "resolved_at" = now(),
        "resolved_by_user_id" = v_actor_user_id,
        "resolution_code" = p_resolution_code,
        "resolution_notes" = p_resolution_notes
    WHERE "id" = p_sla_escalation_id;

    RETURN jsonb_build_object(
        'status', 'RESOLVED', 'sla_escalation_id', p_sla_escalation_id,
        'resolved_by_user_id', v_actor_user_id
    );
END;
$$;

REVOKE ALL ON FUNCTION "workflow"."resolve_sla_escalation"(uuid, varchar(50), text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "workflow"."resolve_sla_escalation"(uuid, varchar(50), text) TO "authenticated";


-- ========================================================================
-- END 004_workflow_functions_triggers.sql
-- ========================================================================
