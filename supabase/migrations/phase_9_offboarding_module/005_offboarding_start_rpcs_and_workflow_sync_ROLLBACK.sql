-- ========================================================================
-- 005_offboarding_start_rpcs_and_workflow_sync_ROLLBACK.sql
-- Removes the start RPCs, the internal implementation and the workflow sync trigger.
-- REFUSES while any case is still SUBMITTED (removing the sync trigger would strand an in-flight
-- approval). Roll back 006-009 first.
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regprocedure('offboarding.start_resignation(character varying,date,character varying,text)') IS NULL THEN
        RAISE EXCEPTION '005 ROLLBACK PRE-FLIGHT: 005 does not appear to be applied'; END IF;
    IF EXISTS (SELECT 1 FROM offboarding.cases WHERE status = 'SUBMITTED') THEN
        RAISE EXCEPTION '005 ROLLBACK PRE-FLIGHT: SUBMITTED cases exist; resolve them before removing the workflow sync trigger'; END IF;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'offboarding' AND p.proname NOT LIKE E'\\_%' AND p.proname <> 'seed_offboarding_workflow_definitions'
           AND p.proname NOT IN ('start_resignation', 'start_resignation_on_behalf', 'start_termination')) > 0 THEN
        RAISE EXCEPTION '005 ROLLBACK PRE-FLIGHT: later Offboarding functions (006-009) still exist - roll them back first'; END IF;
END;
$$;

DROP TRIGGER "trg_offboarding_on_workflow_status_change" ON "workflow"."status_history";
DROP FUNCTION "offboarding"."_on_workflow_status_change"();
DROP FUNCTION "offboarding"."start_termination"(uuid, varchar, date, varchar, text);
DROP FUNCTION "offboarding"."start_resignation_on_behalf"(uuid, varchar, date, varchar, text);
DROP FUNCTION "offboarding"."start_resignation"(varchar, date, varchar, text);
DROP FUNCTION "offboarding"."_start_case"(uuid, uuid, text, varchar, varchar, date, varchar, text, boolean);
-- IF EXISTS so this rollback also works on a database where the first (marker-based) 005 was applied
DROP TABLE IF EXISTS "offboarding"."_workflow_sanctions";

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_offboarding_on_workflow_status_change') THEN RAISE EXCEPTION '005 ROLLBACK POST-CHECK: sync trigger remains'; END IF;
    IF to_regclass('offboarding._workflow_sanctions') IS NOT NULL THEN RAISE EXCEPTION '005 ROLLBACK POST-CHECK: sanction table remains'; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding' AND p.proname IN ('start_resignation','start_resignation_on_behalf','start_termination','_start_case','_on_workflow_status_change')) THEN
        RAISE EXCEPTION '005 ROLLBACK POST-CHECK: 005 functions remain'; END IF;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'offboarding' AND p.proname LIKE E'\\_%') <> 5
       OR to_regprocedure('offboarding.seed_offboarding_workflow_definitions()') IS NULL THEN
        RAISE EXCEPTION '005 ROLLBACK POST-CHECK: the post-004 function set is not restored exactly'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 005_offboarding_start_rpcs_and_workflow_sync_ROLLBACK.sql
-- ========================================================================
