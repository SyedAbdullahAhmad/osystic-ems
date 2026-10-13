-- ========================================================================
-- 001_onboarding_schema.sql  (v2 - corrected per Arslan's review)
-- Onboarding module - schema per ONBOARDING_MODULE_PROPOSAL_v2.md,
-- all 4 decisions and the state-transition rules (v2 S6.2) confirmed
-- by Arslan before this file was written.
--
-- CHANGES IN THIS REVISION, mapped to Arslan's numbered review:
--   - Item 7: "version" now has CHECK (version > 0). The increment-on-
--     update behavior itself is fixed in 002's _force_updated_by().
--   - Item 8: new unique partial index on workflow_request_id - one
--     workflow approval request can never be linked to more than one
--     onboarding record.
--   - Item 2: three new columns (withdrawn_at/withdrawn_by/
--     withdrawal_reason) to actually record reason/actor/timestamp for
--     a withdrawal, consumed by 007's withdraw_onboarding_request().
--   - Item 5: new onboarding.request_idempotency table - the
--     onboarding-level (pre-person-creation) idempotency ledger
--     consumed by 003's create_and_submit_onboarding_request().
-- ========================================================================

CREATE SCHEMA IF NOT EXISTS "onboarding";

CREATE TYPE "onboarding"."onboarding_status" AS ENUM (
    'DRAFT', 'SUBMITTED', 'APPROVED', 'REJECTED', 'WITHDRAWN', 'HIRED'
);

-- ------------------------------------------------------------------------
-- onboarding.onboarding_records - references core.people.id directly
-- (not hr.employees.id) - the person isn't an employee yet, per v2 S2.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "onboarding"."onboarding_records" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "person_id" uuid NOT NULL REFERENCES "core"."people"("id"),
    "position_title" varchar(255),
    "department_id" uuid REFERENCES "core"."departments"("id"),
    "proposed_start_date" date,
    "status" "onboarding"."onboarding_status" NOT NULL DEFAULT 'DRAFT',
    "workflow_request_id" uuid REFERENCES "workflow"."approval_requests"("id"),
    "submitted_at" timestamptz,
    "hired_at" timestamptz,
    "hired_by" uuid REFERENCES "auth"."users"("id"),
    -- Item 2: withdrawal audit trail - populated only by
    -- withdraw_onboarding_request() (007), never by a raw UPDATE.
    "withdrawn_at" timestamptz,
    "withdrawn_by" uuid REFERENCES "auth"."users"("id"),
    "withdrawal_reason" text,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    -- Item 7: must actually increment on every real update (002's
    -- _force_updated_by) to serve as a concurrency/audit version.
    "version" int NOT NULL DEFAULT 1 CHECK ("version" > 0)
);

-- At most one non-terminal onboarding attempt per person at a time
-- (proposed in v2 S6.1, flagged as an addition rather than assumed) -
-- doesn't restrict history: a person can have multiple REJECTED/
-- WITHDRAWN/HIRED records over time (e.g. a rehire - see 011's doc
-- correction in ONBOARDING_MODULE_PROPOSAL_v2.md re: item 11; the
-- index below does not by itself imply rehire is supported end-to-end).
CREATE UNIQUE INDEX IF NOT EXISTS "idx_onboarding_records_one_open_per_person"
    ON "onboarding"."onboarding_records"("person_id")
    WHERE "status" IN ('DRAFT', 'SUBMITTED', 'APPROVED');

-- Item 8: one workflow_request_id can back at most one onboarding
-- record. NULL is allowed (a record briefly has no workflow_request_id
-- between its own INSERT and the follow-up UPDATE in 003 that attaches
-- one), so this is a partial index, same pattern as the one above.
CREATE UNIQUE INDEX IF NOT EXISTS "idx_onboarding_records_workflow_request_unique"
    ON "onboarding"."onboarding_records"("workflow_request_id")
    WHERE "workflow_request_id" IS NOT NULL;

CREATE INDEX IF NOT EXISTS "idx_onboarding_records_person" ON "onboarding"."onboarding_records"("person_id");
CREATE INDEX IF NOT EXISTS "idx_onboarding_records_status" ON "onboarding"."onboarding_records"("status");
CREATE INDEX IF NOT EXISTS "idx_onboarding_records_department" ON "onboarding"."onboarding_records"("department_id");

-- ------------------------------------------------------------------------
-- Item 5: onboarding-level idempotency ledger. Deliberately a SEPARATE
-- table from workflow.request_start_idempotency - that one only comes
-- into play once workflow.start_approval_request() is reached, which
-- in the original package was AFTER core.people and onboarding_records
-- were already created. This table's row is checked and written BEFORE
-- either of those inserts happen (003), so a client retry never
-- produces a second core.people row - it genuinely cannot reach the
-- person/record creation step at all on a confirmed-duplicate key.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "onboarding"."request_idempotency" (
    "idempotency_key" varchar(255) NOT NULL PRIMARY KEY,
    "onboarding_record_id" uuid REFERENCES "onboarding"."onboarding_records"("id"),
    "payload_hash" text NOT NULL,
    "created_by" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "created_at" timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------------------
-- State-transition enforcement (v2 S6.2) - database-level, not just
-- convention. Fires on every UPDATE; a no-op status (unchanged) always
-- passes without restriction, so other columns can still be edited
-- freely. HIRED/REJECTED/WITHDRAWN are terminal - nothing may transition
-- OUT of them, which is exactly what structurally prevents "a withdrawn
-- record that already converted the person" (HIRED can never become
-- WITHDRAWN, and vice versa is equally impossible since WITHDRAWN is
-- terminal too).
--
-- NOTE: this trigger only validates that the STATUS VALUE transition
-- itself is legal. It does NOT by itself guarantee the cross-table
-- consistency (hr.employees / core.people.person_type) required for a
-- transition TO 'HIRED' specifically - that's enforced separately by
-- (a) restricting HIRED-writes to the confirm_employee_hire() RPC only,
-- via RLS (see 002's onboarding_records_update policy), and (b) the
-- dedicated AFTER-trigger consistency guard added in 006 (item 3),
-- which checks the cross-table state itself rather than just who
-- wrote it - defense in depth, not just "only one RPC can do this."
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "onboarding"."_enforce_status_transition"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "onboarding"
AS $$
BEGIN
    IF NEW."status" = OLD."status" THEN
        RETURN NEW;
    END IF;

    IF OLD."status" IN ('HIRED', 'REJECTED', 'WITHDRAWN') THEN
        RAISE EXCEPTION 'ONBOARDING_TERMINAL_STATUS: cannot transition out of terminal status % (record %)', OLD."status", OLD."id";
    END IF;

    IF NOT (
        (OLD."status" = 'DRAFT' AND NEW."status" = 'SUBMITTED')
        OR (OLD."status" = 'SUBMITTED' AND NEW."status" IN ('APPROVED', 'REJECTED', 'WITHDRAWN'))
        OR (OLD."status" = 'APPROVED' AND NEW."status" IN ('WITHDRAWN', 'HIRED'))
    ) THEN
        RAISE EXCEPTION 'ONBOARDING_INVALID_TRANSITION: % -> % is not an allowed transition (record %)', OLD."status", NEW."status", OLD."id";
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_onboarding_records_status_transition" ON "onboarding"."onboarding_records";
CREATE TRIGGER "trg_onboarding_records_status_transition"
    BEFORE UPDATE ON "onboarding"."onboarding_records"
    FOR EACH ROW EXECUTE FUNCTION "onboarding"."_enforce_status_transition"();

-- ========================================================================
-- END 001_onboarding_schema.sql
-- ========================================================================
