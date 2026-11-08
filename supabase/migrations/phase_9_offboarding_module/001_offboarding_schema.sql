-- ========================================================================
-- 001_offboarding_schema.sql  -  Phase 9 Offboarding: schema, tables, guards
-- Requires P01-P06. Canonical employee key = hr.employees.id (hr_employee_id).
-- ROLLBACK ORDER (Track A): 009 -> 008 -> 007 -> 006 -> 005 -> 004 (workflow definition seed) -> 003 -> 002 -> 001.
-- Tables: cases, clearance_tasks, request_idempotency, case_history (append-only),
--         outbox_events (append-only business events), outbox_delivery (mutable delivery state).
-- All writes go through SECURITY DEFINER RPCs added in 005-008 (grants/RLS in 002).
-- ATOMIC: one transaction, strict pre-flight, post-check.
-- ========================================================================
BEGIN;

DO $$
DECLARE v_rel text;
BEGIN
    IF to_regnamespace('offboarding') IS NOT NULL THEN
        RAISE EXCEPTION '001 PRE-FLIGHT: schema offboarding already exists (already applied?)'; END IF;
    FOREACH v_rel IN ARRAY ARRAY['hr.employees','core.people','core.person_user_links','workflow.approval_requests','auth.users'] LOOP
        IF to_regclass(v_rel) IS NULL THEN RAISE EXCEPTION '001 PRE-FLIGHT: required relation % is missing', v_rel; END IF;
    END LOOP;
    IF to_regprocedure('core.has_permission(uuid,text)') IS NULL THEN
        RAISE EXCEPTION '001 PRE-FLIGHT: core.has_permission(uuid,text) is missing'; END IF;
    IF to_regtype('hr.employment_status') IS NULL THEN RAISE EXCEPTION '001 PRE-FLIGHT: hr.employment_status is missing'; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='hr' AND table_name='employees' AND column_name IN ('id','person_id','employment_status') GROUP BY table_name HAVING count(*) = 3) THEN
        RAISE EXCEPTION '001 PRE-FLIGHT: hr.employees lacks id/person_id/employment_status'; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='core' AND table_name='person_user_links' AND column_name IN ('person_id','user_id','status') GROUP BY table_name HAVING count(*) = 3) THEN
        RAISE EXCEPTION '001 PRE-FLIGHT: core.person_user_links lacks person_id/user_id/status'; END IF;
END;
$$;

CREATE SCHEMA "offboarding";

CREATE TYPE "offboarding"."case_type"        AS ENUM ('RESIGNATION', 'TERMINATION');
CREATE TYPE "offboarding"."case_status"      AS ENUM ('SUBMITTED', 'APPROVED', 'IN_CLEARANCE', 'COMPLETED', 'REJECTED', 'WITHDRAWN', 'CANCELLED');
CREATE TYPE "offboarding"."clearance_domain" AS ENUM ('ASSETS', 'ACCESS', 'FINANCE', 'HANDOVER', 'HR');
CREATE TYPE "offboarding"."clearance_status" AS ENUM ('PENDING', 'CLEARED', 'WAIVED');

CREATE TABLE "offboarding"."cases" (
    "id"                   uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "hr_employee_id"       uuid NOT NULL REFERENCES "hr"."employees"("id"),
    "case_type"            "offboarding"."case_type" NOT NULL,
    "status"               "offboarding"."case_status" NOT NULL DEFAULT 'SUBMITTED',
    "reason_category"      varchar(30) NOT NULL,
    "reason_detail"        text,
    "last_working_date"    date NOT NULL,
    "initiated_by"         uuid NOT NULL REFERENCES "auth"."users"("id"),
    "on_behalf"            boolean NOT NULL DEFAULT false,
    "workflow_request_id"  uuid REFERENCES "workflow"."approval_requests"("id"),
    "submitted_at"         timestamptz NOT NULL DEFAULT now(),
    "approved_at"          timestamptz,
    "clearance_started_at" timestamptz,
    "completed_at"         timestamptz,
    "completed_by"         uuid REFERENCES "auth"."users"("id"),
    "withdrawn_at"         timestamptz,
    "withdrawn_by"         uuid REFERENCES "auth"."users"("id"),
    "withdrawal_reason"    text,
    "cancelled_at"         timestamptz,
    "cancelled_by"         uuid REFERENCES "auth"."users"("id"),
    "cancellation_reason"  text,
    "created_at"           timestamptz NOT NULL DEFAULT now(),
    "updated_at"           timestamptz NOT NULL DEFAULT now(),
    "created_by"           uuid REFERENCES "auth"."users"("id"),
    "updated_by"           uuid REFERENCES "auth"."users"("id"),
    "version"              int NOT NULL DEFAULT 1 CHECK ("version" > 0),
    CONSTRAINT "chk_cases_reason_category" CHECK (
        ("case_type" = 'RESIGNATION' AND "reason_category" IN ('PERSONAL','CAREER','RELOCATION','OTHER'))
        OR ("case_type" = 'TERMINATION' AND "reason_category" IN ('PERFORMANCE','CONDUCT','REDUNDANCY','CONTRACT_END','OTHER'))),
    CONSTRAINT "chk_cases_on_behalf_resignation_only" CHECK (NOT "on_behalf" OR "case_type" = 'RESIGNATION'),
    CONSTRAINT "chk_cases_withdrawn_consistent" CHECK (
        ("status" = 'WITHDRAWN') = ("withdrawn_at" IS NOT NULL)
        AND ("withdrawn_at" IS NULL) = ("withdrawn_by" IS NULL)
        AND ("status" <> 'WITHDRAWN' OR ("case_type" = 'RESIGNATION' AND btrim(coalesce("withdrawal_reason", '')) <> ''))
        AND ("status" = 'WITHDRAWN' OR "withdrawal_reason" IS NULL)),
    CONSTRAINT "chk_cases_cancelled_consistent" CHECK (
        ("status" = 'CANCELLED') = ("cancelled_at" IS NOT NULL)
        AND ("cancelled_at" IS NULL) = ("cancelled_by" IS NULL)
        AND ("status" <> 'CANCELLED' OR ("case_type" = 'TERMINATION' AND btrim(coalesce("cancellation_reason", '')) <> ''))
        AND ("status" = 'CANCELLED' OR "cancellation_reason" IS NULL)),
    CONSTRAINT "chk_cases_completed_consistent" CHECK (
        ("status" = 'COMPLETED') = ("completed_at" IS NOT NULL)
        AND ("completed_at" IS NULL) = ("completed_by" IS NULL))
);
CREATE UNIQUE INDEX "idx_offboarding_cases_one_open_per_employee"
    ON "offboarding"."cases" ("hr_employee_id") WHERE "status" IN ('SUBMITTED', 'APPROVED', 'IN_CLEARANCE');
CREATE UNIQUE INDEX "idx_offboarding_cases_workflow_request_unique"
    ON "offboarding"."cases" ("workflow_request_id") WHERE "workflow_request_id" IS NOT NULL;
CREATE INDEX "idx_offboarding_cases_employee" ON "offboarding"."cases" ("hr_employee_id");
CREATE INDEX "idx_offboarding_cases_status"   ON "offboarding"."cases" ("status");

CREATE TABLE "offboarding"."clearance_tasks" (
    "id"             uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "case_id"        uuid NOT NULL REFERENCES "offboarding"."cases"("id"),
    "domain"         "offboarding"."clearance_domain" NOT NULL,
    "status"         "offboarding"."clearance_status" NOT NULL DEFAULT 'PENDING',
    "cleared_at"     timestamptz,
    "cleared_by"     uuid REFERENCES "auth"."users"("id"),
    "clearance_note" text,
    "waived_at"      timestamptz,
    "waived_by"      uuid REFERENCES "auth"."users"("id"),
    "waiver_reason"  text,
    "created_at"     timestamptz NOT NULL DEFAULT now(),
    "updated_at"     timestamptz NOT NULL DEFAULT now(),
    "created_by"     uuid REFERENCES "auth"."users"("id"),
    "updated_by"     uuid REFERENCES "auth"."users"("id"),
    "version"        int NOT NULL DEFAULT 1 CHECK ("version" > 0),
    CONSTRAINT "uq_clearance_tasks_case_domain" UNIQUE ("case_id", "domain"),
    CONSTRAINT "chk_clearance_pending" CHECK ("status" <> 'PENDING'
        OR ("cleared_at" IS NULL AND "cleared_by" IS NULL AND "waived_at" IS NULL AND "waived_by" IS NULL AND "waiver_reason" IS NULL)),
    CONSTRAINT "chk_clearance_cleared" CHECK ("status" <> 'CLEARED'
        OR ("cleared_at" IS NOT NULL AND "cleared_by" IS NOT NULL AND "waived_at" IS NULL AND "waived_by" IS NULL AND "waiver_reason" IS NULL)),
    CONSTRAINT "chk_clearance_waived" CHECK ("status" <> 'WAIVED'
        OR ("waived_at" IS NOT NULL AND "waived_by" IS NOT NULL AND btrim(coalesce("waiver_reason", '')) <> ''
            AND "cleared_at" IS NULL AND "cleared_by" IS NULL AND "domain" <> 'ASSETS'))
);
CREATE INDEX "idx_offboarding_clearance_tasks_case" ON "offboarding"."clearance_tasks" ("case_id");

CREATE TABLE "offboarding"."request_idempotency" (
    "idempotency_key" varchar(255) NOT NULL PRIMARY KEY,
    "operation"       varchar(50)  NOT NULL,
    "case_id"         uuid REFERENCES "offboarding"."cases"("id"),
    "payload_hash"    text NOT NULL,
    "created_by"      uuid NOT NULL REFERENCES "auth"."users"("id"),
    "created_at"      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE "offboarding"."case_history" (
    "id"          uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "case_id"     uuid NOT NULL REFERENCES "offboarding"."cases"("id"),
    "event_type"  varchar(50) NOT NULL,
    "from_status" "offboarding"."case_status",
    "to_status"   "offboarding"."case_status",
    "actor"       uuid REFERENCES "auth"."users"("id"),
    "detail"      jsonb NOT NULL DEFAULT '{}'::jsonb,
    "created_at"  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX "idx_offboarding_case_history_case" ON "offboarding"."case_history" ("case_id", "created_at");

CREATE TABLE "offboarding"."outbox_events" (
    "id"         uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "case_id"    uuid NOT NULL REFERENCES "offboarding"."cases"("id"),
    "event_type" varchar(60) NOT NULL,
    "payload"    jsonb NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT "uq_outbox_events_case_event" UNIQUE ("case_id", "event_type")
);

CREATE TABLE "offboarding"."outbox_delivery" (
    "event_id"        uuid NOT NULL PRIMARY KEY REFERENCES "offboarding"."outbox_events"("id"),
    "delivery_status" varchar(20) NOT NULL DEFAULT 'PENDING' CHECK ("delivery_status" IN ('PENDING', 'DELIVERED', 'FAILED')),
    "attempts"        int NOT NULL DEFAULT 0 CHECK ("attempts" >= 0),
    "last_attempt_at" timestamptz,
    "delivered_at"    timestamptz,
    "last_error"      text,
    "updated_at"      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT "chk_outbox_delivery_delivered" CHECK (("delivery_status" = 'DELIVERED') = ("delivered_at" IS NOT NULL))
);

-- ---------------- trigger functions (pinned search_path; no EXECUTE for app roles, see 002) ----------------
CREATE FUNCTION "offboarding"."_force_created_by"() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, "offboarding" AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'OFFBOARDING_CREATED_BY_REQUIRES_AUTHENTICATED_SESSION: % requires an authenticated session', TG_TABLE_NAME;
    END IF;
    NEW."created_by" := auth.uid();
    RETURN NEW;
END;
$$;

CREATE FUNCTION "offboarding"."_force_updated_by"() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, "offboarding" AS $$
BEGIN
    NEW."updated_by" := auth.uid();
    NEW."updated_at" := now();
    NEW."version"    := OLD."version" + 1;
    RETURN NEW;
END;
$$;

CREATE FUNCTION "offboarding"."_enforce_case_status_transition"() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, "offboarding" AS $$
BEGIN
    -- A terminal case is a final business record: ANY update is rejected, including an update that keeps
    -- the same status and changes another column. Later operational facts belong in history/outbox/delivery.
    IF OLD."status" IN ('COMPLETED', 'REJECTED', 'WITHDRAWN', 'CANCELLED') THEN
        RAISE EXCEPTION 'OFFBOARDING_TERMINAL_STATUS: case % is final (status %) and cannot be updated', OLD."id", OLD."status";
    END IF;
    IF NEW."hr_employee_id" IS DISTINCT FROM OLD."hr_employee_id"
       OR NEW."case_type" IS DISTINCT FROM OLD."case_type"
       OR NEW."initiated_by" IS DISTINCT FROM OLD."initiated_by"
       OR NEW."on_behalf" IS DISTINCT FROM OLD."on_behalf" THEN
        RAISE EXCEPTION 'OFFBOARDING_IMMUTABLE_COLUMN: hr_employee_id, case_type, initiated_by and on_behalf cannot change (case %)', OLD."id";
    END IF;
    IF NEW."status" = OLD."status" THEN RETURN NEW; END IF;
    IF NOT (
           (OLD."status" = 'SUBMITTED'    AND NEW."status" IN ('APPROVED', 'REJECTED'))
        OR (OLD."status" = 'APPROVED'     AND NEW."status" = 'IN_CLEARANCE')
        OR (OLD."status" = 'IN_CLEARANCE' AND NEW."status" = 'COMPLETED')
        OR (OLD."status" IN ('SUBMITTED', 'APPROVED', 'IN_CLEARANCE') AND NEW."status" = 'WITHDRAWN' AND NEW."case_type" = 'RESIGNATION')
        OR (OLD."status" IN ('SUBMITTED', 'APPROVED', 'IN_CLEARANCE') AND NEW."status" = 'CANCELLED' AND NEW."case_type" = 'TERMINATION')
    ) THEN
        RAISE EXCEPTION 'OFFBOARDING_INVALID_TRANSITION: % -> % is not an allowed transition for a % case (case %)', OLD."status", NEW."status", NEW."case_type", OLD."id";
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION "offboarding"."_enforce_clearance_transition"() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, "offboarding" AS $$
BEGIN
    -- Once CLEARED or WAIVED the task is final: ANY update is rejected (sign-off data included),
    -- not only a status change.
    IF OLD."status" <> 'PENDING' THEN
        RAISE EXCEPTION 'OFFBOARDING_CLEARANCE_TERMINAL: a % clearance task is final and cannot be updated (task %)', OLD."status", OLD."id";
    END IF;
    IF NEW."case_id" IS DISTINCT FROM OLD."case_id" OR NEW."domain" IS DISTINCT FROM OLD."domain" THEN
        RAISE EXCEPTION 'OFFBOARDING_IMMUTABLE_COLUMN: case_id and domain of a clearance task cannot change (task %)', OLD."id";
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION "offboarding"."_prevent_mutation"() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, "offboarding" AS $$
BEGIN
    RAISE EXCEPTION 'OFFBOARDING_APPEND_ONLY: % on offboarding.% is not allowed - rows are immutable once written', TG_OP, TG_TABLE_NAME;
END;
$$;

-- Internal trigger functions: no EXECUTE for PUBLIC / anon / authenticated, established HERE so that
-- rolling back 002 restores the true post-001 state exactly. (Triggers do not need the invoker to
-- hold EXECUTE; only the owner-run SECURITY DEFINER RPCs fire them.)
REVOKE ALL ON FUNCTION "offboarding"."_force_created_by"()              FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."_force_updated_by"()              FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."_enforce_case_status_transition"() FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."_enforce_clearance_transition"()   FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION "offboarding"."_prevent_mutation"()               FROM PUBLIC, "anon", "authenticated";

CREATE TRIGGER "trg_cases_created_by"  BEFORE INSERT ON "offboarding"."cases" FOR EACH ROW EXECUTE FUNCTION "offboarding"."_force_created_by"();
CREATE TRIGGER "trg_cases_updated_by"  BEFORE UPDATE ON "offboarding"."cases" FOR EACH ROW EXECUTE FUNCTION "offboarding"."_force_updated_by"();
CREATE TRIGGER "trg_cases_status_transition" BEFORE UPDATE ON "offboarding"."cases" FOR EACH ROW EXECUTE FUNCTION "offboarding"."_enforce_case_status_transition"();
CREATE TRIGGER "trg_clearance_created_by" BEFORE INSERT ON "offboarding"."clearance_tasks" FOR EACH ROW EXECUTE FUNCTION "offboarding"."_force_created_by"();
CREATE TRIGGER "trg_clearance_updated_by" BEFORE UPDATE ON "offboarding"."clearance_tasks" FOR EACH ROW EXECUTE FUNCTION "offboarding"."_force_updated_by"();
CREATE TRIGGER "trg_clearance_transition" BEFORE UPDATE ON "offboarding"."clearance_tasks" FOR EACH ROW EXECUTE FUNCTION "offboarding"."_enforce_clearance_transition"();
CREATE TRIGGER "trg_case_history_immutable" BEFORE UPDATE OR DELETE ON "offboarding"."case_history" FOR EACH ROW EXECUTE FUNCTION "offboarding"."_prevent_mutation"();
CREATE TRIGGER "trg_outbox_events_immutable" BEFORE UPDATE OR DELETE ON "offboarding"."outbox_events" FOR EACH ROW EXECUTE FUNCTION "offboarding"."_prevent_mutation"();

-- ---------------- post-check (same transaction) ----------------
DO $$
DECLARE v_t text;
BEGIN
    FOREACH v_t IN ARRAY ARRAY['cases','clearance_tasks','request_idempotency','case_history','outbox_events','outbox_delivery'] LOOP
        IF to_regclass('offboarding.' || v_t) IS NULL THEN RAISE EXCEPTION '001 POST-CHECK: offboarding.% was not created', v_t; END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'offboarding' AND NOT t.tgisinternal) <> 8 THEN
        RAISE EXCEPTION '001 POST-CHECK: expected exactly 8 offboarding triggers'; END IF;
    -- internal trigger functions: exactly 5, none executable by PUBLIC (default ACL or explicit), anon or authenticated
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'offboarding') <> 5 THEN
        RAISE EXCEPTION '001 POST-CHECK: expected exactly 5 offboarding functions'; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'offboarding'
                  AND (p.proacl IS NULL
                       OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
                       OR has_function_privilege('anon', p.oid, 'EXECUTE')
                       OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))) THEN
        RAISE EXCEPTION '001 POST-CHECK: an internal trigger function is executable by PUBLIC, anon or authenticated'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END 001_offboarding_schema.sql
-- ========================================================================
