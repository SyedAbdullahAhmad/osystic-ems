-- ========================================================================
-- 006_confirm_employee_hire.sql  (v2 - corrected per Arslan's review)
-- The ONLY code path permitted to: (a) set core.people.person_type =
-- 'EMPLOYEE', (b) create the corresponding hr.employees row, and
-- (c) set onboarding_records.status = 'HIRED'. All three happen in
-- this one function call - one transaction, so either all three
-- succeed together or none of them do.
--
-- Confirmed by Arslan (v2 S6, decision #1): CANDIDATE -> EMPLOYEE is a
-- separate, explicit HR action - never automatic on approval or on
-- first login. This function IS that separate action.
--
-- OPEN IMPLEMENTATION DETAIL from v2 S6.2, resolved here as SOFT (not a
-- hard block): does NOT require the candidate to already have an
-- ACTIVE core.person_user_links row before HR can confirm the hire -
-- the response payload reports whether they're linked yet
-- (employee_linked), but doesn't block on it either way. Explicitly
-- re-confirmed by Arslan in his review of this package - see the cover
-- note.
--
-- CHANGES IN THIS REVISION:
--   - Item 6 (round 3): retry-safety from round 1 is now also
--     conflict-checked, not just presence-checked - a retry that
--     supplies a DIFFERENT non-null employee_number or hire_date than
--     what was actually recorded the first time raises
--     ONBOARDING_HIRE_REPLAY_PAYLOAD_MISMATCH rather than silently
--     returning the original (different) result as if it were a clean
--     replay.
--   - Item 6 (round 1): retry-safe. A first call sets HIRED; if the client
--     then times out and retries with the SAME onboarding_record_id,
--     the old code failed outright because the record was no longer
--     APPROVED. Now: if the record is already HIRED AND the cross-table
--     state is actually consistent (person_type = EMPLOYEE, matching
--     hr.employees row exists), the original successful result is
--     returned as-is - no new writes, no error. If it's HIRED but the
--     cross-table state is NOT consistent (shouldn't be reachable at
--     all given the guard trigger below, but checked explicitly rather
--     than assumed), a clear ONBOARDING_HIRED_STATE_INCONSISTENT error
--     is raised instead of silently returning a wrong/stale result.
--   - Item 3 (the second half - the database-level guard, not just the
--     "which RPC can write this" access-control half which RLS in 002
--     already handles): a new AFTER trigger on onboarding_records,
--     "_enforce_hired_consistency", independently verifies - every
--     single time a row's status becomes 'HIRED', from ANY code path,
--     not just this one - that the matching person really is EMPLOYEE
--     and the matching hr.employees row really exists. This function
--     (confirm_employee_hire) satisfies that guard by construction
--     because of write order below (people/hr.employees writes happen
--     BEFORE the onboarding_records write that flips status to HIRED,
--     all three in the same transaction), so this trigger is not
--     expected to ever actually fire against THIS function - it exists
--     as a structural backstop against any OTHER present or future
--     write path (direct UPDATE, a different RPC, a manual fix script)
--     that might try to set status = 'HIRED' without doing the other
--     two writes correctly.
-- ========================================================================

CREATE OR REPLACE FUNCTION "onboarding"."confirm_employee_hire"(
    "p_onboarding_record_id" uuid,
    "p_employee_number" varchar(50) DEFAULT NULL,
    "p_hire_date" date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "onboarding", "core", "hr", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_record "onboarding"."onboarding_records";
    v_person "core"."people";
    v_existing_employee "hr"."employees";
    v_new_hr_employee_id uuid;
    v_employee_linked boolean;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_UNAUTHENTICATED: confirm_employee_hire requires an authenticated session';
    END IF;
    IF NOT core.has_permission(v_actor, 'ONBOARDING_MANAGE') THEN
        RAISE EXCEPTION 'ONBOARDING_NOT_AUTHORIZED: ONBOARDING_MANAGE required to confirm a hire';
    END IF;

    SELECT * INTO v_record FROM "onboarding"."onboarding_records" WHERE "id" = p_onboarding_record_id FOR UPDATE;
    IF v_record IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_RECORD_NOT_FOUND: no such onboarding record';
    END IF;

    -- Item 6 FIX: retry-safety. Checked BEFORE the "must be APPROVED"
    -- check below, since on a genuine retry the record is correctly no
    -- longer APPROVED (it's already HIRED) - that's expected, not an
    -- error condition.
    -- EXECUTION FINDING (round 7): a composite/record variable "IS NOT
    -- NULL" is TRUE only when EVERY column is non-null. hr.employees has
    -- nullable columns (e.g. employee_number), so the old
    -- "v_existing_employee IS NOT NULL" was FALSE for a row that
    -- genuinely exists, wrongly raising HIRED_STATE_INCONSISTENT on
    -- every idempotent replay. Test a non-null key column instead.
    IF v_record."status" = 'HIRED' THEN
        SELECT * INTO v_person FROM "core"."people" WHERE "id" = v_record."person_id";
        SELECT * INTO v_existing_employee FROM "hr"."employees" WHERE "person_id" = v_record."person_id";

        IF v_person."person_type" = 'EMPLOYEE' AND v_existing_employee."id" IS NOT NULL THEN
            -- Item 6 (round 3): a retry is only a clean idempotent
            -- replay if it AGREES with what was actually recorded the
            -- first time. A caller that supplies a non-null
            -- p_employee_number or p_hire_date that CONFLICTS with the
            -- existing hr.employees row is not retrying the same
            -- request - it's a different, conflicting instruction
            -- arriving after the fact, and silently returning the
            -- original success would hide that mismatch entirely. A
            -- caller that omits these parameters (passes NULL,
            -- the default) is treated as "don't care, just confirm" and
            -- always passes.
            -- Item 3 (round 4): NULL-safe. Plain "!=" against a NULL
            -- original value evaluates to UNKNOWN in SQL, not true - so
            -- a first hire recorded with employee_number = NULL,
            -- followed by a retry supplying a non-null value, would
            -- have silently passed the old check (UNKNOWN is not TRUE,
            -- so the IF body never ran) and returned the ORIGINAL
            -- (NULL) result as a false "clean" replay, hiding the
            -- conflict entirely. IS DISTINCT FROM treats NULL as a
            -- real, comparable value (NULL IS DISTINCT FROM 'X' is
            -- TRUE), so this case is now caught correctly.
            IF p_employee_number IS NOT NULL AND p_employee_number IS DISTINCT FROM v_existing_employee."employee_number" THEN
                RAISE EXCEPTION 'ONBOARDING_HIRE_REPLAY_PAYLOAD_MISMATCH: retry supplied employee_number % but record % was already hired with employee_number % - these must match, or omit employee_number on retry',
                    p_employee_number, p_onboarding_record_id, v_existing_employee."employee_number";
            END IF;
            IF p_hire_date IS NOT NULL AND p_hire_date IS DISTINCT FROM v_existing_employee."hire_date" THEN
                RAISE EXCEPTION 'ONBOARDING_HIRE_REPLAY_PAYLOAD_MISMATCH: retry supplied hire_date % but record % was already hired with hire_date % - these must match, or omit hire_date on retry',
                    p_hire_date, p_onboarding_record_id, v_existing_employee."hire_date";
            END IF;

            SELECT EXISTS (
                SELECT 1 FROM "core"."person_user_links"
                WHERE "person_id" = v_person."id" AND "status" = 'ACTIVE'
            ) INTO v_employee_linked;

            RETURN jsonb_build_object(
                'onboarding_record_id', p_onboarding_record_id,
                'person_id', v_person."id",
                'hr_employee_id', v_existing_employee."id",
                'employee_linked', v_employee_linked,
                'status', 'HIRED',
                'idempotent_replay', true
            );
        END IF;

        -- HIRED but inconsistent - should be structurally unreachable
        -- given the guard trigger below, but if it's ever seen, it's a
        -- real data-integrity problem that must not be papered over by
        -- quietly returning success.
        RAISE EXCEPTION 'ONBOARDING_HIRED_STATE_INCONSISTENT: record % is HIRED but person %''s cross-table state is inconsistent (person_type=%, hr.employees row exists=%) - investigate manually, do not retry blindly',
            p_onboarding_record_id, v_record."person_id", v_person."person_type", (v_existing_employee."id" IS NOT NULL);
    END IF;

    IF v_record."status" != 'APPROVED' THEN
        RAISE EXCEPTION 'ONBOARDING_NOT_APPROVED: record must be APPROVED before a hire can be confirmed (currently %)', v_record."status";
    END IF;

    SELECT * INTO v_person FROM "core"."people" WHERE "id" = v_record."person_id" FOR UPDATE;
    IF v_person IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_PERSON_NOT_FOUND: no such person - data integrity issue, investigate manually';
    END IF;
    IF v_person."person_type" != 'CANDIDATE' THEN
        RAISE EXCEPTION 'ONBOARDING_PERSON_NOT_CANDIDATE: person % is % not CANDIDATE - refusing to proceed, this indicates an inconsistent prior state', v_person."id", v_person."person_type";
    END IF;
    IF EXISTS (SELECT 1 FROM "hr"."employees" WHERE "person_id" = v_person."id") THEN
        RAISE EXCEPTION 'ONBOARDING_EMPLOYEE_ALREADY_EXISTS: an hr.employees row already exists for person % - refusing to create a duplicate', v_person."id";
    END IF;

    -- Soft check only (see header) - reported, not enforced.
    SELECT EXISTS (
        SELECT 1 FROM "core"."person_user_links"
        WHERE "person_id" = v_person."id" AND "status" = 'ACTIVE'
    ) INTO v_employee_linked;

    -- The three writes - same transaction, all or nothing. Order
    -- matters: both cross-table writes happen BEFORE the onboarding_
    -- records write, so the new AFTER trigger on onboarding_records
    -- (below) sees a fully-consistent state the instant it fires.
    UPDATE "core"."people" SET "person_type" = 'EMPLOYEE' WHERE "id" = v_person."id";

    INSERT INTO "hr"."employees" ("person_id", "employee_number", "hire_date", "employment_status")
    VALUES (v_person."id", p_employee_number, COALESCE(p_hire_date, CURRENT_DATE), 'ACTIVE')
    RETURNING "id" INTO v_new_hr_employee_id;

    UPDATE "onboarding"."onboarding_records"
    SET "status" = 'HIRED', "hired_at" = now(), "hired_by" = v_actor
    WHERE "id" = p_onboarding_record_id;

    RETURN jsonb_build_object(
        'onboarding_record_id', p_onboarding_record_id,
        'person_id', v_person."id",
        'hr_employee_id', v_new_hr_employee_id,
        'employee_linked', v_employee_linked,
        'status', 'HIRED',
        'idempotent_replay', false
    );
END;
$$;

REVOKE ALL ON FUNCTION "onboarding"."confirm_employee_hire"(uuid, varchar, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "onboarding"."confirm_employee_hire"(uuid, varchar, date) TO "authenticated";

-- ------------------------------------------------------------------------
-- Item 3 (second half): database-level cross-table consistency guard.
-- Fires on every INSERT/UPDATE of onboarding_records where the
-- resulting row's status is 'HIRED'. A plain (non-deferred) AFTER ROW
-- trigger is sufficient here, NOT a deferred CONSTRAINT TRIGGER,
-- because confirm_employee_hire() always performs the core.people and
-- hr.employees writes BEFORE the onboarding_records write within the
-- same transaction - by the time this trigger's row event fires, both
-- cross-table writes it needs to see are already visible to it.
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "onboarding"."_enforce_hired_consistency"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "onboarding", "core", "hr"
AS $$
DECLARE
    v_person_type text;
    v_employee_exists boolean;
BEGIN
    IF NEW."status" != 'HIRED' THEN
        RETURN NEW;
    END IF;

    SELECT "person_type" INTO v_person_type FROM "core"."people" WHERE "id" = NEW."person_id";
    SELECT EXISTS (SELECT 1 FROM "hr"."employees" WHERE "person_id" = NEW."person_id") INTO v_employee_exists;

    IF v_person_type IS DISTINCT FROM 'EMPLOYEE' OR NOT v_employee_exists THEN
        RAISE EXCEPTION 'ONBOARDING_HIRED_INVARIANT_VIOLATED: onboarding_records % cannot be HIRED unless person % is EMPLOYEE (is %) and a matching hr.employees row exists (exists=%) - only confirm_employee_hire() may set this status',
            NEW."id", NEW."person_id", v_person_type, v_employee_exists;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_onboarding_records_enforce_hired_consistency" ON "onboarding"."onboarding_records";
CREATE TRIGGER "trg_onboarding_records_enforce_hired_consistency"
    AFTER INSERT OR UPDATE ON "onboarding"."onboarding_records"
    FOR EACH ROW EXECUTE FUNCTION "onboarding"."_enforce_hired_consistency"();

-- ========================================================================
-- END 006_confirm_employee_hire.sql
-- ========================================================================
