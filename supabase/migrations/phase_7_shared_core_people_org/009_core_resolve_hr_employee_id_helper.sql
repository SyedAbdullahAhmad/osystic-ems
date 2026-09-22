-- ========================================================================
-- 009_core_resolve_hr_employee_id_helper.sql
-- Phase 7: shared helper used by every module's 009x cutover file below.
--
-- SCOPE DECISION, flagged explicitly rather than silently chosen: this
-- batch implements 009a-d as DUAL-WRITE, not a full authorization
-- switch. Every module's RPC keeps its exact existing auth.uid()-based
-- identity/authorization logic, completely unchanged - zero behavior
-- change, zero new failure mode. The ONLY addition is that each RPC now
-- ALSO resolves and stores hr_employee_id on every row it inserts,
-- using this helper, so newly-created data doesn't fall behind the
-- one-time historical backfill from 006 while the legacy employee_id
-- column remains the authorization source of truth.
--
-- Reasoning for deferring the full switch: making authorization depend
-- on hr.employees existing (i.e. a user with no hr.employees row yet -
-- plausible right after 003's provisioning RPC runs on signup, before
-- HR has created their employee record - being unable to submit a
-- request) is a real, new business-rule change that wasn't explicitly
-- decided by the team lead. Flipping RLS/RPC authorization to require
-- the new chain now would also remove the safety net during exactly
-- the validation window the team lead's "don't drop legacy columns
-- until validated" instruction is meant to protect. Recommending the
-- full authorization switch happen atomically WITH 011 (the same
-- moment the legacy column is dropped) instead - that is a sequencing
-- refinement to the original plan, surfaced here for confirmation, not
-- decided unilaterally.
--
-- If hr_employee_id resolves to NULL here (no hr.employees row yet for
-- this person), every 009x RPC below allows the insert to proceed with
-- hr_employee_id left NULL - this is intentional and matches the
-- column being nullable; it does NOT block the legacy-path request.
-- ========================================================================

CREATE OR REPLACE FUNCTION "core"."resolve_hr_employee_id"("p_user_id" uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog, "core", "hr"
AS $$
    SELECT "e"."id"
    FROM "core"."person_user_links" "pul"
    JOIN "hr"."employees" "e" ON "e"."person_id" = "pul"."person_id"
    WHERE "pul"."user_id" = p_user_id AND "pul"."status" = 'ACTIVE'
    LIMIT 1;
$$;

-- Internal helper only - called from inside each module's SECURITY
-- DEFINER RPC (which runs under the function owner's privileges, so no
-- separate EXECUTE grant to authenticated is needed here). Not exposed
-- to PUBLIC directly.
REVOKE ALL ON FUNCTION "core"."resolve_hr_employee_id"(uuid) FROM PUBLIC;

-- ========================================================================
-- END 009_core_resolve_hr_employee_id_helper.sql
-- ========================================================================
