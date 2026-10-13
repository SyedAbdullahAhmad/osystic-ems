-- ========================================================================
-- 007_withdraw_onboarding_request.sql  (NEW - item 2 in Arslan's review)
--
-- The ONLY permitted path to WITHDRAWN (002's RLS WITH CHECK blocks a
-- raw UPDATE from reaching it, same principle as HIRED being reachable
-- only via confirm_employee_hire() in 006). Does the three things a
-- raw UPDATE structurally cannot do together: (a) validate who's
-- actually allowed to withdraw THIS record, (b) close the associated
-- workflow request if one is still open, so it can never later be
-- approved out from under an already-withdrawn candidate, and
-- (c) record who withdrew it, when, and why.
--
-- CHANGES IN THIS REVISION (round 5):
--   - Item 3: workflow_cancelled on the idempotent-replay path is now
--     derived from current_status = 'CANCELLED', not from is_open
--     alone - an APPROVED (and therefore already-closed) request was
--     being misreported as cancelled on replay even though this
--     function never actually cancelled it for that path.
--   - Item 4: withdrawn_at/withdrawn_by are now returned on BOTH paths
--     (previously only on replay), computed once as v_withdrawn_at and
--     used identically for the write and the response.
--
-- AUTHORITY: either an ONBOARDING_MANAGE holder (HR withdrawing on
-- someone's behalf), or the candidate themselves, once linked via an
-- ACTIVE core.person_user_links row - Arslan's review explicitly names
-- "the acting user/candidate authority" as something to validate, not
-- just HR.
--
-- CALLING A service_role-ONLY FUNCTION FROM A SECURITY DEFINER WRAPPER:
-- workflow.process_system_action() is REVOKEd from PUBLIC and
-- "authenticated", granted only to "service_role". This function calls
-- it anyway, the same way EVERY existing module's create-and-submit RPC
-- (e.g. 003 here, and the equivalent in Leave/Attendance/Assets/
-- Contracts) already calls workflow.start_approval_request() - which
-- is REVOKEd from "authenticated" in exactly the same way. That's not
-- a new assumption introduced here: it's the same chaining pattern this
-- entire project already relies on everywhere, and Assets/Contracts
-- have both been confirmed working end-to-end through the real UI,
-- which empirically proves the pattern works (a SECURITY DEFINER
-- function's privilege checks resolve against its OWNER, not its
-- caller, and every function in this project shares the same owner -
-- so once inside one SECURITY DEFINER function, calling another
-- privilege-restricted one succeeds). Flagged explicitly here anyway,
-- since this is the first time a module calls process_system_action
-- specifically (CANCEL is new to this module) rather than
-- start_approval_request/process_approval_action - worth confirming
-- with a real test run rather than assuming, same as everything else
-- in this package.
-- ========================================================================

CREATE OR REPLACE FUNCTION "onboarding"."withdraw_onboarding_request"(
    "p_onboarding_record_id" uuid,
    "p_reason" text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, "onboarding", "core", "workflow", "auth"
AS $$
DECLARE
    v_actor uuid := auth.uid();
    v_record "onboarding"."onboarding_records";
    v_is_hr boolean;
    v_is_candidate boolean;
    v_request "workflow"."approval_requests";
    v_cancel_key varchar(255);
    v_workflow_cancelled boolean := false;
    v_reason text;
    v_withdrawn_at timestamptz;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_UNAUTHENTICATED: withdraw_onboarding_request requires an authenticated session';
    END IF;

    SELECT * INTO v_record FROM "onboarding"."onboarding_records" WHERE "id" = p_onboarding_record_id FOR UPDATE;
    IF v_record IS NULL THEN
        RAISE EXCEPTION 'ONBOARDING_RECORD_NOT_FOUND: no such onboarding record';
    END IF;

    -- Authority check (see header). Evaluated before the idempotent/
    -- status checks below, so an unauthorized caller gets a clear
    -- authorization error even on a record that's already WITHDRAWN,
    -- rather than an unauthorized caller being able to tell the
    -- difference between "doesn't exist" and "already withdrawn" for a
    -- record they have no business looking at.
    v_is_hr := core.has_permission(v_actor, 'ONBOARDING_MANAGE');
    v_is_candidate := EXISTS (
        SELECT 1 FROM "core"."person_user_links"
        WHERE "person_id" = v_record."person_id" AND "user_id" = v_actor AND "status" = 'ACTIVE'
    );

    IF NOT (v_is_hr OR v_is_candidate) THEN
        RAISE EXCEPTION 'ONBOARDING_NOT_AUTHORIZED: ONBOARDING_MANAGE, or being the linked candidate on this record, is required to withdraw it';
    END IF;

    IF v_record."status" = 'HIRED' THEN
        RAISE EXCEPTION 'ONBOARDING_ALREADY_HIRED: record % is already HIRED - a hired record can never be withdrawn', p_onboarding_record_id;
    END IF;

    -- Idempotent: a record that's already WITHDRAWN returns the
    -- original outcome as-is - no new writes, no error. Live-checks
    -- whether the workflow request is (still) closed rather than just
    -- trusting workflow_request_id IS NOT NULL, so a genuinely odd
    -- state is reported accurately rather than assumed.
    IF v_record."status" = 'WITHDRAWN' THEN
        IF v_record."workflow_request_id" IS NOT NULL THEN
            -- Item 3 (round 5): "is_open = false" is NOT the same thing
            -- as "cancelled" - an APPROVED-then-withdrawn record's
            -- workflow request is closed (is_open=false) because it was
            -- APPROVED, not because anything cancelled it; this RPC
            -- never calls process_system_action for that case (see the
            -- fresh-withdrawal path below, which only sets
            -- v_workflow_cancelled := true when it actually performs
            -- the CANCEL). The old `NOT is_open` check conflated the
            -- two and reported workflow_cancelled=true on replay even
            -- for an APPROVED-path withdrawal, where it should be
            -- false. The correct signal is the workflow's own recorded
            -- outcome.
            SELECT ("current_status" = 'CANCELLED') INTO v_workflow_cancelled
            FROM "workflow"."approval_requests" WHERE "id" = v_record."workflow_request_id";
        END IF;

        RETURN jsonb_build_object(
            'onboarding_record_id', v_record."id",
            'person_id', v_record."person_id",
            'status', 'WITHDRAWN',
            'withdrawn_at', v_record."withdrawn_at",
            'withdrawn_by', v_record."withdrawn_by",
            -- Item 6 (round 4): was missing here - the fresh-withdrawal
            -- path always returned it, so the same RPC had an
            -- inconsistent response shape depending on which branch
            -- answered. Both now return it.
            'withdrawal_reason', v_record."withdrawal_reason",
            'workflow_cancelled', COALESCE(v_workflow_cancelled, false),
            'idempotent_replay', true
        );
    END IF;

    IF v_record."status" NOT IN ('SUBMITTED', 'APPROVED') THEN
        RAISE EXCEPTION 'ONBOARDING_INVALID_WITHDRAW_STATUS: only a SUBMITTED or APPROVED record can be withdrawn (currently %)', v_record."status";
    END IF;

    -- Item 7 (round 3): normalize ONCE, use the SAME value everywhere -
    -- previously the workflow cancel comment fell back to a default
    -- string when p_reason was NULL/blank, but onboarding_records.
    -- withdrawal_reason stored the raw (possibly NULL) p_reason
    -- directly, so the two could disagree. A blank string ('   ') is
    -- treated the same as NULL (NULLIF after btrim), not stored as
    -- empty-but-technically-non-null.
    v_reason := COALESCE(NULLIF(btrim(p_reason), ''), 'Onboarding request withdrawn');

    -- Close the associated workflow request FIRST, while the record is
    -- still locked (FOR UPDATE above) and still in its pre-withdrawal
    -- status - if the cancel call fails for any reason, the whole
    -- transaction rolls back and the record is never left half-
    -- withdrawn with its workflow request still open underneath it.
    IF v_record."workflow_request_id" IS NOT NULL THEN
        SELECT * INTO v_request FROM "workflow"."approval_requests" WHERE "id" = v_record."workflow_request_id" FOR UPDATE;

        -- EXECUTION FINDING (round 7): "v_request IS NOT NULL" is TRUE only if
        -- EVERY column is non-null, and approval_requests.organization_id
        -- is always NULL today (known shared-engine limitation) - so the
        -- old check was always FALSE and the workflow CANCEL never fired.
        IF v_request."id" IS NOT NULL AND v_request."is_open" THEN
            -- Deterministic per-record key: a retry of this same
            -- withdrawal naturally reuses it, which is exactly the
            -- idempotency workflow.process_system_action's own
            -- idempotency-key mechanism expects - and a record can only
            -- ever be withdrawn once anyway (status becomes terminal),
            -- so there is no legitimate case where this key needs to
            -- differ across calls for the same record.
            v_cancel_key := 'onboarding-withdraw-' || v_record."id"::text;

            PERFORM "workflow"."process_system_action"(
                v_record."workflow_request_id",
                'CANCEL',
                NULL,
                v_reason,
                jsonb_build_object('withdrawn_by', v_actor, 'onboarding_record_id', v_record."id"),
                v_cancel_key,
                v_request."version"
            );
            v_workflow_cancelled := true;
        END IF;
    END IF;

    -- Item 4 (round 5): one captured value, used for both the write and
    -- the response below - rather than calling now() independently in
    -- each place (which could theoretically disagree by a few
    -- microseconds and, more importantly, previously wasn't even
    -- returned in the response at all on this path).
    v_withdrawn_at := now();

    UPDATE "onboarding"."onboarding_records"
    SET "status" = 'WITHDRAWN',
        "withdrawn_at" = v_withdrawn_at,
        "withdrawn_by" = v_actor,
        "withdrawal_reason" = v_reason
    WHERE "id" = p_onboarding_record_id;

    RETURN jsonb_build_object(
        'onboarding_record_id', p_onboarding_record_id,
        'person_id', v_record."person_id",
        'status', 'WITHDRAWN',
        'withdrawn_at', v_withdrawn_at,
        'withdrawn_by', v_actor,
        'withdrawal_reason', v_reason,
        'workflow_cancelled', v_workflow_cancelled,
        'idempotent_replay', false
    );
END;
$$;

REVOKE ALL ON FUNCTION "onboarding"."withdraw_onboarding_request"(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION "onboarding"."withdraw_onboarding_request"(uuid, text) TO "authenticated";

-- ========================================================================
-- END 007_withdraw_onboarding_request.sql
-- ========================================================================
