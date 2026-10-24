-- ========================================================================
-- P04_hr_employee_status_history_and_termination.sql   (Phase 9 prereq 4 of 4)
-- HR-OWNED: employee status history + sanctioned termination + terminal guard.
-- Depends on P03 (hr._sanctioned_transitions, hr._prevent_mutation).
--
-- LIVE FINDINGS this addresses: hr.employees has employment_status
-- (ACTIVE / ON_LEAVE / TERMINATED) and termination_date, no history table, and
-- no guard - a PEOPLE_MANAGE holder can currently set TERMINATED or
-- termination_date directly.
--
-- 1) hr.employee_status_history - append-only (immutability trigger), written
--    only by trigger / sanctioned function (no write privilege or policy for
--    any application role). Columns: employee_id, previous_status, new_status,
--    effective_date, changed_at, changed_by (+ txid and source for
--    traceability). It deliberately has NO reason/notes column: termination
--    reasoning belongs to the offboarding case.
--    Existing employees are backfilled with one BACKFILL row each.
--
-- 2) AFTER INSERT / status-UPDATE trigger records history for EVERY status
--    change (including ordinary ACTIVE <-> ON_LEAVE), so history is complete
--    whatever path made the change. A sanctioned termination writes its own
--    row (source SANCTIONED_TERMINATION) and the trigger then skips the
--    duplicate.
--
-- 3) hr.terminate_employee(hr_employee_id, termination_date) - INTERNAL ONLY
--    (EXECUTE revoked from PUBLIC/anon/authenticated; called by
--    complete_offboarding(), which authorizes the caller). Sets
--    employment_status = TERMINATED and termination_date, records history,
--    idempotent on replay with the same date (different date = mismatch error).
--    core.people.person_type is NOT touched.
--
-- 4) Guard trigger (BEFORE INSERT OR UPDATE on hr.employees):
--      * inserting an employee already TERMINATED / with a termination_date
--      * entering TERMINATED, or changing termination_date, without a
--        sanction for this employee in this transaction
--      * LEAVING TERMINATED (terminal state; rehire is out of scope)
--    are all rejected. ACTIVE <-> ON_LEAVE and every other column edit are
--    untouched.
--
-- Version handling (team-lead rule): the first real termination increments
-- hr.employees.version exactly once; an idempotent replay increments nothing;
-- a rejected call changes nothing. (Ordinary direct edits by PEOPLE_MANAGE are
-- not changed by this migration.) FOUND instead of whole-record NULL tests.
--
-- ONE AUTHORITATIVE HISTORY PATH PER KIND OF CHANGE (deterministic):
--   * termination: terminate_employee() inserts the SANCTIONED_TERMINATION
--     history row itself, BEFORE it updates the employee. The AFTER UPDATE
--     trigger then looks for a row with the same employee_id, the same
--     transaction id (txid_current()), the same new_status and source =
--     'SANCTIONED_TERMINATION'; finding it, the trigger inserts nothing. So a
--     sanctioned termination yields exactly ONE history row.
--   * every other status change (insert, ACTIVE <-> ON_LEAVE): the trigger is
--     the only writer.
--
-- SANCTION BINDING (verified and permanently tested): the guard accepts a
-- termination or termination_date change only if hr._sanctioned_transitions
-- contains a row matching ALL of: kind = 'EMPLOYEE', entity_id = this
-- employee, to_status = 'TERMINATED', txid = txid_current(). A row committed
-- by an earlier transaction, for another entity, of another kind or for another
-- target status authorizes nothing.
-- Rollback: P04_hr_employee_status_history_and_termination_ROLLBACK.sql
-- ========================================================================

DO $$
BEGIN
    IF to_regclass('hr._sanctioned_transitions') IS NULL OR to_regprocedure('hr._prevent_mutation()') IS NULL THEN
        RAISE EXCEPTION 'P04_REQUIRES_P03: apply P03 first (hr._sanctioned_transitions / hr._prevent_mutation are missing)';
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS "hr"."employee_status_history" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    "employee_id" uuid NOT NULL REFERENCES "hr"."employees"("id"),
    "previous_status" "hr"."employment_status",
    "new_status" "hr"."employment_status" NOT NULL,
    "effective_date" date NOT NULL,
    "changed_at" timestamptz NOT NULL DEFAULT now(),
    "changed_by" uuid REFERENCES "auth"."users"("id"),
    "txid" bigint NOT NULL DEFAULT txid_current(),
    "source" text NOT NULL CHECK ("source" IN ('BACKFILL', 'EMPLOYEE_INSERT', 'DIRECT_UPDATE', 'SANCTIONED_TERMINATION'))
);
CREATE INDEX IF NOT EXISTS "idx_employee_status_history_employee" ON "hr"."employee_status_history" ("employee_id", "changed_at");

DROP TRIGGER IF EXISTS "trg_employee_status_history_immutable" ON "hr"."employee_status_history";
CREATE TRIGGER "trg_employee_status_history_immutable"
    BEFORE UPDATE OR DELETE ON "hr"."employee_status_history"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_prevent_mutation"();

ALTER TABLE "hr"."employee_status_history" ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE "hr"."employee_status_history" FROM PUBLIC, "anon", "authenticated";
GRANT SELECT ON TABLE "hr"."employee_status_history" TO "authenticated";

DROP POLICY IF EXISTS "employee_status_history_select" ON "hr"."employee_status_history";
CREATE POLICY "employee_status_history_select" ON "hr"."employee_status_history"
    FOR SELECT TO "authenticated"
    USING (
        core.has_permission(auth.uid(), 'PEOPLE_MANAGE')
        OR core.has_permission(auth.uid(), 'PEOPLE_VIEW_ALL')
        OR "employee_id" IN (
            SELECT e."id" FROM "hr"."employees" e
            JOIN "core"."person_user_links" l ON l."person_id" = e."person_id"
            WHERE l."user_id" = auth.uid() AND l."status" = 'ACTIVE'
        )
    );

-- backfill: one row per existing employee that has no history yet
INSERT INTO "hr"."employee_status_history" ("employee_id", "previous_status", "new_status", "effective_date", "changed_by", "source")
SELECT e."id", NULL, e."employment_status", COALESCE(e."hire_date", e."created_at"::date), NULL, 'BACKFILL'
FROM "hr"."employees" e
WHERE NOT EXISTS (SELECT 1 FROM "hr"."employee_status_history" h WHERE h."employee_id" = e."id");

-- ---- history for every status change ------------------------------------
CREATE OR REPLACE FUNCTION "hr"."_record_employee_status_history"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "hr", "auth"
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO "hr"."employee_status_history" ("employee_id", "previous_status", "new_status", "effective_date", "changed_by", "source")
        VALUES (NEW."id", NULL, NEW."employment_status", COALESCE(NEW."hire_date", CURRENT_DATE), auth.uid(), 'EMPLOYEE_INSERT');
        RETURN NULL;
    END IF;

    -- UPDATE with a changed status: skip if the sanctioned function already wrote this row
    IF EXISTS (SELECT 1 FROM "hr"."employee_status_history" h
               WHERE h."employee_id" = NEW."id" AND h."txid" = txid_current()
                 AND h."new_status" = NEW."employment_status" AND h."source" = 'SANCTIONED_TERMINATION') THEN
        RETURN NULL;
    END IF;

    INSERT INTO "hr"."employee_status_history" ("employee_id", "previous_status", "new_status", "effective_date", "changed_by", "source")
    VALUES (NEW."id", OLD."employment_status", NEW."employment_status", CURRENT_DATE, auth.uid(), 'DIRECT_UPDATE');
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS "trg_employees_record_status_history_ins" ON "hr"."employees";
CREATE TRIGGER "trg_employees_record_status_history_ins"
    AFTER INSERT ON "hr"."employees"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_record_employee_status_history"();

DROP TRIGGER IF EXISTS "trg_employees_record_status_history_upd" ON "hr"."employees";
CREATE TRIGGER "trg_employees_record_status_history_upd"
    AFTER UPDATE OF "employment_status" ON "hr"."employees"
    FOR EACH ROW WHEN (OLD."employment_status" IS DISTINCT FROM NEW."employment_status")
    EXECUTE FUNCTION "hr"."_record_employee_status_history"();

-- ---- guard ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION "hr"."_guard_employee_termination"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "hr"
AS $$
DECLARE
    v_needs_sanction boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_needs_sanction := (NEW."employment_status" = 'TERMINATED' OR NEW."termination_date" IS NOT NULL);
    ELSE
        IF OLD."employment_status" = 'TERMINATED' AND NEW."employment_status" <> 'TERMINATED' THEN
            RAISE EXCEPTION 'HR_EMPLOYEE_TERMINATED_IS_TERMINAL: employee % is TERMINATED and cannot return to % (rehire is a separate lifecycle, out of scope)', NEW."id", NEW."employment_status";
        END IF;
        v_needs_sanction := (NEW."employment_status" = 'TERMINATED' AND OLD."employment_status" <> 'TERMINATED')
                            OR (NEW."termination_date" IS DISTINCT FROM OLD."termination_date");
    END IF;

    IF v_needs_sanction AND NOT EXISTS (
        SELECT 1 FROM "hr"."_sanctioned_transitions" s
        WHERE s."kind" = 'EMPLOYEE' AND s."entity_id" = NEW."id"
          AND s."to_status" = 'TERMINATED' AND s."txid" = txid_current()
    ) THEN
        RAISE EXCEPTION 'HR_EMPLOYEE_TERMINATION_NOT_SANCTIONED: employee % can only be terminated, or have termination_date set or changed, through the sanctioned termination function', NEW."id";
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_employees_guard_termination" ON "hr"."employees";
CREATE TRIGGER "trg_employees_guard_termination"
    BEFORE INSERT OR UPDATE ON "hr"."employees"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_guard_employee_termination"();

-- ---- sanctioned termination (internal only) --------------------------------
CREATE OR REPLACE FUNCTION "hr"."terminate_employee"("p_hr_employee_id" uuid, "p_termination_date" date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "hr", "core", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_e "hr"."employees";
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'HR_UNAUTHENTICATED: terminate_employee requires an authenticated session (the actor is recorded)';
    END IF;
    IF p_termination_date IS NULL THEN
        RAISE EXCEPTION 'HR_TERMINATION_DATE_REQUIRED: a termination date is required';
    END IF;

    SELECT * INTO v_e FROM "hr"."employees" WHERE "id" = p_hr_employee_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HR_EMPLOYEE_NOT_FOUND: no such employee';
    END IF;

    IF v_e."employment_status" = 'TERMINATED' THEN
        IF v_e."termination_date" IS NOT DISTINCT FROM p_termination_date THEN
            RETURN jsonb_build_object('employee_id', v_e."id", 'status', 'TERMINATED', 'termination_date', v_e."termination_date", 'idempotent_replay', true);
        END IF;
        RAISE EXCEPTION 'HR_EMPLOYEE_TERMINATION_REPLAY_MISMATCH: employee % was already terminated with termination date % - a retry must use the same date', p_hr_employee_id, v_e."termination_date";
    END IF;

    IF v_e."hire_date" IS NOT NULL AND p_termination_date < v_e."hire_date" THEN
        RAISE EXCEPTION 'HR_TERMINATION_BEFORE_HIRE_DATE: termination date % is before the hire date %', p_termination_date, v_e."hire_date";
    END IF;

    INSERT INTO "hr"."_sanctioned_transitions" ("kind", "entity_id", "to_status", "effective_date", "authorized_by")
    VALUES ('EMPLOYEE', v_e."id", 'TERMINATED', p_termination_date, v_actor);

    INSERT INTO "hr"."employee_status_history" ("employee_id", "previous_status", "new_status", "effective_date", "changed_by", "source")
    VALUES (v_e."id", v_e."employment_status", 'TERMINATED', p_termination_date, v_actor, 'SANCTIONED_TERMINATION');

    UPDATE "hr"."employees"
    SET "employment_status" = 'TERMINATED', "termination_date" = p_termination_date, "version" = "version" + 1
    WHERE "id" = v_e."id";

    RETURN jsonb_build_object('employee_id', v_e."id", 'status', 'TERMINATED', 'termination_date', p_termination_date, 'idempotent_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION "hr"."terminate_employee"(uuid, date) FROM PUBLIC, "anon", "authenticated";

-- ========================================================================
-- END P04_hr_employee_status_history_and_termination.sql
-- ========================================================================
