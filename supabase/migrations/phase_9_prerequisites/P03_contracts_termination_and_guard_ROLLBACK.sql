-- ========================================================================
-- P03_contracts_termination_and_guard_ROLLBACK.sql
-- Run P04's rollback FIRST. Drops the guard, the function and the ledger.
-- Contracts already TERMINATED by the function stay TERMINATED (business data).
-- ========================================================================
DO $$
BEGIN
    IF to_regclass('hr.employee_status_history') IS NOT NULL OR to_regprocedure('hr.terminate_employee(uuid,date)') IS NOT NULL THEN
        RAISE EXCEPTION 'P03_ROLLBACK_BLOCKED: P04 objects still exist and depend on hr._sanctioned_transitions - run P04_..._ROLLBACK.sql first';
    END IF;
END;
$$;
DROP TRIGGER IF EXISTS "trg_contracts_guard_termination" ON "hr"."contracts";
DROP FUNCTION IF EXISTS "hr"."_guard_contract_termination"();
DROP FUNCTION IF EXISTS "hr"."terminate_contract"(uuid, date);
DROP TABLE IF EXISTS "hr"."_sanctioned_transitions";
DROP FUNCTION IF EXISTS "hr"."_prevent_mutation"();
