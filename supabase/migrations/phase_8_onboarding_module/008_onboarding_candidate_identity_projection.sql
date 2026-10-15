-- ========================================================================
-- 008_onboarding_candidate_identity_projection.sql
--
-- PURPOSE (team-lead decision, Option A, round 8): the Onboarding UI needs
-- the candidate's name and email, which live in core.people. Users who
-- hold ONBOARDING_MANAGE or ONBOARDING_VIEW_ALL but not PEOPLE_MANAGE
-- cannot read core.people, so they saw "Candidate d843d6ef". This adds a
-- small READ-ONLY, onboarding-owned function that returns the minimum
-- identity fields for onboarding records the caller is ALREADY allowed to
-- see. It does NOT widen core.people RLS or grants in any way, and it
-- does not touch 001-007.
--
-- WHAT IT RETURNS (and nothing else): onboarding_record_id, person_id,
-- full_name, email.
--
-- WHO SEES WHAT - deliberately the exact same rule as the
-- onboarding_records_select policy in 002 (permission-based, no role
-- names, so being a "Technical Admin" grants nothing by itself):
--   * ONBOARDING_MANAGE   -> identity for every onboarding record
--   * ONBOARDING_VIEW_ALL -> identity for every onboarding record
--   * candidate/self      -> identity only for the record whose person
--                            has an ACTIVE core.person_user_links row for
--                            auth.uid()
--   * anyone else         -> zero rows
--
-- SECURITY DEFINER (needed because the caller cannot read core.people):
--   * actor derived from auth.uid(); no actor parameter exists
--   * search_path pinned
--   * visibility is verified explicitly in the query's WHERE clause
--     BEFORE any identity field is returned
--   * REVOKE ALL FROM PUBLIC, GRANT EXECUTE only to "authenticated"
--   * STABLE and contains no write statement
--
-- p_onboarding_record_ids: NULL = every record the caller may see;
-- otherwise restrict to those ids (ids the caller may not see are simply
-- absent from the result - never an error that confirms they exist).
--
-- Every column reference below is table-aliased on purpose: the function's
-- own RETURNS TABLE (...) columns are implicit PL/pgSQL variables, and an
-- unqualified person_id / full_name / email collides with them ("column
-- reference ... is ambiguous") - the same trap core.provision_person_for_user
-- hit in the shared-core phase.
--
-- Rollback: 008_onboarding_candidate_identity_projection_ROLLBACK.sql (run
-- FIRST in the canonical order: 008, 007, 006, 004, 005, 003, 002, 001).
-- ========================================================================

CREATE OR REPLACE FUNCTION "onboarding"."get_candidate_identities"(
    "p_onboarding_record_ids" uuid[] DEFAULT NULL
)
RETURNS TABLE (
    "onboarding_record_id" uuid,
    "person_id" uuid,
    "full_name" text,
    "email" text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, "onboarding", "core", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_can_see_all boolean;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_UNAUTHENTICATED: get_candidate_identities requires an authenticated session';
    END IF;

    v_can_see_all := core.has_permission(v_actor, 'ONBOARDING_MANAGE')
                  OR core.has_permission(v_actor, 'ONBOARDING_VIEW_ALL');

    RETURN QUERY
    SELECT o."id", o."person_id", p."full_name"::text, p."primary_email"::text
    FROM "onboarding"."onboarding_records" o
    JOIN "core"."people" p ON p."id" = o."person_id"
    WHERE (p_onboarding_record_ids IS NULL OR o."id" = ANY(p_onboarding_record_ids))
      AND (
            v_can_see_all
            OR o."person_id" IN (
                SELECT pul."person_id"
                FROM "core"."person_user_links" pul
                WHERE pul."user_id" = v_actor AND pul."status" = 'ACTIVE'
            )
          );
END;
$$;

REVOKE ALL ON FUNCTION "onboarding"."get_candidate_identities"(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "onboarding"."get_candidate_identities"(uuid[]) TO "authenticated";

-- ========================================================================
-- END 008_onboarding_candidate_identity_projection.sql
-- ========================================================================
