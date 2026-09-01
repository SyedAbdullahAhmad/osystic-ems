-- ========================================================================
-- 005_workflow_rls_grants.sql
--
-- DEPENDENCY: 001-004 already applied.
--
-- GAP CLOSED HERE (flagged, not silently added): review item 3 requires
-- "Published workflow versions must be immutable" - 003/004 enforced
-- at-most-one-ACTIVE-version and the version/definition consistency
-- checks, but nothing yet stopped someone from editing workflow_steps /
-- workflow_statuses / transition_rules UNDER an already-ACTIVE version.
-- That's a real gap in the "immutable once published" guarantee, so a
-- trigger closing it is added below, ahead of the RLS/grants work this
-- file is named for.
--
-- CORE PRINCIPLE ENFORCED THROUGHOUT: runtime workflow tables
-- (approval_requests, approval_steps, approval_step_assignees,
-- approval_actions, status_history) get INSERT/UPDATE/DELETE REVOKED
-- from the authenticated role entirely. All mutation of those tables
-- happens through workflow.process_approval_action() (004), which
-- runs SECURITY DEFINER as the function owner - REVOKEs on the calling
-- role do not block the function's own writes. This is the mechanism
-- that actually enforces "every module must call this function instead
-- of directly updating workflow tables," not just documentation.
-- ========================================================================

-- ------------------------------------------------------------------------
-- ROUND 5 CORRECTION: schema-level USAGE grant, missing from this
-- entire migration set until now. Every table-level GRANT below (and
-- the RLS policies that further restrict what rows are visible) is
-- moot without this - Postgres checks USAGE on the SCHEMA an object
-- lives in before it ever gets to table-level GRANTs or RLS, so
-- "authenticated" would hit "permission denied for schema workflow"
-- on literally any direct query against a workflow.* table, no matter
-- how correctly everything else in this file is configured. This is
-- exactly the failure mode that surfaced the gap: every previous
-- successful authenticated-role test happened to go through a
-- SECURITY DEFINER function (which runs as the function owner, not
-- the caller, so schema USAGE by the caller was never actually
-- exercised) rather than a raw SELECT - the first raw
-- "SELECT ... FROM workflow.approval_requests" as authenticated (008's
-- rls_visibility suite) is what finally caught it.
-- ------------------------------------------------------------------------
GRANT USAGE ON SCHEMA "workflow" TO "authenticated";
GRANT USAGE ON SCHEMA "workflow" TO "service_role";


-- ------------------------------------------------------------------------
-- Item 4 (round 3): actor-integrity enforcement for created_by/updated_by.
-- workflow_definitions, workflow_versions, and delegations are all
-- directly INSERT-able by authenticated (gated by RLS below), which
-- means created_by would otherwise be whatever the client's INSERT
-- statement supplied - trivially spoofable. This forces it to the
-- actual caller on every INSERT, unconditionally, regardless of what
-- value the client sent. This is distinct from delegator_user_id on
-- delegations, which MAY legitimately differ from the caller (an admin
-- with WORKFLOW_CONFIG_MANAGE setting up a delegation on someone
-- else's behalf) - created_by still must record who actually performed
-- the write, not who the record is about.
-- workflow_definitions also has updated_by, force-set the same way on
-- every UPDATE (it is the only workflow-config table with this
-- column).
-- ------------------------------------------------------------------------
-- Item 4 (round 4), DOCUMENTED DECISION: workflow configuration
-- seeding (workflow_definitions, workflow_versions, and by extension
-- delegations) MUST be created through an authenticated admin session
-- - a real person holding WORKFLOW_CONFIG_MANAGE, acting through the
-- app or a controlled admin RPC - NEVER through a bare service_role/
-- migration-script INSERT with no JWT context. This is the "controlled
-- admin tooling/RPCs" option, not the "approved system/service actor"
-- option: no synthetic system auth.users row is introduced. Future
-- module workflow-definition seeds (leave, onboarding, etc.) must
-- either (a) be applied by a named human admin authenticating and
-- running the INSERT themselves/through an admin UI, or (b) go through
-- a SECURITY DEFINER admin RPC that itself requires auth.uid() to be
-- present and WORKFLOW_CONFIG_MANAGE to be held - never a raw
-- migration file executed as service_role with no session. If
-- auth.uid() is unavailable when these triggers fire, that is treated
-- as a hard configuration error, not silently worked around with a
-- NULL or fabricated actor id.
CREATE OR REPLACE FUNCTION "workflow"."_force_created_by"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, auth
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_CREATED_BY_REQUIRES_AUTHENTICATED_SESSION: % must be created through an authenticated admin session (see decision note above), not a bare service_role INSERT with no JWT context', TG_TABLE_NAME;
    END IF;
    NEW."created_by" := auth.uid();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION "workflow"."_force_updated_by"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, auth
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'WORKFLOW_UPDATED_BY_REQUIRES_AUTHENTICATED_SESSION: % must be updated through an authenticated admin session, not a bare service_role UPDATE with no JWT context', TG_TABLE_NAME;
    END IF;
    NEW."updated_by" := auth.uid();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_workflow_definitions_force_created_by" ON "workflow"."workflow_definitions";
CREATE TRIGGER "trg_workflow_definitions_force_created_by"
    BEFORE INSERT ON "workflow"."workflow_definitions"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."_force_created_by"();

DROP TRIGGER IF EXISTS "trg_workflow_definitions_force_updated_by" ON "workflow"."workflow_definitions";
CREATE TRIGGER "trg_workflow_definitions_force_updated_by"
    BEFORE UPDATE ON "workflow"."workflow_definitions"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."_force_updated_by"();

DROP TRIGGER IF EXISTS "trg_workflow_versions_force_created_by" ON "workflow"."workflow_versions";
CREATE TRIGGER "trg_workflow_versions_force_created_by"
    BEFORE INSERT ON "workflow"."workflow_versions"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."_force_created_by"();

DROP TRIGGER IF EXISTS "trg_delegations_force_created_by" ON "workflow"."delegations";
CREATE TRIGGER "trg_delegations_force_created_by"
    BEFORE INSERT ON "workflow"."delegations"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."_force_created_by"();


-- ------------------------------------------------------------------------
-- Immutability of published (ACTIVE) workflow versions - closes the
-- gap noted above.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "workflow"."prevent_active_version_child_mutation"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_version_id uuid;
    v_status "workflow"."workflow_version_status";
BEGIN
    v_version_id := COALESCE(NEW."workflow_version_id", OLD."workflow_version_id");

    SELECT "status" INTO v_status
    FROM "workflow"."workflow_versions"
    WHERE "id" = v_version_id;

    IF v_status IN ('ACTIVE', 'RETIRED') THEN
        RAISE EXCEPTION 'WORKFLOW_VERSION_IMMUTABLE: cannot % %.% belonging to an ACTIVE or RETIRED workflow version',
            TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS "trg_workflow_steps_version_immutable" ON "workflow"."workflow_steps";
CREATE TRIGGER "trg_workflow_steps_version_immutable"
    BEFORE INSERT OR UPDATE OR DELETE ON "workflow"."workflow_steps"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."prevent_active_version_child_mutation"();

DROP TRIGGER IF EXISTS "trg_workflow_statuses_version_immutable" ON "workflow"."workflow_statuses";
CREATE TRIGGER "trg_workflow_statuses_version_immutable"
    BEFORE INSERT OR UPDATE OR DELETE ON "workflow"."workflow_statuses"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."prevent_active_version_child_mutation"();

DROP TRIGGER IF EXISTS "trg_transition_rules_version_immutable" ON "workflow"."transition_rules";
CREATE TRIGGER "trg_transition_rules_version_immutable"
    BEFORE INSERT OR UPDATE OR DELETE ON "workflow"."transition_rules"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."prevent_active_version_child_mutation"();

-- workflow_step_assignees doesn't carry workflow_version_id directly -
-- separate function that looks it up via the parent workflow_step.
CREATE OR REPLACE FUNCTION "workflow"."prevent_active_version_assignee_mutation"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_status "workflow"."workflow_version_status";
BEGIN
    SELECT wv."status" INTO v_status
    FROM "workflow"."workflow_steps" ws
    JOIN "workflow"."workflow_versions" wv ON wv."id" = ws."workflow_version_id"
    WHERE ws."id" = COALESCE(NEW."workflow_step_id", OLD."workflow_step_id");

    IF v_status IN ('ACTIVE', 'RETIRED') THEN
        RAISE EXCEPTION 'WORKFLOW_VERSION_IMMUTABLE: cannot % workflow_step_assignees for a step belonging to an ACTIVE or RETIRED workflow version',
            TG_OP;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS "trg_workflow_step_assignees_version_immutable" ON "workflow"."workflow_step_assignees";
CREATE TRIGGER "trg_workflow_step_assignees_version_immutable"
    BEFORE INSERT OR UPDATE OR DELETE ON "workflow"."workflow_step_assignees"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."prevent_active_version_assignee_mutation"();


-- ------------------------------------------------------------------------
-- Delegation core-field immutability - only revocation fields may be
-- updated after creation (append-only aside from revocation, as
-- documented since v2).
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "workflow"."prevent_delegation_core_field_change"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, auth
AS $$
BEGIN
    -- Item 12: allowlist, not denylist - ONLY revoked_at, revoked_by,
    -- revocation_reason, and is_active may differ from OLD. Anything
    -- not explicitly allowed (including organization_id, created_by,
    -- created_at, version, and any future column) is implicitly
    -- protected, rather than needing to be named here every time a
    -- column is added.
    IF NEW."id" <> OLD."id"
       OR NEW."organization_id" IS DISTINCT FROM OLD."organization_id"
       OR NEW."delegator_user_id" <> OLD."delegator_user_id"
       OR NEW."delegate_user_id" <> OLD."delegate_user_id"
       OR NEW."role_id" IS DISTINCT FROM OLD."role_id"
       OR NEW."module" IS DISTINCT FROM OLD."module"
       OR NEW."valid_from" <> OLD."valid_from"
       OR NEW."valid_to" <> OLD."valid_to"
       OR NEW."reason" IS DISTINCT FROM OLD."reason"
       OR NEW."created_at" <> OLD."created_at"
       OR NEW."created_by" <> OLD."created_by"
    THEN
        RAISE EXCEPTION 'WORKFLOW_DELEGATION_CORE_FIELDS_IMMUTABLE: only revocation fields (revoked_at, revoked_by, revocation_reason, is_active) may change after creation';
    END IF;

    -- Item 12: revocation is one-way - an already-revoked/inactive
    -- delegation must never be reactivated.
    IF OLD."is_active" = false AND NEW."is_active" = true THEN
        RAISE EXCEPTION 'WORKFLOW_DELEGATION_REACTIVATION_DENIED: a revoked delegation cannot be reactivated';
    END IF;

    -- Item 12: revoked_by is server-controlled, not caller-suppliable -
    -- when a revocation is actually happening (is_active flips to
    -- false, or revoked_at is being set for the first time),
    -- revoked_by must be the actual caller performing it.
    IF (NEW."is_active" = false AND OLD."is_active" = true)
       OR (NEW."revoked_at" IS NOT NULL AND OLD."revoked_at" IS NULL) THEN
        IF NEW."revoked_by" IS DISTINCT FROM auth.uid() THEN
            RAISE EXCEPTION 'WORKFLOW_DELEGATION_REVOKED_BY_MUST_MATCH_CALLER: revoked_by must be the caller performing the revocation';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_delegations_restrict_update" ON "workflow"."delegations";
CREATE TRIGGER "trg_delegations_restrict_update"
    BEFORE UPDATE ON "workflow"."delegations"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."prevent_delegation_core_field_change"();


-- ------------------------------------------------------------------------
-- SLA escalation resolution-field-only update restriction, same pattern.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "workflow"."prevent_sla_escalation_core_field_change"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW."approval_step_id" <> OLD."approval_step_id"
       OR NEW."escalation_level" <> OLD."escalation_level"
       OR NEW."due_at" <> OLD."due_at"
       OR NEW."escalated_to_user_id" IS DISTINCT FROM OLD."escalated_to_user_id"
       OR NEW."escalated_to_role_id" IS DISTINCT FROM OLD."escalated_to_role_id"
       OR NEW."escalated_at" <> OLD."escalated_at"
    THEN
        RAISE EXCEPTION 'WORKFLOW_SLA_ESCALATION_CORE_FIELDS_IMMUTABLE: only status, acknowledged_at, resolved_at, resolved_by_user_id, resolution_code, resolution_notes may change after creation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_sla_escalations_restrict_update" ON "workflow"."sla_escalations";
CREATE TRIGGER "trg_sla_escalations_restrict_update"
    BEFORE UPDATE ON "workflow"."sla_escalations"
    FOR EACH ROW EXECUTE FUNCTION "workflow"."prevent_sla_escalation_core_field_change"();


-- ------------------------------------------------------------------------
-- can_view_request() is now defined ONCE, in 004 (final, hardened
-- form: REVOKE ALL FROM PUBLIC, pinned search_path without 'public').
-- It is NOT redefined here. An earlier draft of this file re-declared
-- it with an older, less-hardened body - since 004 runs before 005 in
-- the apply order, that CREATE OR REPLACE would have silently
-- downgraded the function immediately after 004 established the
-- correct version. Removed rather than left as a latent regression.
-- ------------------------------------------------------------------------


-- ========================================================================
-- TABLE-BY-TABLE: RLS enable, grants, policies
-- ========================================================================

-- ------------------------------------------------------------------------
-- Config/template tables - readable by all authenticated users,
-- writable only by holders of WORKFLOW_CONFIG_MANAGE. No DELETE ever -
-- retire via workflow_versions.status = 'RETIRED' instead.
-- ------------------------------------------------------------------------

ALTER TABLE "workflow"."workflow_definitions" ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON "workflow"."workflow_definitions" TO "authenticated";
GRANT ALL ON "workflow"."workflow_definitions" TO "service_role";

CREATE POLICY "workflow_definitions_select" ON "workflow"."workflow_definitions"
    FOR SELECT TO "authenticated" USING (auth.uid() IS NOT NULL);
CREATE POLICY "workflow_definitions_insert" ON "workflow"."workflow_definitions"
    FOR INSERT TO "authenticated" WITH CHECK (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_definitions_update" ON "workflow"."workflow_definitions"
    FOR UPDATE TO "authenticated" USING (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_definitions_no_delete" ON "workflow"."workflow_definitions"
    FOR DELETE TO "authenticated" USING (false);


ALTER TABLE "workflow"."workflow_versions" ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON "workflow"."workflow_versions" TO "authenticated";
GRANT ALL ON "workflow"."workflow_versions" TO "service_role";

CREATE POLICY "workflow_versions_select" ON "workflow"."workflow_versions"
    FOR SELECT TO "authenticated" USING (auth.uid() IS NOT NULL);
CREATE POLICY "workflow_versions_insert" ON "workflow"."workflow_versions"
    FOR INSERT TO "authenticated" WITH CHECK (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_versions_update" ON "workflow"."workflow_versions"
    FOR UPDATE TO "authenticated" USING (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_versions_no_delete" ON "workflow"."workflow_versions"
    FOR DELETE TO "authenticated" USING (false);


ALTER TABLE "workflow"."workflow_statuses" ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON "workflow"."workflow_statuses" TO "authenticated";
GRANT ALL ON "workflow"."workflow_statuses" TO "service_role";

CREATE POLICY "workflow_statuses_select" ON "workflow"."workflow_statuses"
    FOR SELECT TO "authenticated" USING (auth.uid() IS NOT NULL);
CREATE POLICY "workflow_statuses_insert" ON "workflow"."workflow_statuses"
    FOR INSERT TO "authenticated" WITH CHECK (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_statuses_update" ON "workflow"."workflow_statuses"
    FOR UPDATE TO "authenticated" USING (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_statuses_no_delete" ON "workflow"."workflow_statuses"
    FOR DELETE TO "authenticated" USING (false);


ALTER TABLE "workflow"."workflow_steps" ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON "workflow"."workflow_steps" TO "authenticated";
GRANT ALL ON "workflow"."workflow_steps" TO "service_role";

CREATE POLICY "workflow_steps_select" ON "workflow"."workflow_steps"
    FOR SELECT TO "authenticated" USING (auth.uid() IS NOT NULL);
CREATE POLICY "workflow_steps_insert" ON "workflow"."workflow_steps"
    FOR INSERT TO "authenticated" WITH CHECK (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_steps_update" ON "workflow"."workflow_steps"
    FOR UPDATE TO "authenticated" USING (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_steps_no_delete" ON "workflow"."workflow_steps"
    FOR DELETE TO "authenticated" USING (false);


ALTER TABLE "workflow"."workflow_step_assignees" ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON "workflow"."workflow_step_assignees" TO "authenticated";
GRANT ALL ON "workflow"."workflow_step_assignees" TO "service_role";

CREATE POLICY "workflow_step_assignees_select" ON "workflow"."workflow_step_assignees"
    FOR SELECT TO "authenticated" USING (auth.uid() IS NOT NULL);
CREATE POLICY "workflow_step_assignees_insert" ON "workflow"."workflow_step_assignees"
    FOR INSERT TO "authenticated" WITH CHECK (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_step_assignees_update" ON "workflow"."workflow_step_assignees"
    FOR UPDATE TO "authenticated" USING (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "workflow_step_assignees_no_delete" ON "workflow"."workflow_step_assignees"
    FOR DELETE TO "authenticated" USING (false);


ALTER TABLE "workflow"."transition_rules" ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON "workflow"."transition_rules" TO "authenticated";
GRANT ALL ON "workflow"."transition_rules" TO "service_role";

CREATE POLICY "transition_rules_select" ON "workflow"."transition_rules"
    FOR SELECT TO "authenticated" USING (auth.uid() IS NOT NULL);
CREATE POLICY "transition_rules_insert" ON "workflow"."transition_rules"
    FOR INSERT TO "authenticated" WITH CHECK (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "transition_rules_update" ON "workflow"."transition_rules"
    FOR UPDATE TO "authenticated" USING (core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE'));
CREATE POLICY "transition_rules_no_delete" ON "workflow"."transition_rules"
    FOR DELETE TO "authenticated" USING (false);


-- ------------------------------------------------------------------------
-- Runtime tables - RPC-only writes. SELECT only for authenticated,
-- scoped by workflow.can_view_request(). INSERT/UPDATE/DELETE
-- explicitly REVOKED so no policy can accidentally allow a direct
-- write - the grant itself is the enforcement, not just RLS.
-- ------------------------------------------------------------------------

ALTER TABLE "workflow"."approval_requests" ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON "workflow"."approval_requests" FROM "authenticated";
GRANT SELECT ON "workflow"."approval_requests" TO "authenticated";
GRANT ALL ON "workflow"."approval_requests" TO "service_role";

CREATE POLICY "approval_requests_select" ON "workflow"."approval_requests"
    FOR SELECT TO "authenticated" USING (workflow.can_view_request("id"));


ALTER TABLE "workflow"."approval_steps" ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON "workflow"."approval_steps" FROM "authenticated";
GRANT SELECT ON "workflow"."approval_steps" TO "authenticated";
GRANT ALL ON "workflow"."approval_steps" TO "service_role";

CREATE POLICY "approval_steps_select" ON "workflow"."approval_steps"
    FOR SELECT TO "authenticated" USING (workflow.can_view_request("approval_request_id"));


ALTER TABLE "workflow"."approval_step_assignees" ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON "workflow"."approval_step_assignees" FROM "authenticated";
GRANT SELECT ON "workflow"."approval_step_assignees" TO "authenticated";
GRANT ALL ON "workflow"."approval_step_assignees" TO "service_role";

CREATE POLICY "approval_step_assignees_select" ON "workflow"."approval_step_assignees"
    FOR SELECT TO "authenticated" USING (
        "assignee_user_id" = auth.uid()
        OR workflow.can_view_request((
            SELECT s."approval_request_id" FROM "workflow"."approval_steps" s
            WHERE s."id" = "approval_step_assignees"."approval_step_id"
        ))
    );


ALTER TABLE "workflow"."approval_actions" ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON "workflow"."approval_actions" FROM "authenticated";
GRANT SELECT ON "workflow"."approval_actions" TO "authenticated";
GRANT ALL ON "workflow"."approval_actions" TO "service_role";

CREATE POLICY "approval_actions_select" ON "workflow"."approval_actions"
    FOR SELECT TO "authenticated" USING (workflow.can_view_request("approval_request_id"));


ALTER TABLE "workflow"."status_history" ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON "workflow"."status_history" FROM "authenticated";
GRANT SELECT ON "workflow"."status_history" TO "authenticated";
GRANT ALL ON "workflow"."status_history" TO "service_role";

CREATE POLICY "status_history_select" ON "workflow"."status_history"
    FOR SELECT TO "authenticated" USING (workflow.can_view_request("approval_request_id"));


-- ------------------------------------------------------------------------
-- Delegations - self-service, direct writes allowed (not via the RPC),
-- gated by RLS + the core-field-immutability trigger above.
-- ------------------------------------------------------------------------

ALTER TABLE "workflow"."delegations" ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON "workflow"."delegations" TO "authenticated";
GRANT ALL ON "workflow"."delegations" TO "service_role";

CREATE POLICY "delegations_select" ON "workflow"."delegations"
    FOR SELECT TO "authenticated" USING (
        "delegator_user_id" = auth.uid()
        OR "delegate_user_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'WORKFLOW_VIEW_ALL')
    );
CREATE POLICY "delegations_insert" ON "workflow"."delegations"
    FOR INSERT TO "authenticated" WITH CHECK (
        "delegator_user_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE')
    );
CREATE POLICY "delegations_update" ON "workflow"."delegations"
    FOR UPDATE TO "authenticated" USING (
        "delegator_user_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'WORKFLOW_CONFIG_MANAGE')
    );
CREATE POLICY "delegations_no_delete" ON "workflow"."delegations"
    FOR DELETE TO "authenticated" USING (false);


-- ------------------------------------------------------------------------
-- SLA escalations - creation is deferred to the future scheduled job
-- (see 004's design note), so INSERT stays revoked from authenticated.
-- Item 13: direct UPDATE is now ALSO revoked from authenticated -
-- resolution happens exclusively through workflow.resolve_sla_escalation()
-- (004, SECURITY DEFINER), which derives resolved_by_user_id/resolved_at
-- from auth.uid()/now() server-side. A direct-UPDATE path, even with
-- the column-restricting trigger still in place below as defense in
-- depth, could not stop a caller from supplying an arbitrary
-- resolved_by_user_id for one of the columns the trigger DID allow -
-- only removing the direct-write path entirely closes that.
-- ------------------------------------------------------------------------

ALTER TABLE "workflow"."sla_escalations" ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON "workflow"."sla_escalations" FROM "authenticated";
GRANT SELECT ON "workflow"."sla_escalations" TO "authenticated";
GRANT ALL ON "workflow"."sla_escalations" TO "service_role";

CREATE POLICY "sla_escalations_select" ON "workflow"."sla_escalations"
    FOR SELECT TO "authenticated" USING (
        "escalated_to_user_id" = auth.uid()
        OR core.has_permission(auth.uid(), 'WORKFLOW_VIEW_ALL')
        OR workflow.can_view_request((
            SELECT s."approval_request_id" FROM "workflow"."approval_steps" s
            WHERE s."id" = "sla_escalations"."approval_step_id"
        ))
    );
-- Item 13: sla_escalations_update policy REMOVED - UPDATE is revoked
-- from authenticated above, so a USING policy for it is unreachable.
-- Resolution now goes through workflow.resolve_sla_escalation() (004),
-- which is SECURITY DEFINER and performs its own authorization check
-- (escalation target, or WORKFLOW_VIEW_ALL) independent of RLS. Its
-- EXECUTE grant lives in 004, next to its definition - not repeated
-- here, per this file's own convention (see note below).


-- ------------------------------------------------------------------------
-- EXECUTE grants for process_approval_action / process_system_action /
-- start_approval_request / activate_workflow_version / can_view_request
-- are NOT repeated here - they are granted directly within 004, next
-- to each function's own definition, with the correct final signature.
-- An earlier draft of this file granted process_approval_action with
-- a stale 11-parameter signature left over from an intermediate patch
-- round; that signature no longer exists after the squash, and the
-- GRANT would have failed outright. Removed rather than "fixed" by
-- guessing the right signature twice in two files - 004 is the single
-- source of truth for these grants now.
-- ------------------------------------------------------------------------


-- ------------------------------------------------------------------------
-- request_start_idempotency (item 7, new table) - service-role/RPC-
-- managed only. Authenticated users never write to this table
-- directly; start_approval_request() (004) does so as its owner. Read
-- access is scoped to rows the caller created, mainly useful for
-- clients wanting to confirm their own idempotent-start result.
-- ------------------------------------------------------------------------

ALTER TABLE "workflow"."request_start_idempotency" ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON "workflow"."request_start_idempotency" FROM "authenticated";
GRANT SELECT ON "workflow"."request_start_idempotency" TO "authenticated";
GRANT ALL ON "workflow"."request_start_idempotency" TO "service_role";

CREATE POLICY "request_start_idempotency_select" ON "workflow"."request_start_idempotency"
    FOR SELECT TO "authenticated" USING ("created_by" = auth.uid());


-- ========================================================================
-- KNOWN GAP, FLAGGED: WORKFLOW_CONFIG_MANAGE and WORKFLOW_VIEW_ALL are
-- referenced throughout this file's policies via core.has_permission(),
-- but neither permission code is seeded anywhere yet. They must exist
-- as rows in core.permissions (Finance's existing table) before these
-- policies will ever evaluate true for anyone. This is exactly what
-- 006_workflow_reference_seed.sql is for - do not treat this file as
-- complete/deployable without it, since every admin-gated policy above
-- will otherwise deny everyone, including legitimate admins.
-- ========================================================================


-- ========================================================================
-- END 005_workflow_rls_grants.sql
-- ========================================================================
