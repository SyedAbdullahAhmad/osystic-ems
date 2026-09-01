-- ========================================================================
-- 003_workflow_constraints_indexes.sql  (CONSOLIDATED BASELINE)
--
-- DEPENDENCY: 001, 002 already applied.
--
-- Squashes the original 003 plus 003b's transition-action binding
-- constraint (simplified now that trigger_action is NOT NULL, so no
-- WHERE clause is needed) plus item 7's idempotency scope fix
-- (approval_actions.idempotency_key is composite-unique with
-- approval_request_id, never globally unique).
-- ========================================================================

CREATE EXTENSION IF NOT EXISTS "btree_gist";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";


-- ------------------------------------------------------------------------
-- 1. workflow_definitions
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."workflow_definitions"
    ADD CONSTRAINT "workflow_definitions_org_module_code_unique"
    UNIQUE ("organization_id", "module", "code");


-- ------------------------------------------------------------------------
-- 2. workflow_versions
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."workflow_versions"
    ADD CONSTRAINT "workflow_versions_definition_version_no_unique"
    UNIQUE ("workflow_definition_id", "version_no");

ALTER TABLE "workflow"."workflow_versions"
    ADD CONSTRAINT "workflow_versions_id_definition_unique"
    UNIQUE ("id", "workflow_definition_id");

CREATE UNIQUE INDEX "workflow_versions_one_active_per_definition"
    ON "workflow"."workflow_versions" ("workflow_definition_id")
    WHERE ("status" = 'ACTIVE');

ALTER TABLE "workflow"."workflow_versions"
    ADD CONSTRAINT "workflow_versions_version_no_positive"
    CHECK ("version_no" > 0);

ALTER TABLE "workflow"."workflow_versions"
    ADD CONSTRAINT "workflow_versions_effective_range"
    CHECK ("effective_from" IS NULL OR "effective_to" IS NULL OR "effective_to" > "effective_from");


-- ------------------------------------------------------------------------
-- 3. workflow_statuses
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."workflow_statuses"
    ADD CONSTRAINT "workflow_statuses_version_code_unique"
    UNIQUE ("workflow_version_id", "status_code");

ALTER TABLE "workflow"."workflow_statuses"
    ADD CONSTRAINT "workflow_statuses_version_definition_fk"
    FOREIGN KEY ("workflow_version_id", "workflow_definition_id")
    REFERENCES "workflow"."workflow_versions" ("id", "workflow_definition_id");

CREATE UNIQUE INDEX "workflow_statuses_one_initial_per_version"
    ON "workflow"."workflow_statuses" ("workflow_version_id")
    WHERE ("is_initial" = true);


-- ------------------------------------------------------------------------
-- 4. workflow_steps
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."workflow_steps"
    ADD CONSTRAINT "workflow_steps_version_step_key_unique"
    UNIQUE ("workflow_version_id", "step_key");

ALTER TABLE "workflow"."workflow_steps"
    ADD CONSTRAINT "workflow_steps_version_step_seq_unique"
    UNIQUE ("workflow_version_id", "step_no", "sequence_no");

ALTER TABLE "workflow"."workflow_steps"
    ADD CONSTRAINT "workflow_steps_id_version_unique"
    UNIQUE ("id", "workflow_version_id");

ALTER TABLE "workflow"."workflow_steps"
    ADD CONSTRAINT "workflow_steps_step_no_positive"
    CHECK ("step_no" > 0);

ALTER TABLE "workflow"."workflow_steps"
    ADD CONSTRAINT "workflow_steps_sequence_no_positive"
    CHECK ("sequence_no" > 0);

ALTER TABLE "workflow"."workflow_steps"
    ADD CONSTRAINT "workflow_steps_sla_minutes_non_negative"
    CHECK ("sla_minutes" >= 0);

ALTER TABLE "workflow"."workflow_steps"
    ADD CONSTRAINT "workflow_steps_min_n_requires_count"
    CHECK (
        ("approval_mode" <> 'MIN_N')
        OR ("required_approvals" IS NOT NULL AND "required_approvals" > 0)
    );

ALTER TABLE "workflow"."workflow_steps"
    ADD CONSTRAINT "workflow_steps_rejection_mode_valid"
    CHECK ("rejection_mode" IN ('ANY_REJECT', 'QUORUM_IMPOSSIBLE'));


-- ------------------------------------------------------------------------
-- 5. workflow_step_assignees
-- ------------------------------------------------------------------------
CREATE INDEX "workflow_step_assignees_step_id_idx"
    ON "workflow"."workflow_step_assignees" ("workflow_step_id");

ALTER TABLE "workflow"."workflow_step_assignees"
    ADD CONSTRAINT "workflow_step_assignees_single_target"
    CHECK (
        ("assignee_type" = 'ROLE' AND "role_id" IS NOT NULL AND "user_id" IS NULL AND "permission_code" IS NULL)
        OR ("assignee_type" = 'USER' AND "user_id" IS NOT NULL AND "role_id" IS NULL AND "permission_code" IS NULL)
        OR ("assignee_type" = 'PERMISSION' AND "permission_code" IS NOT NULL AND "role_id" IS NULL AND "user_id" IS NULL)
    );

-- Item 8: type-specific dedup. Without these, the same USER (or ROLE,
-- or PERMISSION code) could be configured twice on one step, letting
-- activation's static MIN_N count overstate how many DISTINCT
-- assignees will actually resolve at runtime.
CREATE UNIQUE INDEX "workflow_step_assignees_step_user_unique"
    ON "workflow"."workflow_step_assignees" ("workflow_step_id", "user_id")
    WHERE ("assignee_type" = 'USER');

CREATE UNIQUE INDEX "workflow_step_assignees_step_role_unique"
    ON "workflow"."workflow_step_assignees" ("workflow_step_id", "role_id")
    WHERE ("assignee_type" = 'ROLE');

CREATE UNIQUE INDEX "workflow_step_assignees_step_permission_unique"
    ON "workflow"."workflow_step_assignees" ("workflow_step_id", "permission_code")
    WHERE ("assignee_type" = 'PERMISSION');


-- ------------------------------------------------------------------------
-- 6. transition_rules
-- trigger_action is NOT NULL (baked into 002 now), so this unique
-- index no longer needs a partial WHERE clause - every row
-- participates.
-- ------------------------------------------------------------------------
CREATE INDEX "transition_rules_version_definition_idx"
    ON "workflow"."transition_rules" ("workflow_version_id", "workflow_definition_id");

ALTER TABLE "workflow"."transition_rules"
    ADD CONSTRAINT "transition_rules_version_definition_fk"
    FOREIGN KEY ("workflow_version_id", "workflow_definition_id")
    REFERENCES "workflow"."workflow_versions" ("id", "workflow_definition_id");

ALTER TABLE "workflow"."transition_rules"
    ADD CONSTRAINT "transition_rules_from_status_fk"
    FOREIGN KEY ("workflow_version_id", "from_status")
    REFERENCES "workflow"."workflow_statuses" ("workflow_version_id", "status_code");

ALTER TABLE "workflow"."transition_rules"
    ADD CONSTRAINT "transition_rules_to_status_fk"
    FOREIGN KEY ("workflow_version_id", "to_status")
    REFERENCES "workflow"."workflow_statuses" ("workflow_version_id", "status_code");

ALTER TABLE "workflow"."transition_rules"
    ADD CONSTRAINT "transition_rules_version_from_action_unique"
    UNIQUE ("workflow_version_id", "from_status", "trigger_action");


-- ------------------------------------------------------------------------
-- 7. approval_requests
-- ------------------------------------------------------------------------
CREATE INDEX "approval_requests_entity_idx"
    ON "workflow"."approval_requests" ("entity_type", "entity_id");

CREATE INDEX "approval_requests_current_status_idx"
    ON "workflow"."approval_requests" ("current_status");

CREATE INDEX "approval_requests_version_definition_idx"
    ON "workflow"."approval_requests" ("workflow_version_id", "workflow_definition_id");

ALTER TABLE "workflow"."approval_requests"
    ADD CONSTRAINT "approval_requests_version_definition_fk"
    FOREIGN KEY ("workflow_version_id", "workflow_definition_id")
    REFERENCES "workflow"."workflow_versions" ("id", "workflow_definition_id");

ALTER TABLE "workflow"."approval_requests"
    ADD CONSTRAINT "approval_requests_current_status_fk"
    FOREIGN KEY ("workflow_version_id", "current_status")
    REFERENCES "workflow"."workflow_statuses" ("workflow_version_id", "status_code");

-- CAVEAT (unchanged from earlier rounds, still applies): NULLs are
-- distinct in a unique index, so this does not fully prevent
-- duplicate open requests across NULL-organization_id rows until that
-- column is NOT NULL.
-- Item 2 (round 3), NULL-safe open-request uniqueness.
-- The single index below only reliably works once organization_id is
-- NOT NULL. PostgreSQL's default uniqueness semantics treat
-- NULL <> NULL, so while organization_id is NULL platform-wide (the
-- current single-tenant state), two rows with the SAME entity_type/
-- entity_id and organization_id = NULL would NOT violate this index -
-- two concurrent open requests for the same entity could both insert
-- successfully. Split into two indexes so each covers a case where
-- every column in its key is guaranteed non-null:
CREATE UNIQUE INDEX "approval_requests_one_open_per_entity_scoped"
    ON "workflow"."approval_requests" ("organization_id", "entity_type", "entity_id")
    WHERE ("is_open" = true AND "organization_id" IS NOT NULL);

-- NULL-safe variant for the current single-tenant state: organization_id
-- is deliberately excluded from the index key (rather than included
-- and relying on NULL-equality semantics), so there is no NULL value
-- being compared at all - this is a normal, fully-enforcing unique
-- index for every row where organization_id IS NULL.
-- MIGRATION NOTE: once the shared organization migration lands and
-- organization_id becomes NOT NULL platform-wide, this index becomes
-- permanently unreachable (its WHERE clause can never match) and
-- should be dropped in that migration - "_scoped" above is then the
-- sole, final constraint. Until then, both are required together.
CREATE UNIQUE INDEX "approval_requests_one_open_per_entity_null_org"
    ON "workflow"."approval_requests" ("entity_type", "entity_id")
    WHERE ("is_open" = true AND "organization_id" IS NULL);


-- ------------------------------------------------------------------------
-- 8. approval_steps
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."approval_steps"
    ADD CONSTRAINT "approval_steps_request_step_unique"
    UNIQUE ("approval_request_id", "workflow_step_id");

CREATE INDEX "approval_steps_sla_due_at_idx"
    ON "workflow"."approval_steps" ("sla_due_at");

CREATE INDEX "approval_steps_workflow_step_version_idx"
    ON "workflow"."approval_steps" ("workflow_step_id", "workflow_version_id");

ALTER TABLE "workflow"."approval_steps"
    ADD CONSTRAINT "approval_steps_step_version_fk"
    FOREIGN KEY ("workflow_step_id", "workflow_version_id")
    REFERENCES "workflow"."workflow_steps" ("id", "workflow_version_id");

ALTER TABLE "workflow"."approval_steps"
    ADD CONSTRAINT "approval_steps_step_no_positive"
    CHECK ("step_no" > 0);

ALTER TABLE "workflow"."approval_steps"
    ADD CONSTRAINT "approval_steps_min_n_requires_count"
    CHECK (
        ("approval_mode" <> 'MIN_N')
        OR ("required_approvals" IS NOT NULL AND "required_approvals" > 0)
    );

CREATE INDEX "approval_steps_request_id_idx"
    ON "workflow"."approval_steps" ("approval_request_id");

-- Item 2: outcome_action_id FK is added further down (after section 10),
-- since it requires approval_actions_id_step_unique to exist first.


-- ------------------------------------------------------------------------
-- 9. delegations
-- ------------------------------------------------------------------------
CREATE INDEX "delegations_delegate_validity_idx"
    ON "workflow"."delegations" ("delegate_user_id", "valid_from", "valid_to");

CREATE INDEX "delegations_delegator_role_module_idx"
    ON "workflow"."delegations" ("delegator_user_id", "role_id", "module");

ALTER TABLE "workflow"."delegations"
    ADD CONSTRAINT "delegations_delegate_not_delegator"
    CHECK ("delegate_user_id" <> "delegator_user_id");

ALTER TABLE "workflow"."delegations"
    ADD CONSTRAINT "delegations_valid_range"
    CHECK ("valid_to" > "valid_from");

ALTER TABLE "workflow"."delegations"
    ADD CONSTRAINT "delegations_scope_not_empty"
    CHECK (NOT ("role_id" IS NULL AND "module" IS NULL));

ALTER TABLE "workflow"."delegations"
    ADD CONSTRAINT "delegations_no_overlap"
    EXCLUDE USING gist (
        "delegator_user_id" WITH =,
        (COALESCE("role_id", '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
        (COALESCE("module", '')) WITH =,
        tstzrange("valid_from", "valid_to") WITH &&
    ) WHERE ("is_active" = true);


-- ------------------------------------------------------------------------
-- 10. approval_actions
-- Item 7: idempotency uniqueness is scoped to the request, matching
-- what the RPC actually checks and enforces - NOT a global unique
-- constraint on idempotency_key alone.
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."approval_actions"
    ADD CONSTRAINT "approval_actions_request_idempotency_key_unique"
    UNIQUE ("approval_request_id", "idempotency_key");

ALTER TABLE "workflow"."approval_actions"
    ADD CONSTRAINT "approval_actions_actor_consistency"
    CHECK (
        ("actor_type" = 'USER' AND "actor_user_id" IS NOT NULL)
        OR ("actor_type" = 'SYSTEM' AND "actor_user_id" IS NULL)
    );

ALTER TABLE "workflow"."approval_actions"
    ADD CONSTRAINT "approval_actions_id_step_unique"
    UNIQUE ("id", "approval_step_id");

CREATE INDEX "approval_actions_step_id_idx"
    ON "workflow"."approval_actions" ("approval_step_id");
CREATE INDEX "approval_actions_actor_user_id_idx"
    ON "workflow"."approval_actions" ("actor_user_id");
CREATE INDEX "approval_actions_delegation_id_idx"
    ON "workflow"."approval_actions" ("delegation_id");

-- Item 2: outcome_action_id must reference an action belonging to the
-- SAME step, not just any approval_actions row.
ALTER TABLE "workflow"."approval_steps"
    ADD CONSTRAINT "approval_steps_outcome_action_fk"
    FOREIGN KEY ("outcome_action_id", "id")
    REFERENCES "workflow"."approval_actions" ("id", "approval_step_id");


-- ------------------------------------------------------------------------
-- 11. approval_step_assignees
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."approval_step_assignees"
    ADD CONSTRAINT "approval_step_assignees_step_user_unique"
    UNIQUE ("approval_step_id", "assignee_user_id");

CREATE INDEX "approval_step_assignees_assignee_idx"
    ON "workflow"."approval_step_assignees" ("assignee_user_id");


-- ------------------------------------------------------------------------
-- 12. sla_escalations
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."sla_escalations"
    ADD CONSTRAINT "sla_escalations_step_level_unique"
    UNIQUE ("approval_step_id", "escalation_level");

CREATE INDEX "sla_escalations_escalated_at_idx"
    ON "workflow"."sla_escalations" ("escalated_at");
CREATE INDEX "sla_escalations_due_at_idx"
    ON "workflow"."sla_escalations" ("due_at");

ALTER TABLE "workflow"."sla_escalations"
    ADD CONSTRAINT "sla_escalations_level_positive"
    CHECK ("escalation_level" > 0);

ALTER TABLE "workflow"."sla_escalations"
    ADD CONSTRAINT "sla_escalations_exactly_one_target"
    CHECK (num_nonnulls("escalated_to_user_id", "escalated_to_role_id") = 1);


-- ------------------------------------------------------------------------
-- 13. status_history
-- ------------------------------------------------------------------------
CREATE INDEX "status_history_request_id_idx"
    ON "workflow"."status_history" ("approval_request_id");
CREATE INDEX "status_history_step_id_idx"
    ON "workflow"."status_history" ("approval_step_id");

ALTER TABLE "workflow"."status_history"
    ADD CONSTRAINT "status_history_to_status_fk"
    FOREIGN KEY ("workflow_version_id", "to_status")
    REFERENCES "workflow"."workflow_statuses" ("workflow_version_id", "status_code");

ALTER TABLE "workflow"."status_history"
    ADD CONSTRAINT "status_history_from_status_fk"
    FOREIGN KEY ("workflow_version_id", "from_status")
    REFERENCES "workflow"."workflow_statuses" ("workflow_version_id", "status_code");


-- ------------------------------------------------------------------------
-- 14. request_start_idempotency  (NEW - item 7)
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."request_start_idempotency"
    ADD CONSTRAINT "request_start_idempotency_key_unique"
    UNIQUE ("idempotency_key");

CREATE INDEX "request_start_idempotency_request_id_idx"
    ON "workflow"."request_start_idempotency" ("approval_request_id");


-- ------------------------------------------------------------------------
-- 15. Item 6 (round 3): version > 0 for every optimistic-concurrency
-- "version" column. NOT NULL was already enforced (round 2, item 9);
-- this adds the positivity check on top, one per table.
-- ------------------------------------------------------------------------
ALTER TABLE "workflow"."workflow_definitions" ADD CONSTRAINT "workflow_definitions_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."workflow_versions" ADD CONSTRAINT "workflow_versions_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."workflow_statuses" ADD CONSTRAINT "workflow_statuses_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."workflow_steps" ADD CONSTRAINT "workflow_steps_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."workflow_step_assignees" ADD CONSTRAINT "workflow_step_assignees_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."transition_rules" ADD CONSTRAINT "transition_rules_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."approval_requests" ADD CONSTRAINT "approval_requests_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."approval_steps" ADD CONSTRAINT "approval_steps_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."approval_step_assignees" ADD CONSTRAINT "approval_step_assignees_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."delegations" ADD CONSTRAINT "delegations_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."approval_actions" ADD CONSTRAINT "approval_actions_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."sla_escalations" ADD CONSTRAINT "sla_escalations_version_positive" CHECK ("version" > 0);
ALTER TABLE "workflow"."status_history" ADD CONSTRAINT "status_history_version_positive" CHECK ("version" > 0);


-- ========================================================================
-- END 003_workflow_constraints_indexes.sql
-- ========================================================================
