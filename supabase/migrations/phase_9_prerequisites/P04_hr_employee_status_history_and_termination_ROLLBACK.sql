-- ========================================================================
-- P04_hr_employee_status_history_and_termination_ROLLBACK.sql
-- Drops the guard, history triggers, functions and the history table (which
-- also removes the recorded history). Employees already TERMINATED stay
-- TERMINATED (business data). Run BEFORE P03's rollback.
-- ========================================================================
DROP TRIGGER IF EXISTS "trg_employees_guard_termination" ON "hr"."employees";
DROP TRIGGER IF EXISTS "trg_employees_record_status_history_ins" ON "hr"."employees";
DROP TRIGGER IF EXISTS "trg_employees_record_status_history_upd" ON "hr"."employees";
DROP FUNCTION IF EXISTS "hr"."terminate_employee"(uuid, date);
DROP FUNCTION IF EXISTS "hr"."_guard_employee_termination"();
DROP FUNCTION IF EXISTS "hr"."_record_employee_status_history"();
DROP TABLE IF EXISTS "hr"."employee_status_history";
