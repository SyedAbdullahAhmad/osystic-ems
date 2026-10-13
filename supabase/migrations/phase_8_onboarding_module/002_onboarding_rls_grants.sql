-- ========================================================================
-- 002_onboarding_rls_grants.sql  (v3 - corrected per Arslan's round-2
-- review, item 1 - THE most important fix in this round)
--
-- CHANGE IN THIS REVISION:
--   v2 granted "authenticated" both INSERT and UPDATE on
--   onboarding_records, gated only by an RLS policy requiring
--   ONBOARDING_MANAGE (and, for UPDATE, excluding HIRED/WITHDRAWN).
--   Arslan's review correctly identified that this still let an
--   ONBOARDING_MANAGE holder bypass the entire RPC/workflow path
--   outright - e.g. INSERT a row directly at status='APPROVED', or
--   raw-UPDATE SUBMITTED -> APPROVED/REJECTED - since all of those are
--   legal VALUE transitions under 001's state-transition trigger, which
--   only validates that the transition is a structurally legal move,
--   not that it happened through the correct controlled path.
--
--   FIX: "authenticated" now gets SELECT ONLY on onboarding_records.
--   There is no INSERT or UPDATE RLS policy left at all - not "a
--   stricter one", NONE. Every write to this table happens exclusively
--   through SECURITY DEFINER functions:
--     - INSERT (DRAFT/SUBMITTED)    -> create_and_submit_onboarding_request() (003)
--     - UPDATE to APPROVED/REJECTED -> _on_workflow_status_change() (003), reacting to the workflow engine
--     - UPDATE to HIRED             -> confirm_employee_hire() (006)
--     - UPDATE to WITHDRAWN         -> withdraw_onboarding_request() (007)
--   None of these four need a table-level GRANT to "authenticated" or
--   an RLS policy to do their writes - a SECURITY DEFINER function's
--   privilege checks resolve against its OWNER, not its caller, and the
--   owner (same role that ran every migration in this project) already
--   has full privileges on its own tables, bypassing RLS entirely by
--   design. This is not a new assumption - it's the exact same
--   principle 006/007 already relied on for HIRED/WITHDRAWN
--   specifically; this revision just extends it to the entire table
--   rather than two status values.
--
--   This also resolves item 2 (REJECTED should not remain freely
--   editable) as a direct consequence, not a separate fix: with no
--   RLS-governed UPDATE path left at all, REJECTED (and SUBMITTED, and
--   APPROVED, and every other status) is equally immutable from the
--   ordinary authenticated path - terminal history across the board is
--   now audit-stable, not just HIRED/WITHDRAWN.
--
--   If editable candidate fields are needed later (e.g. HR correcting
--   a typo in position_title while still SUBMITTED), that needs a
--   dedicated, purpose-built RPC that validates exactly what may change
--   and when - not a restoration of general row UPDATE. Not built here;
--   flagged for a future, explicit ask if/when it's actually needed.
-- ========================================================================

GRANT USAGE ON SCHEMA "onboarding" TO "authenticated";

-- Item 1 FIX: SELECT only. No INSERT, no UPDATE, no DELETE for
-- "authenticated" on onboarding_records, at the base table-grant level -
-- the first and more fundamental of the two layers (base grant, then
-- RLS policy) that must both allow a write for it to succeed.
GRANT SELECT ON "onboarding"."onboarding_records" TO "authenticated";

-- Item 4 (round 3): request_idempotency gets NO grant to "authenticated"
-- at all anymore - not even SELECT/INSERT. Round 2's comments already
-- said no client is supposed to read or write this table directly and
-- that the SECURITY DEFINER create RPC owns the whole path - but the
-- grant was still sitting there unused, relying on RLS (no ordinary-
-- user policy existed) as the only thing actually stopping direct
-- access. Removing the base grant entirely makes that defense-in-depth
-- rather than RLS being the sole backstop: even if a future policy were
-- accidentally added to this table, there would still be no base
-- privilege for "authenticated" to exploit it with. The RPC's own
-- SECURITY DEFINER writes are completely unaffected (see the owner-
-- privilege-resolution principle explained throughout this file).

ALTER TABLE "onboarding"."onboarding_records" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "onboarding"."request_idempotency" ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION "onboarding"."_force_created_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "onboarding"
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_CREATED_BY_REQUIRES_AUTHENTICATED_SESSION: % requires an authenticated session', TG_TABLE_NAME;
    END IF;
    NEW."created_by" := auth.uid();
    RETURN NEW;
END;
$$;

-- Increments "version" on every real UPDATE (item 7 from round 1),
-- unchanged from v2.
CREATE OR REPLACE FUNCTION "onboarding"."_force_updated_by"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "onboarding"
AS $$
BEGIN
    NEW."updated_by" := auth.uid();
    NEW."updated_at" := now();
    NEW."version" := OLD."version" + 1;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_onboarding_records_created_by" ON "onboarding"."onboarding_records";
CREATE TRIGGER "trg_onboarding_records_created_by" BEFORE INSERT ON "onboarding"."onboarding_records"
    FOR EACH ROW EXECUTE FUNCTION "onboarding"."_force_created_by"();
DROP TRIGGER IF EXISTS "trg_onboarding_records_updated_by" ON "onboarding"."onboarding_records";
CREATE TRIGGER "trg_onboarding_records_updated_by" BEFORE UPDATE ON "onboarding"."onboarding_records"
    FOR EACH ROW EXECUTE FUNCTION "onboarding"."_force_updated_by"();

-- ------------------------------------------------------------------------
-- RLS policies - onboarding.onboarding_records
-- SELECT ONLY. No INSERT/UPDATE policy exists in this file at all (see
-- header) - every write path is a SECURITY DEFINER RPC that bypasses
-- RLS by construction, not a table permission someone could widen by
-- adding a policy later without also noticing there's no base GRANT to
-- support it.
-- ------------------------------------------------------------------------

CREATE POLICY "onboarding_records_select" ON "onboarding"."onboarding_records"
    FOR SELECT USING (
        core.has_permission(auth.uid(), 'ONBOARDING_MANAGE')
        OR core.has_permission(auth.uid(), 'ONBOARDING_VIEW_ALL')
        OR "person_id" IN (
            SELECT "person_id" FROM "core"."person_user_links"
            WHERE "user_id" = auth.uid() AND "status" = 'ACTIVE'
        )
    );

-- ------------------------------------------------------------------------
-- RLS policies - onboarding.request_idempotency
-- No ordinary-user SELECT/INSERT policy at all, unchanged from v2: this
-- table is read and written exclusively by
-- create_and_submit_onboarding_request() (003), a SECURITY DEFINER
-- function that bypasses RLS entirely.
-- ------------------------------------------------------------------------

-- ========================================================================
-- END 002_onboarding_rls_grants.sql
-- ========================================================================
