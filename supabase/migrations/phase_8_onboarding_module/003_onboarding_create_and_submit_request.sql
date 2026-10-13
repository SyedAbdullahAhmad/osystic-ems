-- ========================================================================
-- 003_onboarding_create_and_submit_request.sql  (v2 - corrected per
-- Arslan's review)
-- HR-initiated, same asymmetry as hr.create_contract() - the actor
-- (v_actor, an ONBOARDING_MANAGE holder) is never the candidate.
--
-- V1 SIMPLIFICATION, flagged explicitly: this RPC always creates a
-- brand NEW core.people row - it does not attempt to match/reuse an
-- existing person by email (e.g. a former employee being re-onboarded,
-- or a candidate already entered by someone else). That kind of
-- matching is deliberately scoped OUT of v1 - see item 11's correction
-- in ONBOARDING_MODULE_PROPOSAL_v2.md: rehire is explicitly out of
-- scope for v1, not silently implied as supported.
--
-- Creates the record directly at SUBMITTED, not DRAFT - DRAFT remains a
-- valid enum value (reachable by a future "save as draft" UI feature,
-- not built here) but this RPC's only job is create-and-submit
-- together, matching hr.create_contract()'s own create-and-submit
-- pattern exactly.
--
-- CHANGES IN THIS REVISION (item 2, round 5):
-- The idempotency check below is now race-free under concurrent
-- requests with the SAME key - a transaction-scoped advisory lock
-- (pg_advisory_xact_lock) serializes them before the lookup, so a
-- genuine concurrent duplicate now correctly waits and then returns the
-- original result, rather than racing into person/record creation and
-- the loser hitting a raw unique-violation. See the lock acquisition
-- itself, below, for the full explanation.
--
-- CHANGES FROM ROUND 1 (item 5):
-- p_idempotency_key is now REQUIRED (was optional with a post-hoc
-- fallback generated from v_record_id - which is useless as an
-- idempotency guard since v_record_id doesn't exist yet on a retry
-- that's meant to avoid creating it again). The client-supplied key is
-- now checked against onboarding.request_idempotency BEFORE either
-- core.people or onboarding_records is touched. A matching key +
-- matching payload hash short-circuits to the ORIGINAL result with no
-- new writes at all. A matching key + DIFFERENT payload hash is a
-- hard error (ONBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH) - the same
-- key must not silently get reused for a different candidate.
-- ========================================================================

CREATE OR REPLACE FUNCTION "onboarding"."create_and_submit_onboarding_request"(
    "p_full_name" varchar(255),
    "p_email" varchar(255),
    "p_idempotency_key" varchar(255),
    "p_position_title" varchar(255) DEFAULT NULL,
    "p_department_id" uuid DEFAULT NULL,
    "p_proposed_start_date" date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "onboarding", "workflow", "core", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_organization_id uuid;
    v_person_id uuid;
    v_record_id uuid;
    v_workflow_definition_id uuid;
    v_start_result jsonb;
    v_normalized_email varchar(255);
    v_payload_hash text;
    v_existing "onboarding"."request_idempotency";
    v_workflow_status text;
    v_existing_record "onboarding"."onboarding_records";
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_UNAUTHENTICATED: create_and_submit_onboarding_request requires an authenticated session';
    END IF;
    IF NOT core.has_permission(v_actor, 'ONBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'ONBOARDING_NOT_AUTHORIZED: ONBOARDING_MANAGE required to create an onboarding request';
    END IF;

    IF p_full_name IS NULL OR btrim(p_full_name) = '' THEN
        RAISE EXCEPTION 'ONBOARDING_FULL_NAME_REQUIRED: a full_name is required for a candidate';
    END IF;
    IF p_email IS NULL OR btrim(p_email) = '' THEN
        RAISE EXCEPTION 'ONBOARDING_EMAIL_REQUIRED: an email is required for a candidate (this is the field provisioning will later match against)';
    END IF;
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
        RAISE EXCEPTION 'ONBOARDING_IDEMPOTENCY_KEY_REQUIRED: a client-generated idempotency_key is required (same key on retry; a different key per distinct candidate submission)';
    END IF;

    v_normalized_email := lower(btrim(p_email));

    -- Item 5: the payload hash covers exactly the fields Arslan listed -
    -- actor, full name, normalized email, position, department, start
    -- date - so "same key, same payload" vs "same key, different
    -- payload" is a real comparison, not just trusting the key alone.
    -- Item 8 (round 2): pgcrypto's digest() is called schema-qualified
    -- (extensions.digest) rather than relying on this function's pinned
    -- search_path to happen to include wherever pgcrypto landed. In a
    -- Supabase-managed project, pgcrypto installs into the "extensions"
    -- schema, not "public" - confirm this with
    -- `SELECT extname, nspname FROM pg_extension e JOIN pg_namespace n
    -- ON n.oid = e.extnamespace WHERE extname = 'pgcrypto';` before
    -- applying this file (also added to the checklist's prerequisites).
    -- If it's installed somewhere else in your project, change the
    -- schema qualifier below to match - do not remove the qualifier and
    -- fall back to depending on search_path.
    v_payload_hash := encode(
        "extensions"."digest"(
            concat_ws(
                '|',
                v_actor::text,
                btrim(p_full_name),
                v_normalized_email,
                COALESCE(btrim(p_position_title), ''),
                COALESCE(p_department_id::text, ''),
                COALESCE(p_proposed_start_date::text, '')
            ),
            'sha256'
        ),
        'hex'
    );

    -- Item 2 (round 5): serialize concurrent calls with the SAME
    -- idempotency key before the lookup below. Without this, two
    -- requests racing with the same key can both pass the
    -- check-then-write sequence (neither sees the other's row yet),
    -- both proceed into core.people/onboarding_records creation, and
    -- the loser hits a unique-violation on request_idempotency's own
    -- PRIMARY KEY (or core.people's email uniqueness) instead of
    -- getting back the original idempotent result - exactly the
    -- "swallow the unique_violation after side effects already
    -- started" anti-pattern Arslan explicitly said not to use.
    --
    -- pg_advisory_xact_lock is TRANSACTION-scoped: it blocks a second
    -- caller with the same key until the first caller's transaction
    -- actually commits (or rolls back) - not just until this statement
    -- finishes - and releases automatically, no matching unlock call
    -- needed. hashtext() is used (not p_idempotency_key itself) because
    -- the advisory-lock functions take an integer key, not text; the
    -- 32-bit hash is more than sufficient here since collisions only
    -- cause unrelated keys to serialize against each other
    -- (unnecessary blocking), never an incorrect idempotency result -
    -- the actual key comparison below is still the real, exact text
    -- match. No existing function in this project used advisory locks
    -- before this - introduced here specifically because the
    -- idempotency ledger's check-then-write sequence is what needs it;
    -- workflow.start_approval_request's own equivalent check accepts
    -- this same race as a standing, documented project convention (see
    -- its own idempotency check) and that is unchanged here - this
    -- lock only serializes THIS function's pre-person-creation check.
    PERFORM pg_advisory_xact_lock(hashtext(p_idempotency_key)::bigint);

    -- Item 5 (round 1): idempotency check happens BEFORE any
    -- core.people or onboarding_records write - a confirmed-duplicate
    -- retry never reaches either INSERT. Now race-free (see above): by
    -- the time this SELECT runs, any concurrent caller with the SAME
    -- key has either not started yet (will block above until this
    -- transaction commits) or has already committed (so this SELECT
    -- sees its row).
    SELECT * INTO v_existing FROM "onboarding"."request_idempotency" WHERE "idempotency_key" = p_idempotency_key;

    -- Round 7: test a non-null key column, not the whole record (a record
    -- "IS NOT NULL" is only TRUE when every column is non-null).
    IF v_existing."idempotency_key" IS NOT NULL THEN
        IF v_existing."payload_hash" <> v_payload_hash THEN
            RAISE EXCEPTION 'ONBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH: idempotency_key % was already used for a different request payload', p_idempotency_key;
        END IF;

        -- Same key, same payload: this is a genuine retry. Return the
        -- original result, re-derived from the original record - no
        -- new core.people/onboarding_records/workflow request is created.
        SELECT * INTO v_existing_record FROM "onboarding"."onboarding_records" WHERE "id" = v_existing."onboarding_record_id";
        IF v_existing_record IS NULL THEN
            -- Should be unreachable (FK + same transaction that wrote
            -- both rows together below) - a clear error beats a silent
            -- NULL if it ever somehow happens.
            RAISE EXCEPTION 'ONBOARDING_IDEMPOTENCY_RECORD_MISSING: idempotency_key % has no matching onboarding_record (data inconsistency)', p_idempotency_key;
        END IF;

        -- Item 5 (round 3): 'status' was overloaded - the fresh-create
        -- path below returned the WORKFLOW status (e.g. PENDING) while
        -- this replay path returned the ONBOARDING business status
        -- (e.g. SUBMITTED) under the same key, for the same resource.
        -- Both domains are now returned explicitly and consistently on
        -- every path through this function.
        SELECT "current_status" INTO v_workflow_status
        FROM "workflow"."approval_requests" WHERE "id" = v_existing_record."workflow_request_id";

        RETURN jsonb_build_object(
            'onboarding_record_id', v_existing_record."id",
            'person_id', v_existing_record."person_id",
            'workflow_request_id', v_existing_record."workflow_request_id",
            'onboarding_status', v_existing_record."status",
            'workflow_status', v_workflow_status,
            'idempotent_replay', true
        );
    END IF;

    SELECT "id" INTO v_organization_id FROM "core"."organizations" WHERE "code" = 'OSYSTIC';
    IF v_organization_id IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_OSYSTIC_ORG_MISSING: seeded OSYSTIC organization row not found';
    END IF;

    -- New core.people row, person_type = CANDIDATE. Duplicate email
    -- against an existing person raises naturally via the partial
    -- unique index - see header re: rehire being out of scope for v1.
    INSERT INTO "core"."people" ("organization_id", "full_name", "primary_email", "person_type", "status")
    VALUES (v_organization_id, p_full_name, p_email, 'CANDIDATE', 'ACTIVE')
    RETURNING "id" INTO v_person_id;

    INSERT INTO "onboarding"."onboarding_records" (
        "person_id", "position_title", "department_id", "proposed_start_date", "status", "submitted_at"
    ) VALUES (
        v_person_id, p_position_title, p_department_id, p_proposed_start_date, 'SUBMITTED', now()
    ) RETURNING "id" INTO v_record_id;

    -- Claim the idempotency key now, right after the two creates and
    -- before the workflow call. With the advisory lock acquired above
    -- held for the rest of this transaction, no concurrent caller with
    -- the SAME key can reach this INSERT (or the SELECT above) until
    -- this transaction commits or rolls back - so this is no longer a
    -- race window at all, just the normal claim-the-key step of an
    -- already-serialized sequence (item 2, round 5).
    INSERT INTO "onboarding"."request_idempotency" ("idempotency_key", "onboarding_record_id", "payload_hash", "created_by")
    VALUES (p_idempotency_key, v_record_id, v_payload_hash, v_actor);

    -- Item 9 (round 2): resolved scoped to the SAME organization_id
    -- just used for core.people above, not just by module/code alone -
    -- 004 now seeds ONBOARDING_OFFER_APPROVAL bound to OSYSTIC's
    -- organization_id, so this lookup stays consistent with that
    -- binding rather than matching on code alone (which would still
    -- accidentally match a future second org's differently-scoped
    -- definition of the same code, if one is ever seeded).
    --
    -- HONEST LIMITATION, not worked around here: the workflow engine's
    -- own start_approval_request() (phase_2) hardcodes
    -- approval_requests.organization_id = NULL unconditionally - the
    -- p_organization_id parameter was deliberately REMOVED from that
    -- function in an earlier round ("Internally NULL, matching the
    -- single-tenant convention used throughout this schema until the
    -- shared org migration lands" - see that function's own header
    -- comment). So while the DEFINITION itself is now correctly
    -- organization-scoped, the resulting approval_requests ROW still
    -- will not carry an organization_id, regardless of anything this
    -- file does - that's shared, system-wide engine behavior affecting
    -- every module equally, not something onboarding's own migrations
    -- can or should silently work around. Changing it means changing
    -- workflow.start_approval_request() itself and re-testing every
    -- other module that calls it (Leave/Attendance/Assets/Contracts) -
    -- flagged as a separate, explicit, shared-engine decision, not
    -- bundled into this module's fix.
    SELECT "id" INTO v_workflow_definition_id
    FROM "workflow"."workflow_definitions"
    WHERE "module" = 'onboarding' AND "code" = 'ONBOARDING_OFFER_APPROVAL'
      AND "organization_id" IS NOT DISTINCT FROM v_organization_id;

    IF v_workflow_definition_id IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_WORKFLOW_NOT_CONFIGURED: no ACTIVE ONBOARDING_OFFER_APPROVAL workflow_definition found for organization % - run 004''s seed function first', v_organization_id;
    END IF;

    v_start_result := "workflow"."start_approval_request"(
        v_workflow_definition_id,
        'onboarding_record',
        v_record_id,
        jsonb_build_object(
            'person_id', v_person_id,
            'position_title', p_position_title,
            'department_id', p_department_id,
            'proposed_start_date', p_proposed_start_date
        ),
        p_idempotency_key
    );

    UPDATE "onboarding"."onboarding_records"
    SET "workflow_request_id" = (v_start_result->>'approval_request_id')::uuid
    WHERE "id" = v_record_id;

    -- Round 7 (execution finding): the engine's start result reports its
    -- own label ('CREATED'), while the replay path returns the request's
    -- real current_status ('PENDING'). Read the same source on BOTH paths
    -- so workflow_status means one thing.
    SELECT "current_status" INTO v_workflow_status
    FROM "workflow"."approval_requests"
    WHERE "id" = (v_start_result->>'approval_request_id')::uuid;

    RETURN jsonb_build_object(
        'onboarding_record_id', v_record_id,
        'person_id', v_person_id,
        'workflow_request_id', v_start_result->>'approval_request_id',
        -- Item 5 (round 3): onboarding_status is known statically here -
        -- this function always creates the record at 'SUBMITTED' (see
        -- the INSERT above) - rather than re-querying it. workflow_status
        -- is whatever the engine's start_approval_request() reports
        -- (normally PENDING). Two distinct, clearly-named fields, never
        -- one overloaded 'status'.
        'onboarding_status', 'SUBMITTED',
        'workflow_status', v_workflow_status,
        'idempotent_replay', false
    );
END;
$$;

REVOKE ALL ON FUNCTION "onboarding"."create_and_submit_onboarding_request"(varchar, varchar, varchar, varchar, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "onboarding"."create_and_submit_onboarding_request"(varchar, varchar, varchar, varchar, uuid, date) TO "authenticated";

-- ------------------------------------------------------------------------
-- Workflow status change reaction - same pattern as every other
-- module's _on_workflow_status_change trigger. Only moves
-- onboarding_records.status between SUBMITTED/APPROVED/REJECTED - HIRED
-- is never reachable from here (see 001/002/006 - only
-- confirm_employee_hire() can set it), and CANCELLED (007's withdraw
-- path) is deliberately not handled here either - withdraw_onboarding_
-- request() sets onboarding_records.status = 'WITHDRAWN' itself,
-- directly, in the same transaction as the workflow cancel, rather than
-- relying on this trigger to react to it asynchronously.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "onboarding"."_on_workflow_status_change"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "onboarding", "workflow"
AS $$
DECLARE
    v_record "onboarding"."onboarding_records";
BEGIN
    IF NEW."to_status" NOT IN ('APPROVED', 'REJECTED') THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_record FROM "onboarding"."onboarding_records" WHERE "workflow_request_id" = NEW."approval_request_id";
    IF v_record IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW."to_status" = 'APPROVED' THEN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'APPROVED' WHERE "id" = v_record."id";
    ELSIF NEW."to_status" = 'REJECTED' THEN
        UPDATE "onboarding"."onboarding_records" SET "status" = 'REJECTED' WHERE "id" = v_record."id";
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_onboarding_on_workflow_status_change" ON "workflow"."status_history";
CREATE TRIGGER "trg_onboarding_on_workflow_status_change"
    AFTER INSERT ON "workflow"."status_history"
    FOR EACH ROW EXECUTE FUNCTION "onboarding"."_on_workflow_status_change"();

-- ========================================================================
-- END 003_onboarding_create_and_submit_request.sql
-- ========================================================================
