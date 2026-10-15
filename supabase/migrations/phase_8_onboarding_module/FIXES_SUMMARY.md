# Phase 8 Onboarding — v8 Fix Package: Round 7

Addresses Shawaiz's decision after the first real rollback drill hit
`WORKFLOW_VERSION_IMMUTABLE` on the `004` rollback. Architecture remains
frozen. The round-7 decision itself changed only the `004` rollback, the
test file, the checklist and this summary. **Separately, real execution
of the suite then exposed three code defects, fixed in `003`, `006` and
`007`** (see "Execution findings" below). `001`, `002` and `005` are
unchanged from v7.

| Item (his letter) | Fixed in |
|---|---|
| **Option 1** – separate migration-reversibility proof from seeded functional proof | Checklist Step 7 (Track A / Track B), `TEST_...` Section 18 |
| **A** – Track A: fresh scratch DB, no seed invocation, apply → rollback → verify → re-apply | Checklist Step 7 Track A |
| **B** – Track B: current scratch DB, re-apply `006` + `007`, run functional suite, never remove the workflow | Checklist Step 7a + Track B |
| **C** – 004 rollback contract: seed-never-invoked vs. activated; fail fast with a clear message; correct the false "no delete-blocking trigger" claim; record the dependency on `phase_2_workflow_engine/005_workflow_rls_grants.sql` triggers | `004_..._SEED_ROLLBACK.sql` (rewritten) |
| **D** – execution report in two sections + shared-engine characteristic statement | Checklist Step 8 |

## 004 rollback behavior (new)

- **CASE 1** – no `workflow._seed_provenance` rows: prints a notice and
  drops only the seed function. Used by Track A.
- **CASE 2** – any seeded version is ACTIVE/RETIRED: raises
  `ONBOARDING_ROLLBACK_BLOCKED_ACTIVE_WORKFLOW` before any DELETE; the
  seed function is left in place; nothing is partially rolled back.
- Deletes remain provenance-scoped and are only reachable for an
  unactivated (DRAFT) seed.
- No trigger disabling, direct status changes or CASCADE anywhere.

## Correction on record

Earlier versions of the `004` rollback header (v3–v7) said no
DELETE-blocking trigger exists on the workflow configuration tables.
That check read only `004_workflow_functions_triggers.sql` and missed
`005_workflow_rls_grants.sql`. The round-6 Track A plan (which seeded
before rollback) was built on that claim and was invalid; it is replaced.

## Not yet run

Everything here is still unexecuted against a database. First real
checks: (1) the `004` rollback's CASE 1 notice in a fresh unseeded DB;
(2) the CASE 2 exception in the currently seeded DB (expected, and a
useful negative proof that the fail-fast guard works); (3) that
`006`/`007` re-apply cleanly in the current scratch DB.

---

## Execution findings (found by the first real test run, same round)

Running `TEST_onboarding_full_flow.sql` raised
`ONBOARDING_HIRED_STATE_INCONSISTENT ... person_type=EMPLOYEE,
hr.employees row exists=f` inside `confirm_employee_hire()`. Root cause
was a PL/pgSQL gotcha, not bad data: `<record_var> IS NOT NULL` is TRUE
only when **every** column is non-null. The hire had in fact succeeded
(the HIRED consistency trigger uses `EXISTS` and passed), but the replay
branch's `v_existing_employee IS NOT NULL` was FALSE because
`hr.employees` has nullable columns.

Same pattern audited across the package; three real fixes:

| File | Change | Impact if left |
|---|---|---|
| `006` | `v_existing_employee."id" IS NOT NULL` (2 places) | Every idempotent hire replay failed |
| `007` | `v_request."id" IS NOT NULL AND ...` | `approval_requests.organization_id` is always NULL, so the old check was always FALSE: withdrawing a SUBMITTED record never cancelled its workflow request (the exact hole round 2 item 2 was meant to close) |
| `003` | `v_existing."idempotency_key" IS NOT NULL` | Latent; `onboarding_record_id` is nullable |

`IS NULL` checks that guard "row not found" (`v_record IS NULL`, etc.)
were reviewed and are correct: a found row always has a non-null `id`.
All three files are `CREATE OR REPLACE` and safe to re-apply.

### Second execution finding: `workflow_status` meant two things (003)

First full test run: **all assertions PASS**, but the result rows showed
`workflow_status = CREATED` on the fresh call (3a) and `PENDING` on the
idempotent replay (3b). The fresh path returned the engine's start-result
label; the replay path returned `approval_requests.current_status`. The
test only asserted the field exists, so it passed. `003` now reads
`current_status` on both paths. Re-apply `003` (CREATE OR REPLACE). To
make this stay fixed, the 3a2 assertion should compare the fresh and
replay values; not yet added.

### Round-7 follow-up corrections (Shawaiz review of v8)

- **Regression assertion `3b2`:** asserts fresh `workflow_status` =
  `PENDING`, replay `workflow_status` equals it, and fresh/replay agree on
  `onboarding_record_id`, `person_id`, `workflow_request_id` and
  `onboarding_status`. Permanently covers the CREATED-vs-PENDING defect.
- **Final zero-failure gate:** the suite now raises
  `ONBOARDING_TEST_SUITE_FAILED` (listing the failing steps) if any result
  begins with `FAIL`, raises `ONBOARDING_TEST_SUITE_EMPTY` if no PASS rows
  were recorded, and otherwise adds a `99-summary` row. A run that merely
  completes can no longer be reported as passing.
- **This document:** the opening statement above no longer claims no
  code changed in `003`/`006`/`007`.

### Third execution finding: suite was not re-runnable (test only)

Re-running the suite failed with `23505 employees_employee_number_key`
(`EMP-TEST-001` already existed from the previous committed run). No
product defect: the unique constraint did its job. The test now
generates a fresh `employee_number` per run. The other hard-coded
employee numbers (`EMP-999-CONFLICT`, `EMP-SHOULD-BE-REJECTED`,
`EMP-SHOULD-NOT-EXIST`) are only used in calls/inserts that are expected
to be rejected, so they never persist.

---

## Round 8: migration 008 (candidate identity projection)

Team-lead decision after the UI test showed approvers without
`PEOPLE_MANAGE` seeing "Candidate d843d6ef": Option A, implemented as an
onboarding-owned read-only function. No change to `core.people` RLS/grants
and no change to `001`-`007`.

- `008_onboarding_candidate_identity_projection.sql`: `onboarding.get_candidate_identities(uuid[] DEFAULT NULL)`
  returns `onboarding_record_id, person_id, full_name, email` only. SECURITY
  DEFINER, actor from `auth.uid()`, pinned `search_path`, PUBLIC revoked,
  EXECUTE for `authenticated` only, STABLE, no write statement. Visibility
  is the same permission-based rule as the `onboarding_records_select`
  policy (MANAGE, VIEW_ALL, or the ACTIVE-linked candidate); no role-name
  bypass, so Technical Admin gets nothing by being Technical Admin.
- `008_..._ROLLBACK.sql`: drops the function; first in the rollback order.
- `TEST_onboarding_008_identity_projection.sql`: MANAGE with and without
  PEOPLE_MANAGE sees the real name/email; VIEW_ALL holder (temporary role)
  sees it; unrelated user and an admin-ish user with no onboarding
  permission get zero rows; candidate gets only their own record; direct
  `core.people` SELECT stays blocked for the MANAGE and VIEW_ALL users;
  function shape/grants checks; no-write fingerprint; unauthenticated call
  rejected; Leave/Attendance/Assets/Contracts counts unchanged; temporary
  roles removed by id; final zero-failure gate.
- Frontend: `onboarding.service.ts` resolves names through this function
  instead of reading `core.people` directly.
- Checklist: Track A is now `001`-`008`, rollback `008 -> 007 -> 006 -> 004 -> 005 -> 003 -> 002 -> 001`.

Not yet run against a database.
