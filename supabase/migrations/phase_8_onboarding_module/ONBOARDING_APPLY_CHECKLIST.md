# Onboarding Module — Apply Checklist  (v8 + migration 008 — per Shawaiz's round-7 and round-8 decisions)

Same discipline as every prior module: backup → pre-apply snapshot →
apply one file at a time → post-apply regression check → bootstrap →
end-to-end proof → rollback → verify → re-apply, with real evidence
pasted back at each step. **Rounds 6–7 split the rollback/proof portion into TWO separate
environments (Track A: reversibility, Track B: functional) — see Step 7.**

Design reference: `ONBOARDING_MODULE_PROPOSAL_v2.md`. Rounds 1–6's
corrections are mapped item-by-item in `FIXES_SUMMARY.md`; nothing here
re-opens the architecture. Note: item NUMBERS reset each round (they
follow Arslan's own numbered list in each review) — "item 1" means a
different thing in different rounds. Headings below are always suffixed
with the round to avoid ambiguity.

## ROUND 8 ADDITION: migration 008 (candidate identity projection)

Approved by the team lead (Option A): `onboarding.get_candidate_identities(uuid[])`,
a read-only SECURITY DEFINER function returning only
`onboarding_record_id, person_id, full_name, email` for onboarding records
the caller can already see (same rule as the `onboarding_records_select`
policy: ONBOARDING_MANAGE, ONBOARDING_VIEW_ALL, or the linked candidate).
`core.people` RLS and grants are unchanged. Apply it after `007`; its
rollback is the FIRST file in the rollback order; Track A therefore
becomes: apply `001`–`008`, no seed, roll back `008 → 007 → 006 → 004 → 005
→ 003 → 002 → 001`, verify exact state, re-apply. Track B adds
`TEST_onboarding_008_identity_projection.sql` (run after the main suite;
needs the candidate account linked).

## CHANGES IN THIS REVISION (round 7 — Shawaiz's Option 1 decision)

Triggered by a real execution finding: running the `004` rollback in the
seeded scratch database failed with
`WORKFLOW_VERSION_IMMUTABLE: cannot DELETE workflow_step_assignees for a
step belonging to an ACTIVE or RETIRED workflow version`. Decision:
**Option 1 — separate the two proofs; no shared-engine change.**

- **`004` rollback rewritten.** Two explicit cases: (1) seed function
  installed but never invoked → rollback drops the function; (2) workflow
  version already ACTIVE/RETIRED → rollback **fails fast** with
  `ONBOARDING_ROLLBACK_BLOCKED_ACTIVE_WORKFLOW` before deleting anything.
  Its header no longer claims there is no delete-blocking trigger — the
  triggers come from `phase_2_workflow_engine/005_workflow_rls_grants.sql`
  (the earlier check only read `004_workflow_functions_triggers.sql`).
- **Track A no longer seeds the workflow** (it did in v6/v7, which could
  never work). Track A = fresh DB, apply `001`–`007`, no seed, no tests,
  roll back, verify, re-apply.
- **Track B** = the seeded scratch DB: functional/security suite,
  concurrency test, regressions. Never rolled back.
- **Step 7a (new):** recovery procedure for the scratch DB where `007`
  and `006` were already rolled back and the `004` rollback failed.
- **Step 8 (new):** execution report template with two separate
  sections (Migration Reversibility Evidence / Functional Execution
  Evidence) and the verbatim shared-engine characteristic statement.
- No migration code in `001`–`003`, `005`–`007` changed.

## CHANGES IN ROUND 6 (for reference)

> **Superseded in part by round 7:** round 6's Track A said to seed the
> workflow before rolling back. That cannot work (an activated workflow
> is immutable). Track A now never seeds. Everything else below stands.

- **Item 1 (the big one, this round): Step 7 is a full rewrite, not a
  patch.** The previous cleanup instructions told the operator to
  delete `workflow.approval_actions`/`status_history` rows — confirmed
  by reading the actual trigger code that this is impossible, not
  merely risky (both tables are unconditionally append-only by
  design). Replaced with a two-track strategy: prove the migration
  rollback in an environment with zero workflow runtime history
  (Track A), keep the end-to-end functional proof entirely separate
  (Track B) and never attempt rollback there.
- **Item 2: the third test account must now be verified as genuinely
  non-privileged** — `TEST_onboarding_full_flow.sql`'s SECTION 0 now
  checks it holds neither `ONBOARDING_MANAGE` nor `PEOPLE_MANAGE`
  (the latter is what Section 9's tests actually depend on).
- **Item 3: `_onboarding_test_setup_grants` is now run-scoped** with a
  `run_id`, and Step 3 refuses to start while a previous run's
  unresolved rows are still present — a crashed prior run can no longer
  cause a later run's cleanup to revoke a grant it didn't create.
- **Item 4: Step 5a now requires explicit before/after row-count
  evidence** (not just "it looked right") proving serialization
  actually protected pre-person-creation side effects.
- **Item 5: new Step 6a** — the `organization_id = NULL` shared-engine
  limitation must be copied verbatim into the execution report as a
  recorded known limitation, not left implicit in code comments.

## CHANGES IN ROUND 5 (for reference)

- **Item 1: the test harness's own TEMP
  tables weren't accessible after `SET ROLE "authenticated"`.** A real
  execution blocker — Postgres checks privileges against the CURRENT
  role, and `authenticated` doesn't inherit ownership of a temp table
  the original privileged session created. Fixed with explicit
  `GRANT SELECT`/`INSERT` statements on all three right after they're
  created, before Section 0 even runs.
- **Item 2: `create_and_submit_onboarding_request()`'s idempotency
  check is now race-free under concurrent identical requests** — a
  transaction-scoped `pg_advisory_xact_lock` serializes callers with the
  same key before the lookup, so a genuine concurrent duplicate now
  waits and returns the original result instead of racing into
  person/record creation and losing on a raw unique-violation. New
  **Step 5a**: a manual two-session test (not expressible as a single
  script).
- **Item 3: `withdraw_onboarding_request()`'s `workflow_cancelled`
  field was conflating "closed" with "cancelled"** — an APPROVED
  (closed-by-approval, never cancelled) request was being misreported
  as cancelled on replay. Now derived from `current_status = 'CANCELLED'`
  specifically. New assertions in `TEST_...` Sections 13/14 covering
  both the fresh and replay call for each path.
- **Item 4: `007`'s response now returns `withdrawn_at`/`withdrawn_by`
  on BOTH the fresh and replay path** (previously only on replay),
  computed once and used identically for the write and the response.
- **Item 5: new `TEST_...` Section 8C** — `_enforce_hired_consistency()`
  (`006`) tested directly, bypassing the RPC entirely, proving this
  database-level guard works independent of RLS/grants (Section 7's
  test fails at the grant layer, never reaching this trigger at all).
- **Item 6: role-grant cleanup is now ownership-safe** — Step 3's
  provisioning script records exactly which `role_permissions` pairs it
  creates, and Step 7's cleanup revokes only those, never a
  pre-existing legitimate grant. Also: `\dn` (a `psql` meta-command, not
  valid in the Supabase SQL Editor) replaced with a plain
  `pg_namespace` query throughout.

## CHANGES IN ROUND 4 (for reference)

- **Item 1 (the big one, this round): `004`'s seed function is now
  `SECURITY DEFINER`.** `authenticated` has no grant at all on
  `workflow._seed_provenance` (confirmed by reading
  `phase_2_workflow_engine/006_workflow_reference_seed.sql` directly) —
  under the round-3 `SECURITY INVOKER` design, the seed function's own
  provenance-tracking inserts would have failed with a permission error
  even though its other six tables' writes would have succeeded. New
  **Step 2a** below is a preflight check for this specific risk before
  you apply `004`.
- **Item 2: three test fixtures that insert directly into
  `core.people`/`core.person_user_links`/`onboarding_records` from a
  privileged (non-`authenticated`) DB role now also set
  `request.jwt.claims` to a real test user first** — these tables'
  `_force_created_by()` triggers require `auth.uid() IS NOT NULL`
  regardless of which role is connected; being privileged bypasses
  RLS/grants, not triggers.
- **Item 3: `006`'s hire-retry conflict check is now NULL-safe**
  (`IS DISTINCT FROM`, not `!=`) — a first hire recorded with a NULL
  `employee_number` now still correctly catches a conflicting non-null
  retry.
- **Item 5: the `core.people` direct-mutation test no longer assumes an
  exception** — that table's UPDATE policy is `USING`-only (no
  `WITH CHECK`), so an unauthorized UPDATE is silently filtered to 0
  rows, not an error. Rewritten to check the actual invariant
  (`person_type` unchanged) via a privileged re-read.
- **Item 6: the rollback procedure's cleanup section now gives an
  explicit, dependency-ordered list**, not a broad "remove these four
  things" — see Step 7.
- **Item 6 (small): `007`'s idempotent-replay response now also
  includes `withdrawal_reason`**, matching the fresh-withdrawal
  response shape.

## CHANGES IN ROUND 2 (for reference)

- **Item 1 (the big one): onboarding_records is now RPC-only.** `002`
  grants `authenticated` SELECT ONLY — no INSERT, no UPDATE at all.
  Every write happens through a SECURITY DEFINER function. This also
  resolves item 2 (REJECTED is now equally immutable, not a special
  case).
- **Item 8: pgcrypto prerequisite.** New Step 0 below — confirm where
  `pgcrypto` is installed in your project before applying `003`.
- **Item 6: a THIRD real test account is now required** (candidate
  self-view testing) — see Step 3.
- **Item 4: rollback order corrected** — `007 → 006 → 004 → 005 → 003 →
  002 → 001` (004 before 005, not after — 004's own data still
  references the `ONBOARDING_MANAGE` code by name while it exists).
  There are **seven** rollback files, not six.
- **Round 3 (NEW): test suite rewritten again** — every negative test
  now asserts WHY it failed (exact SQLSTATE or message prefix), not
  just that an exception occurred; the one-open-per-person test uses a
  dedicated person, not the already-HIRED main record; ordinary-user
  tests use the real third account; a new test covers hire-retry
  payload mismatches; version is asserted at exact lifecycle points.
  See `FIXES_SUMMARY.md` for the full round-3 mapping.
- **Round 3: `003`'s response is now `onboarding_status` +
  `workflow_status`**, not one overloaded `status` field — update any
  frontend call site accordingly.
- **Round 3: `request_idempotency` has no `authenticated` grant at all
  anymore** — fully internal to the RPC.
- **Item 9: the workflow definition is now bound to the OSYSTIC
  organization** — see Step 4a and the honest limitation noted there.

## Step 0 — Confirm pgcrypto's schema (item 8, NEW)

Before applying `003` (which calls `extensions.digest(...)`):

```sql
SELECT e.extname, n.nspname
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pgcrypto';
```

If `nspname` is **not** `extensions`, stop and change the schema
qualifier in `003`'s `v_payload_hash` computation to match before
applying it — do not remove the qualifier and fall back to an ambient
search_path.

## Step 1 — Backup + pre-apply snapshot

```sql
SELECT 'core.people' AS "table", count(*) FROM "core"."people"
UNION ALL SELECT 'hr.employees', count(*) FROM "hr"."employees"
UNION ALL SELECT 'core.permissions', count(*) FROM "core"."permissions"
UNION ALL SELECT 'workflow.workflow_definitions', count(*) FROM "workflow"."workflow_definitions"
UNION ALL SELECT 'workflow.approval_requests', count(*) FROM "workflow"."approval_requests"
UNION ALL SELECT 'workflow._seed_provenance (this module)', count(*) FROM "workflow"."_seed_provenance" WHERE "seeded_by_migration" LIKE '00%_onboarding%';
```
Save this — `core.permissions` should be **+2** after `005`,
`workflow.workflow_definitions` **+1** after Step 4 (Track B only).

## Step 2 — Apply, in order

1. `001_onboarding_schema.sql`
2. `002_onboarding_rls_grants.sql`
3. `003_onboarding_create_and_submit_request.sql` (after Step 0's pgcrypto check)
4. `004_onboarding_workflow_definition_SEED.sql` (creates the seed **function** only — do not call it yet; depends on `workflow."_seed_provenance"` already existing from `phase_2_workflow_engine/006_workflow_reference_seed.sql`, which should already be applied)
5. `005_onboarding_permissions_seed.sql`
6. `006_confirm_employee_hire.sql`
7. `007_withdraw_onboarding_request.sql`
8. `008_onboarding_candidate_identity_projection.sql` (round 8 - read-only candidate identity function; run `TEST_onboarding_008_identity_projection.sql` after it in the Track B database)

Stop and report if any file errors.

## Step 2a — `_seed_provenance` privilege preflight (item 1, round 4, NEW)

Confirm directly, rather than assuming either answer:

```sql
SELECT has_table_privilege('authenticated', 'workflow._seed_provenance', 'INSERT');
```

This should return `false` — `004`'s seed function is `SECURITY
DEFINER` specifically because `authenticated` has no grant on this
table at all (confirmed against `phase_2_workflow_engine/
006_workflow_reference_seed.sql`, which never grants it). If this
query unexpectedly returns `true`, something in your project's setup
differs from what was verified here — stop and report back before
calling the seed function, rather than assuming the `SECURITY DEFINER`
fix is unnecessary. Also worth a glance while you're here:

```sql
SELECT relrowsecurity FROM pg_class WHERE oid = 'workflow._seed_provenance'::regclass;
```

Expected `false` (RLS not enabled on this table at all — it was never
meant to be reachable by `authenticated` through any path other than a
`SECURITY DEFINER` function like `004`'s).

## Step 3 — Provision THREE real test accounts

1. **`LOCAL_TEST_ADMIN`** (`2d48e4e3-fee2-4034-8b8d-a3cce8298ce2`) — grant
   `ONBOARDING_MANAGE` (submitter).
2. **A second real, loggable-in account** — grant `ONBOARDING_MANAGE`
   too (approver; maker-checker requires two different holders).
3. **A third real `auth.users` row** — for candidate self-view testing.
   This one needs **no permission grant at all** — in fact, the
   opposite: it must be verified to hold **neither** `ONBOARDING_MANAGE`
   **nor** `PEOPLE_MANAGE` (round 6, item 2 — `TEST_onboarding_full_flow.sql`'s
   SECTION 0 now checks both explicitly and refuses to run otherwise).
   `PEOPLE_MANAGE` specifically matters because that's what actually
   gates `core.people`/`hr.employees` access (not `ONBOARDING_MANAGE`) —
   an account that happened to already hold it would make Section 9's
   negative tests pass for the wrong reason. It still needs to
   genuinely exist in `auth.users` — `core.person_user_links.user_id`
   has a hard FK to it. Use a real, deliberately unprivileged EMS test
   identity, not just any spare account.

**Item 3 (round 6):** the setup-grants scratch table is now **run-scoped**.
Without a run identifier, a crashed/unfinished prior run's
`granted_by_this_setup = true` rows could survive and cause a LATER
run's cleanup to revoke a grant the later run never actually created.
Fixed two ways together: a `run_id` on every row, and an explicit
refusal to start while a previous run's rows are still sitting there
unresolved:

```sql
CREATE TABLE IF NOT EXISTS "_onboarding_test_setup_grants" (
    "run_id" uuid, "role_id" uuid, "permission_id" uuid, "granted_by_this_setup" boolean
);

DO $$
DECLARE
    v_run_id uuid := gen_random_uuid();
    v_role_id uuid;
    v_permission_id uuid;
    v_already_existed boolean;
BEGIN
    -- Refuse to start while a previous run's rows are still present -
    -- they should have been fully cleaned up (Step 7) before a new run
    -- begins. Don't let old scratch provenance silently carry forward.
    IF EXISTS (SELECT 1 FROM "_onboarding_test_setup_grants") THEN
        RAISE EXCEPTION 'STALE SETUP-GRANTS FOUND: _onboarding_test_setup_grants already has rows from a previous run that was never cleaned up (Step 7). Resolve or clear them first - do not let old provenance influence this run''s cleanup.';
    END IF;

    RAISE NOTICE 'This run''s run_id is % - record it, Step 7''s cleanup needs it.', v_run_id;

    SELECT "id" INTO v_permission_id FROM "core"."permissions" WHERE "code" = 'ONBOARDING_MANAGE';

    -- Repeat this whole block once per account/role being granted
    -- ONBOARDING_MANAGE (accounts 1 and 2 only — account 3 gets nothing,
    -- and must NOT already hold it - see point 3 above).
    SELECT "id" INTO v_role_id FROM "core"."roles" WHERE "name" = 'LOCAL_TEST_ADMIN'; -- change per account

    v_already_existed := EXISTS (
        SELECT 1 FROM "core"."role_permissions" WHERE "role_id" = v_role_id AND "permission_id" = v_permission_id
    );
    IF NOT v_already_existed THEN
        INSERT INTO "core"."role_permissions" ("role_id", "permission_id") VALUES (v_role_id, v_permission_id);
    END IF;
    INSERT INTO "_onboarding_test_setup_grants" VALUES (v_run_id, v_role_id, v_permission_id, NOT v_already_existed);
END;
$$;
```

Record the `run_id` the `NOTICE` prints — Step 7's cleanup must scope
its `DELETE` to it explicitly, not just to `granted_by_this_setup = true`
alone.

This table isn't a `TEMP` table deliberately — `role_permissions`
grants and the accounts holding them are expected to persist across
the whole apply → test → rollback → re-apply cycle (possibly spanning
multiple sessions), unlike the test script's own `TEMP` fixtures which
are deliberately session-scoped. Drop it manually once Step 7's cleanup
has used it.

Record all three accounts' `auth.users.id` values — `TEST_onboarding_full_flow.sql`'s
`SECTION 0` needs them.

## Step 4 — Seed the workflow definition (TRACK B ENVIRONMENT ONLY)

**Do NOT run this step in the Track A (reversibility) environment.** Once
seeded, the workflow version is ACTIVE and permanently immutable — the
`004` rollback can no longer remove it (see Step 7).

Log in as a session holding both `ONBOARDING_MANAGE`-granting admin
rights AND `WORKFLOW_CONFIG_MANAGE`, then:

```sql
SELECT "onboarding"."seed_onboarding_workflow_definition"();
```

**Item 9 note:** this binds the definition to the OSYSTIC
organization_id. One honest limitation this does NOT fix, surfaced
directly rather than silently worked around: `workflow.start_approval_request()`
(the shared engine) hardcodes `approval_requests.organization_id = NULL`
unconditionally for every module, by deliberate prior design decision
("single-tenant convention... until the shared org migration lands" —
see that function's own comment). So while the *definition* is now
correctly org-scoped, the resulting *request* row still won't carry an
organization_id — that's shared, system-wide engine behavior, out of
scope for this module's migrations to change unilaterally.

## Step 5 — End-to-end proof (`TEST_onboarding_full_flow.sql`)

Fill in all **three** placeholder ids in `SECTION 0` first — the script
validates them (now comprehensively: existence, distinctness, and
`ONBOARDING_MANAGE` on both admins, round 4's item 4) and refuses to
run with placeholders still in place. Every scenario from every round
is covered, with WHY each negative test failed actually asserted
(SQLSTATE or exact message prefix). Sections worth knowing about by
name:
- **Section 4:** direct INSERT at APPROVED/REJECTED/WITHDRAWN and raw
  UPDATE straight to APPROVED/REJECTED, as a genuine `ONBOARDING_MANAGE`
  holder against a dedicated fixture person — asserts SQLSTATE `42501`.
- **Section 8:** the terminal-transition trigger (`001`), tested
  directly — no ordinary-role path can reach it after Section 4's lockdown.
- **Section 8C (new, round 5):** `_enforce_hired_consistency()` (`006`)
  tested directly, bypassing the RPC — proves this DB-level guard works
  independent of RLS/grants, which Section 7 alone doesn't exercise.
- **Section 9:** `core.people`/`hr.employees` direct-write tests,
  rewritten (round 4) to check the actual invariant rather than assume
  an exception — `core.people`'s UPDATE policy is `USING`-only.
- **Section 11 / 11B:** `confirm_employee_hire()` retried with a
  conflicting employee_number, including the NULL-original case.
- **Sections 13/14 (round 5):** `workflow_cancelled` asserted on both
  the fresh and replay call for each withdrawal path — `true` for
  SUBMITTED, `false` for APPROVED.
- **Section 13:** also the first real exercise of
  `withdraw_onboarding_request()` → `workflow.process_system_action()` —
  if it fails, report the exact PostgreSQL permission error, don't widen
  any grant.
- **Section 15:** the one-open-per-person and `workflow_request_id`
  unique-index tests, using dedicated fresh fixtures.
- **Section 17:** version asserted at the exact expected progression
  (2 → 3 → 4), not just ">1".

## Step 5a — Manual two-session concurrency test (item 4, round 6: evidence capture now explicit)

This is NOT expressible as a single sequentially-executed script — it
genuinely requires two separate, simultaneous database connections.
Open two SQL Editor tabs (or two `psql` sessions). **Round 6's
correction: don't just eyeball that it "worked" — capture the specific
evidence listed below, proving serialization actually protected the
pre-person-creation side effects, not merely that the API returned
something plausible.**

1. Pick a fixed candidate email and idempotency key for this test, e.g.
   `concurrency-test@example.invalid` / `'concurrency-test-key-001'`.
2. **Before** anything else, capture baseline counts:
   ```sql
   SELECT count(*) FROM "core"."people" WHERE "primary_email" = 'concurrency-test@example.invalid';
   SELECT count(*) FROM "onboarding"."onboarding_records" o JOIN "core"."people" p ON p."id" = o."person_id" WHERE p."primary_email" = 'concurrency-test@example.invalid';
   ```
   Both should be `0`. Record this.
3. In **both** tabs, set the same actor:
   ```sql
   SELECT set_config('request.jwt.claims', json_build_object('sub', '<hr_admin uuid>', 'role', 'authenticated')::text, true);
   ```
4. In **Tab A**, start (but do not yet commit) a transaction calling
   `create_and_submit_onboarding_request(...)` with that exact key and
   payload — pause before sending `COMMIT`.
5. In **Tab B**, concurrently call the function with the exact SAME key
   and payload. **Capture and record:**
   - That Tab B visibly blocks ("running"/not yet returned) while Tab A
     remains uncommitted — a screenshot or the client's own "query
     running" indicator is fine.
   - Tab A's full result once it returns (`onboarding_record_id`,
     `idempotent_replay: false`).
   - Tab B's full result once it returns, AFTER Tab A commits
     (`onboarding_record_id` — must match Tab A's exactly —
     `idempotent_replay: true`).
6. **After** both complete, re-run the same two count queries from step
   2. **Both must now read exactly `1`**, not `2` — this is the actual
   proof that serialization worked: a race would have produced `2`
   (or a raw unique-violation error instead of Tab B's clean
   `idempotent_replay: true` result). Record these after-counts
   alongside the before-counts from step 2.
7. Repeat steps 3-5 with Tab B using the SAME key but a DIFFERENT
   payload (e.g. a different `full_name`) — Tab B should still wait for
   Tab A, then return `ONBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH`, not
   a raw constraint-violation error and not a silent duplicate. Re-check
   the counts once more — still exactly `1` each, the mismatched retry
   must not have created anything either.

Paste into the execution report: both tabs' exact outputs, the blocking
evidence, and all three sets of before/after counts (steps 2, 6, 7).

## Step 6 — Regression check

Re-run Step 1's snapshot query and confirm every count moved by exactly
what the test script should have produced. Separately, re-run one real
existing check per other module (Leave/Attendance/Assets/Contracts) to
confirm none of the shared tables this module writes to
(`core.permissions`, `workflow.*`, `core.people`, `hr.employees`)
affected them.

## Step 6a — Record known limitations in the execution report (item 5, round 6, NEW)

This is a documentation action item, not a code change — do not modify
anything to "fix" this inside Phase 8.

The shared workflow engine's `workflow.start_approval_request()`
hardcodes `approval_requests.organization_id = NULL` unconditionally,
for every module, by existing deliberate design (its own code comment:
*"Internally NULL, matching the single-tenant convention used
throughout this schema until the shared org migration lands"*). `004`
correctly binds the onboarding *workflow definition* to the OSYSTIC
organization, and `003` correctly resolves it scoped to that same
organization — but the resulting `approval_requests` *row* still won't
carry an `organization_id`, regardless of anything in this module.

**Copy this into the execution report verbatim, as a recorded known
limitation, not a defect of Phase 8:**

> Known limitation (shared engine, not Phase 8-specific):
> `workflow.approval_requests.organization_id` is `NULL` for every
> module's requests, including Onboarding's, due to
> `start_approval_request()`'s existing single-tenant convention. To be
> resolved by a future shared organization-scoping migration to the
> workflow engine itself — which will require regression testing across
> Leave, Attendance, Assets, Contracts, and Onboarding when it happens,
> since all five depend on this same function.

## Step 7 — Two proofs, two environments (REWRITTEN, round 7)

**Why they must be separate.** Two parts of the shared workflow engine
are permanent by design, and Phase 8 does not weaken either:

1. `workflow.approval_actions` and `workflow.status_history` carry an
   unconditional `BEFORE UPDATE OR DELETE` trigger
   (`workflow.prevent_mutation()`), so runtime history can never be
   deleted once any approve/reject/withdraw action has run.
2. `phase_2_workflow_engine/005_workflow_rls_grants.sql` installs
   `BEFORE INSERT OR UPDATE OR DELETE` triggers on `workflow_steps`,
   `workflow_statuses`, `transition_rules` and `workflow_step_assignees`
   that block any change once the parent version is ACTIVE or RETIRED.
   The seed function must activate the version, so **a seeded onboarding
   workflow is permanent in that database.** There is no sanctioned
   "retract version" function.

Both are shared workflow-engine characteristics (Leave, Attendance,
Assets and Contracts behave the same), not Phase 8 defects. Never
disable triggers, change version status directly, or use CASCADE to get
around them.

### TRACK A — Migration Reversibility Evidence
Fresh disposable scratch database / Supabase branch. **Never shared UAT
or production.** If none is available, say so before doing anything else.

1. Take a clean pre-apply snapshot (Step 1 query). Save it.
2. Apply `001`–`008` (Step 0 pgcrypto check first).
3. **Do NOT call `onboarding.seed_onboarding_workflow_definition()`.**
4. **Do NOT run `TEST_onboarding_full_flow.sql`; create no onboarding data.**
5. Run rollbacks in this exact order:
   `008 → 007 → 006 → 004 → 005 → 003 → 002 → 001`.
   `004`'s rollback should print the CASE 1 notice (no provenance rows)
   and drop only the seed function.
6. Verify exact pre-Phase-8 state:
   ```sql
   SELECT nspname FROM pg_namespace WHERE nspname = 'onboarding';
   ```
   returns zero rows, and the Step 1 snapshot is identical to the saved
   one (including `workflow._seed_provenance` and `core.permissions`).
7. Re-apply `001`–`008`; confirm success (repeatability).

### TRACK B — Functional Execution Evidence
The seeded scratch database (this can be the current one, see Step 7a).

1. `001`–`008` applied; three test accounts verified (Step 3); workflow
   seeded (Step 4).
2. Run `TEST_onboarding_full_flow.sql` in full (Step 5).
3. Run the two-session concurrency test (Step 5a).
4. Run the Leave/Attendance/Assets/Contracts regressions (Step 6).
5. **Never attempt rollback here.** If the `004` rollback is run in this
   environment it raises `ONBOARDING_ROLLBACK_BLOCKED_ACTIVE_WORKFLOW`
   and changes nothing — that is correct behavior. `onboarding` / `hr` /
   `core` test rows may be tidied individually (dependency order:
   `onboarding.request_idempotency` → `onboarding.onboarding_records` →
   `hr.employees` → `core.person_user_links` → `core.people`; then only
   the `role_permissions` grants recorded for this `run_id` in
   `_onboarding_test_setup_grants`), but this is optional; dispose of the
   environment wholesale when finished.

## Step 7a — Recovering the current scratch database (NEW, round 7)

State after the first drill attempt: `007` and `006` rolled back
successfully; `004` rollback failed atomically (nothing deleted); the
seed function and the ACTIVE onboarding workflow are still present;
`005`, `003`, `002`, `001` untouched; `ONBOARDING_MANAGE` grants for
LOCAL_TEST_ADMIN and TEST_WORKFLOW_ADMIN still in place.

1. Do **not** run any further rollback files in this database.
2. Re-apply, in order: `006_confirm_employee_hire.sql`, then
   `007_withdraw_onboarding_request.sql` (both unchanged in v8).
3. Verify they exist:
   ```sql
   SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'onboarding'
     AND p.proname IN ('confirm_employee_hire','withdraw_onboarding_request');
   ```
   (expect 2 rows), and `NOTIFY pgrst, 'reload schema';` if the API
   still can't see them.
4. Continue with Track B (Steps 5, 5a, 6). Do not attempt to remove the
   activated onboarding workflow.
5. Run Track A separately in a fresh scratch database/branch.

## Step 8 — Execution report structure (NEW, round 7)

Keep the two proofs in separate sections.

**Section 1 — Migration Reversibility Evidence (Track A):** environment
description (fresh scratch, no seed invocation), pre-apply snapshot,
apply results `001`–`008`, rollback results in order (include the `004`
CASE 1 notice), exact-state verification output, re-apply results.

**Section 2 — Functional Execution Evidence (Track B):** seeded
workflow verification, full PASS/FAIL output of
`TEST_onboarding_full_flow.sql`, concurrency-test evidence (Step 5a),
`process_system_action(... CANCEL ...)` confirmation, regression results
for Leave / Attendance / Assets / Contracts, exact PostgreSQL errors
encountered and how they were resolved.

**Record verbatim in the report:**

> Shared workflow-engine characteristic (not a Phase 8 defect): once a
> workflow version has been activated, its configuration is immutable
> (triggers from `phase_2_workflow_engine/005_workflow_rls_grants.sql`),
> and runtime approval history is append-only. Phase 8 does not attempt
> to destructively retract an activated workflow. Any future retraction
> mechanism must be added to the shared engine and regression-tested
> across Leave, Attendance, Assets, Contracts and Onboarding.

Also include the Step 6a `organization_id = NULL` known limitation.
