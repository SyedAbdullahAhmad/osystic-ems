-- ========================================================================
-- P06_contracts_rpc_only_and_asset_status_guard_ROLLBACK.sql
-- Restores the pre-P06 state EXACTLY: the two ALL policies (PERMISSIVE, TO public, exact
-- expression), INSERT/UPDATE/DELETE on contracts/contract_versions and DELETE on
-- assets.assets back to authenticated only, the baseline function bodies (verified by
-- hash), and removes the guard, the ledger and the new policies.
-- RE-OPENS the contract and asset-status bypasses; for Track A reversibility only.
-- NOTE: dropping the ledger discards the fulfil/return sanction rows recorded since P06
-- (the assignment tables keep the business record).
-- ========================================================================
BEGIN;

DO $$
BEGIN
    IF to_regclass('assets._sanctioned_transitions') IS NULL THEN RAISE EXCEPTION 'P06 ROLLBACK PRE-FLIGHT: P06 does not appear to be applied'; END IF;
    IF has_table_privilege('authenticated','hr.contracts','INSERT') OR has_table_privilege('authenticated','hr.contract_versions','UPDATE')
       OR has_table_privilege('authenticated','assets.assets','DELETE') THEN
        RAISE EXCEPTION 'P06 ROLLBACK PRE-FLIGHT: write privileges are already present'; END IF;
END;
$$;

DROP TRIGGER "trg_assets_guard_status" ON "assets"."assets";
DROP FUNCTION "assets"."_guard_asset_status"();
DROP TRIGGER "trg_assets_sanctioned_transitions_immutable" ON "assets"."_sanctioned_transitions";
DROP TABLE "assets"."_sanctioned_transitions";
DROP FUNCTION "assets"."_prevent_mutation"();

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

    UPDATE "assets"."assets" SET "current_status" = 'ASSIGNED' WHERE "id" = p_asset_id;
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

DROP POLICY "assets_insert" ON "assets"."assets";
DROP POLICY "assets_update" ON "assets"."assets";
CREATE POLICY "assets_manage" ON "assets"."assets" AS PERMISSIVE FOR ALL TO public
    USING (core.has_permission(auth.uid(), 'ASSET_MANAGE'::text));
CREATE POLICY "contracts_manage" ON "hr"."contracts" AS PERMISSIVE FOR ALL TO public
    USING (core.has_permission(auth.uid(), 'CONTRACT_MANAGE'::text));
CREATE POLICY "contract_versions_manage" ON "hr"."contract_versions" AS PERMISSIVE FOR ALL TO public
    USING (core.has_permission(auth.uid(), 'CONTRACT_MANAGE'::text));
GRANT INSERT, UPDATE, DELETE ON TABLE "hr"."contracts"          TO "authenticated";
GRANT INSERT, UPDATE, DELETE ON TABLE "hr"."contract_versions"  TO "authenticated";
GRANT DELETE ON TABLE "assets"."assets" TO "authenticated";

DO $$
DECLARE v_exp record; v_priv text;
BEGIN
    FOR v_exp IN SELECT * FROM (VALUES
        ('hr','contracts','contracts_manage','ALL',$q$core.has_permission(auth.uid(), 'CONTRACT_MANAGE'::text)$q$),
        ('hr','contract_versions','contract_versions_manage','ALL',$q$core.has_permission(auth.uid(), 'CONTRACT_MANAGE'::text)$q$),
        ('assets','assets','assets_manage','ALL',$q$core.has_permission(auth.uid(), 'ASSET_MANAGE'::text)$q$),
        ('assets','assets','assets_select','SELECT','true')) AS t(s,tb,pn,cm,ql) LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname=v_exp.s AND tablename=v_exp.tb AND policyname=v_exp.pn
            AND cmd=v_exp.cm AND permissive='PERMISSIVE' AND roles='{public}'::name[] AND qual=v_exp.ql AND with_check IS NULL) THEN
            RAISE EXCEPTION 'P06 ROLLBACK POST-CHECK: policy %.%.% not restored exactly', v_exp.s, v_exp.tb, v_exp.pn; END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname='hr' AND tablename='contracts') <> 2
       OR (SELECT count(*) FROM pg_policies WHERE schemaname='hr' AND tablename='contract_versions') <> 2
       OR (SELECT count(*) FROM pg_policies WHERE schemaname='assets' AND tablename='assets') <> 2 THEN
        RAISE EXCEPTION 'P06 ROLLBACK POST-CHECK: policy counts differ from the pre-P06 baseline'; END IF;
    FOREACH v_priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE'] LOOP
        IF NOT has_table_privilege('authenticated','hr.contracts',v_priv) OR NOT has_table_privilege('authenticated','hr.contract_versions',v_priv)
           OR NOT has_table_privilege('authenticated','assets.assets',v_priv) THEN
            RAISE EXCEPTION 'P06 ROLLBACK POST-CHECK: authenticated missing % on a restored table', v_priv; END IF;
    END LOOP;
    FOREACH v_priv IN ARRAY ARRAY['TRUNCATE','TRIGGER','REFERENCES'] LOOP
        IF has_table_privilege('authenticated','hr.contracts',v_priv) OR has_table_privilege('authenticated','hr.contract_versions',v_priv)
           OR has_table_privilege('authenticated','assets.assets',v_priv) THEN
            RAISE EXCEPTION 'P06 ROLLBACK POST-CHECK: authenticated holds % (not in baseline)', v_priv; END IF;
    END LOOP;
    IF has_table_privilege('anon','hr.contracts','INSERT') OR has_table_privilege('anon','assets.assets','DELETE') THEN
        RAISE EXCEPTION 'P06 ROLLBACK POST-CHECK: anon holds a write privilege (must not)'; END IF;
    IF md5(replace((SELECT p.prosrc FROM pg_proc p WHERE p.oid = to_regprocedure('assets.fulfill_asset_request(uuid,uuid)')::oid), E'\r', '')) <> '566f11f01e519839d5e8ce516abb8af9'
       OR md5(replace((SELECT p.prosrc FROM pg_proc p WHERE p.oid = to_regprocedure('assets.return_asset(uuid)')::oid), E'\r', '')) <> '40c11c5827f0bdc9d8c2170d5da5d8e6' THEN
        RAISE EXCEPTION 'P06 ROLLBACK POST-CHECK: function bodies are not the exact pre-P06 baseline'; END IF;
    RAISE NOTICE 'P06 ROLLBACK POST-CHECK PASSED: policies, privileges and function bodies equal the pre-P06 baseline';
END;
$$;

COMMIT;
-- ========================================================================
-- END P06_contracts_rpc_only_and_asset_status_guard_ROLLBACK.sql
-- ========================================================================
