-- ========================================================================
-- P06_contracts_rpc_only_and_asset_status_guard.sql
-- Shared-module security fix #2 (follows P05). Requires P01-P05 applied.
-- Evidence (rolled-back, as authenticated): CONTRACT_MANAGE could directly INSERT,
-- UPDATE (DRAFT->ACTIVE) and DELETE hr.contracts and write hr.contract_versions;
-- ASSET_MANAGE could directly set assets.current_status=ASSIGNED, INSERT an asset
-- already ASSIGNED, and hard-DELETE assets.
--
-- Part A  CONTRACTS ARE RPC-ONLY. The two ALL policies (contracts_manage,
--         contract_versions_manage) are dropped and INSERT/UPDATE/DELETE are revoked
--         from authenticated on hr.contracts and hr.contract_versions. Read access is
--         unchanged (contracts_select / contract_versions_select already cover
--         CONTRACT_MANAGE holders). Every writer is a SECURITY DEFINER path:
--         create_contract, the workflow status trigger, terminate_contract. The P03
--         TERMINATED guard stays as defence in depth.
-- Part B  ASSETS. ASSET_MANAGE keeps inventory INSERT and edit; hard DELETE is removed;
--         entering or leaving ASSIGNED is allowed only through fulfill_asset_request /
--         return_asset, via an Assets-owned transaction-bound ledger
--         (assets._sanctioned_transitions: txid + asset id + target status, append-only,
--         no HR dependency). fulfill_asset_request now also bumps assets.version once
--         (return_asset already did).
--
-- NOT CHANGED: assets.assets SELECT visibility (separate change), request-table policies
-- (P05), any other function/trigger, Finance RBAC tables.
-- ATOMIC: one transaction; strict pre-flight; post-check inside the same transaction.
-- ========================================================================
BEGIN;

DO $$
DECLARE v_sig text; v_rel text; v_priv text; v_n int; v_exp record;
BEGIN
    -- 1. exact routines the application and the guard rely on, all SECURITY DEFINER, no overloads
    FOREACH v_sig IN ARRAY ARRAY[
        'hr.create_contract(uuid,hr.contract_type,date,date,uuid,text,character varying,character varying)',
        'hr.terminate_contract(uuid,date)',
        'hr._on_contract_workflow_status_change()',
        'workflow.process_approval_action(uuid,workflow.approval_action_type,uuid,text,jsonb,character varying,integer)',
        'assets.fulfill_asset_request(uuid,uuid)',
        'assets.return_asset(uuid)'] LOOP
        IF to_regprocedure(v_sig) IS NULL THEN RAISE EXCEPTION 'P06 PRE-FLIGHT: exact signature % not found', v_sig; END IF;
        IF NOT (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = to_regprocedure(v_sig)::oid) THEN
            RAISE EXCEPTION 'P06 PRE-FLIGHT: % is not SECURITY DEFINER', v_sig; END IF;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE (n.nspname, p.proname) IN (('assets','fulfill_asset_request'),('assets','return_asset'),
            ('hr','create_contract'),('hr','terminate_contract'));
    IF v_n <> 4 THEN RAISE EXCEPTION 'P06 PRE-FLIGHT: % routines match the sanctioned names, expected 4 (overload?)', v_n; END IF;

    -- 2. baseline function bodies (LF-normalised md5) = the reviewed sources (009c fulfill, P02 return)
    IF md5(replace((SELECT p.prosrc FROM pg_proc p WHERE p.oid = to_regprocedure('assets.fulfill_asset_request(uuid,uuid)')::oid), E'\r', '')) <> '566f11f01e519839d5e8ce516abb8af9' THEN
        RAISE EXCEPTION 'P06 PRE-FLIGHT: live assets.fulfill_asset_request differs from the reviewed baseline - send pg_get_functiondef and do not apply'; END IF;
    IF md5(replace((SELECT p.prosrc FROM pg_proc p WHERE p.oid = to_regprocedure('assets.return_asset(uuid)')::oid), E'\r', '')) <> '40c11c5827f0bdc9d8c2170d5da5d8e6' THEN
        RAISE EXCEPTION 'P06 PRE-FLIGHT: live assets.return_asset differs from the reviewed baseline - send pg_get_functiondef and do not apply'; END IF;

    -- 3. not already applied; enum as reviewed
    IF to_regclass('assets._sanctioned_transitions') IS NOT NULL THEN RAISE EXCEPTION 'P06 PRE-FLIGHT: assets._sanctioned_transitions already exists'; END IF;
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = 'assets.asset_status'::regtype)
       <> ARRAY['AVAILABLE','ASSIGNED','IN_REPAIR','RETIRED'] THEN RAISE EXCEPTION 'P06 PRE-FLIGHT: assets.asset_status labels differ from baseline'; END IF;

    -- 4. RLS enabled, not forced (owner-run RPCs and triggers must keep working)
    FOREACH v_rel IN ARRAY ARRAY['hr.contracts','hr.contract_versions','hr.contract_requests','assets.assets','assets.asset_assignments'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = v_rel::regclass AND relrowsecurity AND NOT relforcerowsecurity) THEN
            RAISE EXCEPTION 'P06 PRE-FLIGHT: RLS on % is not (enabled, not forced)', v_rel; END IF;
    END LOOP;

    -- 5. policy baseline: exactly these policies, exact definitions
    FOR v_exp IN SELECT * FROM (VALUES
        ('hr','contracts','contracts_manage','ALL',$q$core.has_permission(auth.uid(), 'CONTRACT_MANAGE'::text)$q$,NULL::text),
        ('hr','contract_versions','contract_versions_manage','ALL',$q$core.has_permission(auth.uid(), 'CONTRACT_MANAGE'::text)$q$,NULL::text),
        ('assets','assets','assets_manage','ALL',$q$core.has_permission(auth.uid(), 'ASSET_MANAGE'::text)$q$,NULL::text),
        ('assets','assets','assets_select','SELECT','true',NULL::text)) AS t(s,tb,pn,cm,ql,wc) LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname=v_exp.s AND tablename=v_exp.tb AND policyname=v_exp.pn
            AND cmd=v_exp.cm AND permissive='PERMISSIVE' AND roles='{public}'::name[] AND qual=v_exp.ql AND with_check IS NULL) THEN
            RAISE EXCEPTION 'P06 PRE-FLIGHT: policy %.%.% differs from reviewed baseline', v_exp.s, v_exp.tb, v_exp.pn; END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname='hr' AND tablename='contracts') <> 2
       OR (SELECT count(*) FROM pg_policies WHERE schemaname='hr' AND tablename='contract_versions') <> 2
       OR (SELECT count(*) FROM pg_policies WHERE schemaname='assets' AND tablename='assets') <> 2 THEN
        RAISE EXCEPTION 'P06 PRE-FLIGHT: unexpected extra or missing policies on contracts / contract_versions / assets'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='hr' AND tablename='contracts' AND policyname='contracts_select' AND cmd='SELECT' AND qual LIKE '%CONTRACT_MANAGE%')
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='hr' AND tablename='contract_versions' AND policyname='contract_versions_select' AND cmd='SELECT' AND qual LIKE '%CONTRACT_MANAGE%') THEN
        RAISE EXCEPTION 'P06 PRE-FLIGHT: SELECT policies must already cover CONTRACT_MANAGE holders (read access would be lost)'; END IF;

    -- 6. privilege baseline (P01 state): authenticated holds exactly SELECT/INSERT/UPDATE/DELETE
    FOREACH v_rel IN ARRAY ARRAY['hr.contracts','hr.contract_versions','assets.assets'] LOOP
        FOREACH v_priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE'] LOOP
            IF NOT has_table_privilege('authenticated', v_rel, v_priv) THEN RAISE EXCEPTION 'P06 PRE-FLIGHT: authenticated expected to hold % on %', v_priv, v_rel; END IF;
        END LOOP;
        FOREACH v_priv IN ARRAY ARRAY['TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('authenticated', v_rel, v_priv) THEN RAISE EXCEPTION 'P06 PRE-FLIGHT: authenticated unexpectedly holds % on %', v_priv, v_rel; END IF;
        END LOOP;
        FOREACH v_priv IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] LOOP
            IF has_table_privilege('anon', v_rel, v_priv) THEN RAISE EXCEPTION 'P06 PRE-FLIGHT: anon unexpectedly holds % on %', v_priv, v_rel; END IF;
            IF EXISTS (SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
                        WHERE c.oid = v_rel::regclass AND a.grantee = 0 AND a.privilege_type = v_priv) THEN
                RAISE EXCEPTION 'P06 PRE-FLIGHT: PUBLIC (ACL grantee 0) unexpectedly holds % on %', v_priv, v_rel; END IF;
        END LOOP;
    END LOOP;

    -- 7. remember function ACLs so the post-check proves CREATE OR REPLACE changed nothing
    PERFORM set_config('p06.fulfill_auth', has_function_privilege('authenticated','assets.fulfill_asset_request(uuid,uuid)','EXECUTE')::text, true);
    PERFORM set_config('p06.fulfill_anon', has_function_privilege('anon','assets.fulfill_asset_request(uuid,uuid)','EXECUTE')::text, true);
    PERFORM set_config('p06.return_auth',  has_function_privilege('authenticated','assets.return_asset(uuid)','EXECUTE')::text, true);
    PERFORM set_config('p06.return_anon',  has_function_privilege('anon','assets.return_asset(uuid)','EXECUTE')::text, true);
END;
$$;

-- ---------------- Part A: contracts RPC-only ----------------
DROP POLICY "contracts_manage"          ON "hr"."contracts";
DROP POLICY "contract_versions_manage"  ON "hr"."contract_versions";
REVOKE INSERT, UPDATE, DELETE ON TABLE "hr"."contracts"          FROM "authenticated";
REVOKE INSERT, UPDATE, DELETE ON TABLE "hr"."contract_versions"  FROM "authenticated";

-- ---------------- Part B: assets ----------------
-- B1: Assets-owned, transaction-bound sanction ledger (append-only; mirrors the P03/P04 pattern)
CREATE TABLE "assets"."_sanctioned_transitions" (
    "id"            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    "asset_id"      uuid NOT NULL,
    "to_status"     text NOT NULL CHECK ("to_status" IN ('AVAILABLE', 'ASSIGNED')),
    "txid"          bigint NOT NULL DEFAULT txid_current(),
    "authorized_by" uuid,
    "created_at"    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX "idx_assets_sanctioned_transitions_lookup" ON "assets"."_sanctioned_transitions" ("asset_id", "txid");
ALTER TABLE "assets"."_sanctioned_transitions" ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE "assets"."_sanctioned_transitions" FROM PUBLIC, "anon", "authenticated";

CREATE FUNCTION "assets"."_prevent_mutation"() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, "assets" AS $$
BEGIN
    RAISE EXCEPTION 'ASSETS_APPEND_ONLY: % on assets.% is not allowed - rows are immutable once written', TG_OP, TG_TABLE_NAME;
END;
$$;
CREATE TRIGGER "trg_assets_sanctioned_transitions_immutable"
    BEFORE UPDATE OR DELETE ON "assets"."_sanctioned_transitions"
    FOR EACH ROW EXECUTE FUNCTION "assets"."_prevent_mutation"();

-- B2: guard - entering or leaving ASSIGNED needs a sanction for (this txid, this asset, this target status)
CREATE FUNCTION "assets"."_guard_asset_status"() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, "assets" AS $$
DECLARE v_controlled boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_controlled := (NEW."current_status" = 'ASSIGNED');
    ELSE
        v_controlled := (NEW."current_status" IS DISTINCT FROM OLD."current_status"
                         AND (NEW."current_status" = 'ASSIGNED' OR OLD."current_status" = 'ASSIGNED'));
    END IF;
    IF v_controlled AND NOT EXISTS (
        SELECT 1 FROM "assets"."_sanctioned_transitions" s
         WHERE s."asset_id" = NEW."id" AND s."to_status" = NEW."current_status"::text AND s."txid" = txid_current()
    ) THEN
        RAISE EXCEPTION 'ASSETS_STATUS_CHANGE_NOT_SANCTIONED: asset % can only enter or leave ASSIGNED through fulfill_asset_request / return_asset', NEW."id";
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER "trg_assets_guard_status"
    BEFORE INSERT OR UPDATE OF "current_status" ON "assets"."assets"
    FOR EACH ROW EXECUTE FUNCTION "assets"."_guard_asset_status"();

-- B3: the two sanctioned paths (baseline bodies + sanction line; fulfill also bumps version once)
CREATE OR REPLACE FUNCTION "assets"."fulfill_asset_request"(
    "p_asset_request_id" uuid,
    "p_asset_id" uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "assets", "core", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_request "assets"."asset_requests";
    v_asset "assets"."assets";
    v_assignment_id uuid;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'ASSETS_UNAUTHENTICATED: fulfill_asset_request requires an authenticated session';
    END IF;
    IF NOT core.has_permission(v_actor, 'ASSET_MANAGE') THEN
        RAISE EXCEPTION 'ASSETS_NOT_AUTHORIZED: ASSET_MANAGE required to fulfill an asset request';
    END IF;

    SELECT * INTO v_request FROM "assets"."asset_requests" WHERE "id" = p_asset_request_id FOR UPDATE;
    IF v_request IS NULL THEN
        RAISE EXCEPTION 'ASSETS_REQUEST_NOT_FOUND: no such asset request';
    END IF;
    IF v_request."request_status" != 'APPROVED' THEN
        RAISE EXCEPTION 'ASSETS_REQUEST_NOT_APPROVED: request must be APPROVED before it can be fulfilled (currently %)', v_request."request_status";
    END IF;

    SELECT * INTO v_asset FROM "assets"."assets" WHERE "id" = p_asset_id FOR UPDATE;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'ASSETS_ASSET_NOT_FOUND: no such asset';
    END IF;
    IF v_asset."current_status" != 'AVAILABLE' THEN
        RAISE EXCEPTION 'ASSETS_ASSET_NOT_AVAILABLE: asset is not AVAILABLE (currently %)', v_asset."current_status";
    END IF;
    IF v_asset."asset_category_id" != v_request."asset_category_id" THEN
        RAISE EXCEPTION 'ASSETS_CATEGORY_MISMATCH: asset does not belong to the requested category';
    END IF;

    -- NEW: hr_employee_id carried over from the REQUEST row
    -- (v_request."hr_employee_id", resolved at submit time above), not
    -- re-resolved from the actor - the assignment belongs to the
    -- requesting employee, never to whoever fulfills it (v_actor is a
    -- different person - the ASSET_MANAGE holder handing the item
    -- over). Same "identify the employee this row is actually about,
    -- not the acting user" principle applies here as everywhere else.
    INSERT INTO "assets"."asset_assignments" ("asset_request_id", "asset_id", "employee_id", "hr_employee_id", "assigned_by")
    VALUES (p_asset_request_id, p_asset_id, v_request."employee_id", v_request."hr_employee_id", v_actor)
    RETURNING "id" INTO v_assignment_id;

    -- P06: sanction this exact transition (this transaction, this asset, target ASSIGNED).
    INSERT INTO "assets"."_sanctioned_transitions" ("asset_id", "to_status", "authorized_by")
    VALUES (p_asset_id, 'ASSIGNED', v_actor);
    -- P06: a real sanctioned state change increments the asset version exactly once.
    UPDATE "assets"."assets" SET "current_status" = 'ASSIGNED', "version" = "version" + 1 WHERE "id" = p_asset_id;
    UPDATE "assets"."asset_requests" SET "request_status" = 'FULFILLED' WHERE "id" = p_asset_request_id;

    RETURN jsonb_build_object('assignment_id', v_assignment_id, 'asset_id', p_asset_id, 'status', 'FULFILLED');
END;
$$;

CREATE OR REPLACE FUNCTION "assets"."return_asset"("p_assignment_id" uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "assets", "core", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_assignment "assets"."asset_assignments";
    v_asset "assets"."assets";
    v_returned_at timestamptz;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'ASSETS_UNAUTHENTICATED: return_asset requires an authenticated session';
    END IF;
    IF NOT core.has_permission(v_actor, 'ASSET_MANAGE') THEN
        RAISE EXCEPTION 'ASSETS_NOT_AUTHORIZED: ASSET_MANAGE required to record an asset return';
    END IF;

    SELECT * INTO v_assignment FROM "assets"."asset_assignments" WHERE "id" = p_assignment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSETS_ASSIGNMENT_NOT_FOUND: no such asset assignment';
    END IF;

    -- Idempotent replay: already returned -> report the recorded fact, change nothing.
    IF v_assignment."returned_at" IS NOT NULL THEN
        RETURN jsonb_build_object(
            'assignment_id', v_assignment."id",
            'asset_id', v_assignment."asset_id",
            'returned_at', v_assignment."returned_at",
            'status', 'RETURNED',
            'idempotent_replay', true
        );
    END IF;

    SELECT * INTO v_asset FROM "assets"."assets" WHERE "id" = v_assignment."asset_id" FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSETS_ASSET_NOT_FOUND: the assignment references a missing asset';
    END IF;
    IF v_asset."current_status" <> 'ASSIGNED' THEN
        RAISE EXCEPTION 'ASSETS_ASSET_STATE_INCONSISTENT: assignment % is open but its asset is % (expected ASSIGNED) - investigate manually', p_assignment_id, v_asset."current_status";
    END IF;
    v_returned_at := now();
    UPDATE "assets"."asset_assignments" SET "returned_at" = v_returned_at, "version" = "version" + 1 WHERE "id" = v_assignment."id";
    -- P06: sanction this exact transition (this transaction, this asset, target AVAILABLE).
    INSERT INTO "assets"."_sanctioned_transitions" ("asset_id", "to_status", "authorized_by")
    VALUES (v_assignment."asset_id", 'AVAILABLE', v_actor);
    UPDATE "assets"."assets" SET "current_status" = 'AVAILABLE', "version" = "version" + 1 WHERE "id" = v_assignment."asset_id";

    RETURN jsonb_build_object(
        'assignment_id', v_assignment."id",
        'asset_id', v_assignment."asset_id",
        'returned_at', v_returned_at,
        'status', 'RETURNED',
        'idempotent_replay', false
    );
END;
$$;

-- B4: ASSET_MANAGE keeps inventory INSERT and edit; no hard DELETE
DROP POLICY "assets_manage" ON "assets"."assets";
CREATE POLICY "assets_insert" ON "assets"."assets" AS PERMISSIVE FOR INSERT TO public
    WITH CHECK (core.has_permission(auth.uid(), 'ASSET_MANAGE'));
CREATE POLICY "assets_update" ON "assets"."assets" AS PERMISSIVE FOR UPDATE TO public
    USING (core.has_permission(auth.uid(), 'ASSET_MANAGE'))
    WITH CHECK (core.has_permission(auth.uid(), 'ASSET_MANAGE'));
REVOKE DELETE ON TABLE "assets"."assets" FROM "authenticated";

-- ---------------- Post-check (same transaction: failure rolls everything back) ----------------
DO $$
DECLARE v_priv text;
BEGIN
    FOREACH v_priv IN ARRAY ARRAY['INSERT','UPDATE','DELETE'] LOOP
        IF has_table_privilege('authenticated','hr.contracts',v_priv) OR has_table_privilege('authenticated','hr.contract_versions',v_priv) THEN
            RAISE EXCEPTION 'P06 POST-CHECK: authenticated still holds % on contracts / contract_versions', v_priv; END IF;
    END LOOP;
    IF NOT has_table_privilege('authenticated','hr.contracts','SELECT') OR NOT has_table_privilege('authenticated','hr.contract_versions','SELECT') THEN
        RAISE EXCEPTION 'P06 POST-CHECK: authenticated lost SELECT on contracts / contract_versions'; END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='hr' AND tablename IN ('contracts','contract_versions') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'P06 POST-CHECK: a non-SELECT policy remains on contracts / contract_versions'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='hr.contracts'::regclass AND tgname='trg_contracts_guard_termination' AND tgenabled <> 'D') THEN
        RAISE EXCEPTION 'P06 POST-CHECK: the P03 termination guard is missing'; END IF;
    IF has_table_privilege('authenticated','assets.assets','DELETE') THEN RAISE EXCEPTION 'P06 POST-CHECK: authenticated still holds DELETE on assets.assets'; END IF;
    IF NOT has_table_privilege('authenticated','assets.assets','INSERT') OR NOT has_table_privilege('authenticated','assets.assets','UPDATE')
       OR NOT has_table_privilege('authenticated','assets.assets','SELECT') THEN RAISE EXCEPTION 'P06 POST-CHECK: authenticated lost SELECT/INSERT/UPDATE on assets.assets'; END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname='assets' AND tablename='assets') <> 3
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='assets' AND tablename='assets' AND policyname='assets_insert' AND cmd='INSERT')
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='assets' AND tablename='assets' AND policyname='assets_update' AND cmd='UPDATE')
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='assets' AND tablename='assets' AND policyname='assets_select' AND cmd='SELECT') THEN
        RAISE EXCEPTION 'P06 POST-CHECK: assets.assets policies are not exactly insert/update/select'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='assets.assets'::regclass AND tgname='trg_assets_guard_status' AND tgenabled <> 'D') THEN
        RAISE EXCEPTION 'P06 POST-CHECK: the asset status guard trigger is missing'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid='assets._sanctioned_transitions'::regclass AND relrowsecurity)
       OR has_table_privilege('authenticated','assets._sanctioned_transitions','SELECT')
       OR has_table_privilege('authenticated','assets._sanctioned_transitions','INSERT')
       OR has_table_privilege('anon','assets._sanctioned_transitions','SELECT') THEN
        RAISE EXCEPTION 'P06 POST-CHECK: the sanction ledger is not locked down'; END IF;
    IF has_function_privilege('authenticated','assets.fulfill_asset_request(uuid,uuid)','EXECUTE')::text <> current_setting('p06.fulfill_auth')
       OR has_function_privilege('anon','assets.fulfill_asset_request(uuid,uuid)','EXECUTE')::text <> current_setting('p06.fulfill_anon')
       OR has_function_privilege('authenticated','assets.return_asset(uuid)','EXECUTE')::text <> current_setting('p06.return_auth')
       OR has_function_privilege('anon','assets.return_asset(uuid)','EXECUTE')::text <> current_setting('p06.return_anon') THEN
        RAISE EXCEPTION 'P06 POST-CHECK: EXECUTE privileges on the sanctioned asset functions changed'; END IF;
    IF position('_sanctioned_transitions' IN (SELECT p.prosrc FROM pg_proc p WHERE p.oid = to_regprocedure('assets.fulfill_asset_request(uuid,uuid)')::oid)) = 0
       OR position('_sanctioned_transitions' IN (SELECT p.prosrc FROM pg_proc p WHERE p.oid = to_regprocedure('assets.return_asset(uuid)')::oid)) = 0 THEN
        RAISE EXCEPTION 'P06 POST-CHECK: sanctioned functions do not record their sanction'; END IF;
END;
$$;

COMMIT;
-- ========================================================================
-- END P06_contracts_rpc_only_and_asset_status_guard.sql
-- ========================================================================
