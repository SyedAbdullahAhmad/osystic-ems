-- ========================================================================
-- 003_provision_person_for_user.sql
-- Phase 7: Shared-Core People/Organization Model - provisioning RPC
--
-- core.provision_person_for_user() - called client-side immediately
-- after supabase.auth.signUp() resolves (per proposal v2 S4: simpler
-- and more debuggable than a raw auth.users trigger, consistent with
-- this project's existing pattern of explicit RPCs over implicit
-- triggers where a choice exists).
--
-- HARDENING - every point below is a direct response to Umar's
-- safeguard #2 and the team lead's review-reply rules, not
-- discretionary:
--   1. user_id is taken from auth.uid() inside the function, NEVER
--      from a caller-supplied argument - the function takes NO
--      parameters at all. A caller can only ever provision/link
--      themselves; there is no argument surface to pass someone
--      else's identity through.
--   2. search_path is explicitly pinned (SET search_path = core,
--      pg_temp) - a SECURITY DEFINER function with an unpinned
--      search_path is a classic privilege-escalation vector (a caller
--      could otherwise shadow an unqualified function/table name from
--      a schema earlier in their own search_path).
--   3. EXECUTE is granted only to authenticated, never to anon - an
--      unauthenticated caller has no auth.uid() to provision anyway,
--      but the grant itself is scoped defensively regardless.
--   4. Verified-email matching gate: the caller's OWN
--      email_confirmed_at must be non-null before ANY match-by-email
--      is attempted, and this ONLY applies to matching a DIFFERENT
--      login to someone else's existing person record. An unconfirmed
--      email must never be used to attach a session to a pre-existing
--      person record - otherwise anyone could sign up with an address
--      they don't control yet and immediately inherit that person's
--      historical data.
--   5. Reject linking to an already-ACTIVE-linked person outright,
--      with a clear exception - never silently create a duplicate
--      link, never silently re-point an existing employee's identity
--      to a new login.
--   6. Explicit REVOKED-link reactivation for the approved
--      rehire/relink decision (same core.people record reused,
--      confirmed by the team lead), split into two genuinely different
--      cases (revised after 010's Check 4 exposed the original version
--      collapsing them into one, email-dependent path - see below):
--        a) SAME login (same auth.users.id) reconnecting - checked
--           FIRST, directly by user_id, independent of email
--           confirmation entirely. This doesn't need email as a trust
--           mechanism at all: the exact auth.users.id itself, via the
--           person_user_links foreign key, IS the identity fact - it
--           is not "matching to someone else's identity" the way an
--           email string is, so gating it behind email verification
--           was unnecessary and, as discovered live, actively broke
--           this exact case whenever the account's email happened to
--           be unconfirmed (falls through to "create new", which then
--           collides with that person's own still-unique email).
--        b) DIFFERENT login (rehired under a new account) reconnecting
--           to their old person record - this one legitimately still
--           needs the verified-email gate from point 4, since it IS
--           matching to a person via an external, spoofable signal.
-- ========================================================================

CREATE OR REPLACE FUNCTION "core"."provision_person_for_user"()
RETURNS TABLE ("person_id" uuid, "action_taken" text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = "core", pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_caller_email text;
    v_email_confirmed boolean;
    v_organization_id uuid;
    v_matched_person_id uuid;
    v_active_link_exists boolean;
    v_new_person_id uuid;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'PROVISION_REQUIRES_AUTHENTICATED_SESSION: core.provision_person_for_user requires an authenticated session';
    END IF;

    -- If this user_id already has an ACTIVE link, this is a no-op
    -- re-call (e.g. the client retries after a network blip) - return
    -- the existing link, do not attempt anything else.
    --
    -- NOTE: every reference to person_id in this function's queries
    -- below is table-aliased ("pul"."person_id", not bare "person_id")
    -- - this function's own RETURNS TABLE ("person_id" uuid, ...)
    -- clause implicitly declares a PL/pgSQL variable named person_id in
    -- scope, which collides with the literal column name otherwise
    -- ("column reference person_id is ambiguous"). Discovered on first
    -- live exercise of this function via 010's Check 4 test.
    SELECT pul."person_id" INTO v_matched_person_id
    FROM "core"."person_user_links" pul
    WHERE pul."user_id" = v_user_id AND pul."status" = 'ACTIVE';

    IF v_matched_person_id IS NOT NULL THEN
        RETURN QUERY SELECT v_matched_person_id, 'ALREADY_LINKED'::text;
        RETURN;
    END IF;

    -- Hardening point #6a (revised): SAME-login reactivation, checked
    -- directly by this exact user_id, BEFORE any email logic runs at
    -- all. If this exact login has a REVOKED link on record, reconnect
    -- it - no email verification needed for this branch, since it's
    -- not matching an external signal to a person, it's recognizing
    -- this login's own prior link.
    SELECT pul."person_id" INTO v_matched_person_id
    FROM "core"."person_user_links" pul
    WHERE pul."user_id" = v_user_id AND pul."status" = 'REVOKED'
    ORDER BY pul."linked_at" DESC
    LIMIT 1;

    IF v_matched_person_id IS NOT NULL THEN
        UPDATE "core"."person_user_links" pul
        SET "status" = 'ACTIVE', "linked_at" = now()
        WHERE pul."person_id" = v_matched_person_id AND pul."user_id" = v_user_id AND pul."status" = 'REVOKED';

        RETURN QUERY SELECT v_matched_person_id, 'REACTIVATED_SAME_LOGIN'::text;
        RETURN;
    END IF;

    SELECT "email", "email_confirmed_at" IS NOT NULL
    INTO v_caller_email, v_email_confirmed
    FROM "auth"."users"
    WHERE "id" = v_user_id;

    SELECT "id" INTO v_organization_id
    FROM "core"."organizations"
    WHERE "code" = 'OSYSTIC';

    IF v_organization_id IS NULL THEN
        RAISE EXCEPTION 'PROVISION_OSYSTIC_ORG_MISSING: seeded OSYSTIC organization row not found - check 001_shared_core_schema.sql was applied';
    END IF;

    v_matched_person_id := NULL;

    -- Verified-email matching gate (hardening point #4) - this is now
    -- ONLY reached for a login with no ACTIVE and no REVOKED link of
    -- its own (handled above) - i.e. either a genuinely brand-new
    -- login, or a DIFFERENT login rehired under a new account trying
    -- to reconnect to an old person record. Only look for an existing
    -- person record to match/reuse if the caller's own email is
    -- actually confirmed.
    IF v_email_confirmed AND v_caller_email IS NOT NULL THEN
        SELECT "id" INTO v_matched_person_id
        FROM "core"."people"
        WHERE lower("primary_email") = lower(v_caller_email);
    END IF;

    IF v_matched_person_id IS NULL THEN
        -- No match (or email unverified) - create a brand new person +
        -- link. Today's ordinary signup case.
        --
        -- full_name placeholder: NOT NULL per v2 S2, but nothing at
        -- signup time actually supplies a real name yet (bare
        -- supabase.auth.signUp() today, no name field). Falling back
        -- to the email as a temporary placeholder, NOT silently
        -- inventing a name - v2 S7 already recommends a manual HR
        -- data-entry pass for full_name; this is that same gap,
        -- flagged here rather than hidden by a fabricated value.
        INSERT INTO "core"."people" ("organization_id", "full_name", "primary_email", "person_type", "status")
        VALUES (v_organization_id, COALESCE(v_caller_email, 'Unnamed'), v_caller_email, 'EMPLOYEE', 'ACTIVE')
        RETURNING "id" INTO v_new_person_id;

        INSERT INTO "core"."person_user_links" ("person_id", "user_id", "status")
        VALUES (v_new_person_id, v_user_id, 'ACTIVE');

        RETURN QUERY SELECT v_new_person_id, 'CREATED_NEW_PERSON'::text;
        RETURN;
    END IF;

    -- Matched an existing person record by verified email (a DIFFERENT
    -- login than v_user_id - same-login was already handled above).
    -- Check whether that person already has an ACTIVE link (hardening
    -- point #5) - checked explicitly here, not left to the unique-
    -- index violation, so the caller gets a clean, specific error.
    SELECT EXISTS (
        SELECT 1 FROM "core"."person_user_links" pul
        WHERE pul."person_id" = v_matched_person_id AND pul."status" = 'ACTIVE'
    ) INTO v_active_link_exists;

    IF v_active_link_exists THEN
        RAISE EXCEPTION 'PROVISION_PERSON_ALREADY_ACTIVELY_LINKED: person % already has an active link to a different account', v_matched_person_id;
    END IF;

    -- Hardening point #6b: DIFFERENT-login rehire matched by verified
    -- email - either no prior link row at all on this person (an
    -- HR-created CANDIDATE person signing in for the first time - the
    -- Onboarding case from proposal v2 S4), or a REVOKED link that
    -- belonged to a different login entirely (rehired under a new
    -- email) - either way, insert a new ACTIVE link row pointing at
    -- the SAME existing person_id. Never create a duplicate
    -- core.people row for a matched person.
    INSERT INTO "core"."person_user_links" ("person_id", "user_id", "status")
    VALUES (v_matched_person_id, v_user_id, 'ACTIVE');

    RETURN QUERY SELECT v_matched_person_id, 'LINKED_EXISTING_PERSON'::text;
END;
$$;

REVOKE ALL ON FUNCTION "core"."provision_person_for_user"() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "core"."provision_person_for_user"() TO "authenticated";

-- ========================================================================
-- END 003_provision_person_for_user.sql
-- ========================================================================
