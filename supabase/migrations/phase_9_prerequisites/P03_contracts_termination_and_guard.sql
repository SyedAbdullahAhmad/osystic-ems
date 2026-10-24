-- ========================================================================
-- P03_contracts_termination_and_guard.sql   (Phase 9 prerequisite 3 of 4)
-- CONTRACTS-OWNED termination function + narrow TERMINATED guard, plus the
-- shared "sanctioned transition" ledger that P04 (employees) reuses.
--
-- WHAT EXISTS TODAY (live schema): hr.contracts.status has a TERMINATED value
-- but no function can reach it, and CONTRACT_MANAGE can UPDATE the table
-- directly with no status guard.
--
-- 1) hr._sanctioned_transitions - tiny internal ledger. A sanctioned function
--    writes one row (kind, entity, target status, current transaction id)
--    immediately before it performs the guarded change. The guard trigger
--    allows the change only if such a row exists for THIS transaction. The
--    table has RLS enabled with no policies and no privileges for PUBLIC /
--    anon / authenticated, and an immutability trigger, so no application
--    role can forge a sanction (unlike a session setting, which any SQL
--    session could set).
--
-- 2) hr.terminate_contract(contract_id, effective_date) - INTERNAL ONLY
--    (EXECUTE revoked from PUBLIC/anon/authenticated; it is called by other
--    SECURITY DEFINER functions such as complete_offboarding(), which do the
--    caller's authorization). Behaviour (team-lead decision):
--      * contract must be ACTIVE (already TERMINATED = idempotent replay if
--        the same effective date, else a mismatch error)
--      * effective date must be >= current version's effective_from
--      * sets contracts.status = TERMINATED
--      * closes the CURRENT version: effective_to = LEAST(existing
--        effective_to, effective date) - termination never EXTENDS a version
--        that already ended earlier
--      * no new contract version is created
--
-- 3) Guard trigger: entering status TERMINATED (UPDATE or INSERT) is rejected
--    unless sanctioned. Every other transition (DRAFT/PENDING_APPROVAL/
--    APPROVED/REJECTED/ACTIVE/EXPIRED, and the workflow trigger's
--    PENDING_APPROVAL -> ACTIVE/REJECTED) is untouched.
--
-- Version handling (team-lead rule): the first real termination increments
-- "version" exactly once on hr.contracts AND on the closed hr.contract_versions
-- row; an idempotent replay increments nothing; a rejected call changes nothing.
-- FOUND instead of whole-record NULL tests.
--
-- SANCTION BINDING (verified and permanently tested): the guard accepts a
-- change only if hr._sanctioned_transitions contains a row matching ALL of:
--   kind = 'CONTRACT', entity_id = this contract, to_status = 'TERMINATED',
--   txid = txid_current()
-- A row committed by an earlier transaction, for another entity, of another
-- kind or for another target status authorizes nothing.
-- Rollback: P03_contracts_termination_and_guard_ROLLBACK.sql
-- (run P04's rollback first - P04 depends on the ledger created here).
-- ========================================================================

CREATE TABLE IF NOT EXISTS "hr"."_sanctioned_transitions" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    "kind" text NOT NULL CHECK ("kind" IN ('CONTRACT', 'EMPLOYEE')),
    "entity_id" uuid NOT NULL,
    "to_status" text NOT NULL,
    "effective_date" date,
    "txid" bigint NOT NULL DEFAULT txid_current(),
    "authorized_by" uuid,
    "created_at" timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS "idx_sanctioned_transitions_lookup" ON "hr"."_sanctioned_transitions" ("kind", "entity_id", "txid");
ALTER TABLE "hr"."_sanctioned_transitions" ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE "hr"."_sanctioned_transitions" FROM PUBLIC, "anon", "authenticated";

-- shared immutability trigger function (P04 reuses it for the status history)
CREATE OR REPLACE FUNCTION "hr"."_prevent_mutation"()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, "hr"
AS $$
BEGIN
    RAISE EXCEPTION 'HR_APPEND_ONLY: % on hr.% is not allowed - rows are immutable once written', TG_OP, TG_TABLE_NAME;
END;
$$;

DROP TRIGGER IF EXISTS "trg_sanctioned_transitions_immutable" ON "hr"."_sanctioned_transitions";
CREATE TRIGGER "trg_sanctioned_transitions_immutable"
    BEFORE UPDATE OR DELETE ON "hr"."_sanctioned_transitions"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_prevent_mutation"();

-- ---- guard: entering TERMINATED needs a sanction for THIS transaction ----
CREATE OR REPLACE FUNCTION "hr"."_guard_contract_termination"()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "hr"
AS $$
DECLARE
    v_entering boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_entering := (NEW."status" = 'TERMINATED');
    ELSE
        v_entering := (NEW."status" = 'TERMINATED' AND OLD."status" <> 'TERMINATED');
    END IF;

    IF v_entering AND NOT EXISTS (
        SELECT 1 FROM "hr"."_sanctioned_transitions" s
        WHERE s."kind" = 'CONTRACT' AND s."entity_id" = NEW."id"
          AND s."to_status" = 'TERMINATED' AND s."txid" = txid_current()
    ) THEN
        RAISE EXCEPTION 'HR_CONTRACT_TERMINATION_NOT_SANCTIONED: contract % can only become TERMINATED through the sanctioned termination function', NEW."id";
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_contracts_guard_termination" ON "hr"."contracts";
CREATE TRIGGER "trg_contracts_guard_termination"
    BEFORE INSERT OR UPDATE OF "status" ON "hr"."contracts"
    FOR EACH ROW EXECUTE FUNCTION "hr"."_guard_contract_termination"();

-- ---- the sanctioned termination function (internal only) ----------------
CREATE OR REPLACE FUNCTION "hr"."terminate_contract"("p_contract_id" uuid, "p_effective_date" date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "hr", "core", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_c "hr"."contracts";
    v_v "hr"."contract_versions";
    v_new_to date;
    v_recorded_date date;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'HR_UNAUTHENTICATED: terminate_contract requires an authenticated session (the actor is recorded)';
    END IF;
    IF p_effective_date IS NULL THEN
        RAISE EXCEPTION 'HR_TERMINATION_DATE_REQUIRED: an effective termination date is required';
    END IF;

    SELECT * INTO v_c FROM "hr"."contracts" WHERE "id" = p_contract_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HR_CONTRACT_NOT_FOUND: no such contract';
    END IF;

    SELECT * INTO v_v FROM "hr"."contract_versions" WHERE "id" = v_c."current_version_id" AND "contract_id" = v_c."id" FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HR_CONTRACT_NO_CURRENT_VERSION: contract % has no valid current version', p_contract_id;
    END IF;

    IF v_c."status" = 'TERMINATED' THEN
        SELECT s."effective_date" INTO v_recorded_date FROM "hr"."_sanctioned_transitions" s
        WHERE s."kind" = 'CONTRACT' AND s."entity_id" = v_c."id" AND s."to_status" = 'TERMINATED'
        ORDER BY s."created_at" DESC LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'HR_CONTRACT_TERMINATED_UNRECORDED: contract % is TERMINATED but has no recorded sanctioned termination - investigate manually', p_contract_id;
        END IF;
        IF v_recorded_date IS DISTINCT FROM p_effective_date THEN
            RAISE EXCEPTION 'HR_CONTRACT_TERMINATION_REPLAY_MISMATCH: contract % was already terminated with effective date % - a retry must use the same date', p_contract_id, v_recorded_date;
        END IF;
        RETURN jsonb_build_object('contract_id', v_c."id", 'status', 'TERMINATED', 'effective_to', v_v."effective_to", 'idempotent_replay', true);
    END IF;

    IF v_c."status" <> 'ACTIVE' THEN
        RAISE EXCEPTION 'HR_CONTRACT_NOT_ACTIVE: only an ACTIVE contract can be terminated (currently %)', v_c."status";
    END IF;
    IF p_effective_date < v_v."effective_from" THEN
        RAISE EXCEPTION 'HR_TERMINATION_BEFORE_EFFECTIVE_FROM: termination date % is before the current version starts (%)', p_effective_date, v_v."effective_from";
    END IF;

    v_new_to := LEAST(coalesce(v_v."effective_to", p_effective_date), p_effective_date);

    INSERT INTO "hr"."_sanctioned_transitions" ("kind", "entity_id", "to_status", "effective_date", "authorized_by")
    VALUES ('CONTRACT', v_c."id", 'TERMINATED', p_effective_date, v_actor);

    UPDATE "hr"."contract_versions" SET "effective_to" = v_new_to, "version" = "version" + 1 WHERE "id" = v_v."id";
    UPDATE "hr"."contracts" SET "status" = 'TERMINATED', "version" = "version" + 1 WHERE "id" = v_c."id";

    RETURN jsonb_build_object('contract_id', v_c."id", 'status', 'TERMINATED', 'effective_to', v_new_to, 'idempotent_replay', false);
END;
$$;

REVOKE ALL ON FUNCTION "hr"."terminate_contract"(uuid, date) FROM PUBLIC, "anon", "authenticated";

-- ========================================================================
-- END P03_contracts_termination_and_guard.sql
-- ========================================================================
