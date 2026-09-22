# Shared-Core People/Organization — Apply Checklist (Batch 1: 001-008d)

Team lead approved the revised migration plan and confirmed all five
rules from the review reply (backfill mapping, RPC hardening, permission
naming, migration actor, legacy-column hold). Nothing from this package
has been applied to Supabase yet.

## Execution readiness — confirm all four before applying anything

Per the team lead's second review reply, these four must be explicitly
confirmed ready at the point of execution, not assumed:
- [ ] **Backup**: Step 1 below run, output file confirmed non-empty
- [ ] **Pre-migration snapshot**: Step 2 below run, output saved for comparison
- [ ] **Post-migration validation**: Steps 5, 7 (this batch) and Step 3
      (Batch 2) understood and ready to run/report immediately after
      each corresponding apply step — not deferred to "later"
- [ ] **Existing module regression tests**: each module's own
      end-to-end test script (Leave/Attendance/Assets/Contracts,
      Batch 2 Step 2) is on hand and ready to re-run right after `009a-d`

This checklist is the mechanism for all four — walking through it step
by step, in order, reporting each step's real output, is what
constitutes the confirmation the team lead asked for.

**This checklist covers only 001-008d** - the additive foundation
(shared-core tables, hr.employees, the provisioning RPC, and the new
nullable `hr_employee_id` columns across all 9 tables). It does **not**
cover 009a-011 (the RLS/RPC cutover and the held legacy-column drop) -
those need a separate checklist once written, since they touch each
module's live, tested RPCs and require a fresh regression pass per
module.

## Step 1 — Backup

```powershell
pg_dump "postgresql://postgres.kjjeeoeaugrlmmuxpjjf:<YOUR_ENCODED_PASSWORD>@aws-0-<region>.pooler.supabase.com:5432/postgres" --schema=core --schema=hr --schema=workflow --schema=leave --schema=attendance --schema=assets --file=pre_shared_core_backup.sql
```
- Session Pooler connection string, same as every prior module.
- Percent-encode the password if it has special characters.
- Confirm the output file is non-empty before continuing.

## Step 2 — Pre-apply snapshot

```sql
SELECT 'leave.leave_requests' AS "table", count(*) FROM "leave"."leave_requests"
UNION ALL SELECT 'leave.leave_ledger', count(*) FROM "leave"."leave_ledger"
UNION ALL SELECT 'leave.leave_accruals', count(*) FROM "leave"."leave_accruals"
UNION ALL SELECT 'leave.leave_adjustments', count(*) FROM "leave"."leave_adjustments"
UNION ALL SELECT 'attendance.attendance_days', count(*) FROM "attendance"."attendance_days"
UNION ALL SELECT 'attendance.correction_requests', count(*) FROM "attendance"."correction_requests"
UNION ALL SELECT 'assets.asset_requests', count(*) FROM "assets"."asset_requests"
UNION ALL SELECT 'assets.asset_assignments', count(*) FROM "assets"."asset_assignments"
UNION ALL SELECT 'hr.contracts', count(*) FROM "hr"."contracts"
UNION ALL SELECT 'core.permissions', count(*) FROM "core"."permissions";
```
Save the output — every one of these counts must be identical after
Step 3 below (this batch is additive-only; nothing in these 9 tables'
existing rows, or their existing columns, should change).

## Step 3 — Apply migrations, in order, one file per SQL Editor query

From `supabase/migrations/phase_7_shared_core_people_org/`:
1. `001_shared_core_schema.sql`
2. `002_shared_core_rls_grants.sql`
3. `003_provision_person_for_user.sql`
4. `004_hr_employees_schema.sql`
5. `005_people_org_permissions_seed.sql`

If any file errors, stop and do not proceed to the next one.

## Step 4 — Backfill (admin session, not a bare migration)

**Revision 3** — Step 0 is now a true fail-fast guard (a `DO` block that
`RAISE EXCEPTION`s and aborts), and the entire script runs inside one
explicit `BEGIN...COMMIT` transaction — a collision rolls back
everything in the script, nothing partially commits. **Revision 2** —
email is no longer used to associate a user with an
existing person anywhere in this script (the team lead's review
concern on the original version). Every eligible user now gets a fresh
`core.people` row created and linked in the same transaction, keyed
purely by `auth.users.id`. Run `006_backfill_people_and_links.sql` in
full, as one paste, logged in as `LOCAL_TEST_ADMIN`:
- **Step 0 now genuinely aborts on collision** — if it fires, the whole
  script errors out and nothing commits (confirmed by the explicit
  transaction wrapper); a clean run shows a `NOTICE: Step 0 passed: no
  email collisions among N eligible users.` in the output before
  Step 2/3 run — capture that notice as the evidence.
- Note the `eligible_user_count` output for comparison against Step 5.

## Step 5 — Backfill validation (read-only, stop-the-line gate)

Run `007_backfill_validation.sql` in full. Per the rollback criterion in
the migration plan: **if any check here doesn't match expectations, stop
— do not proceed to Step 6.** Rollback at this point is simply dropping
what Step 4 added (`core.people` / `core.person_user_links` /
`hr.employees` rows); nothing in the 9 live tables has been touched yet.

Report back:
- Check 0: zero rows (no person mapped to by more than one user — the
  direct determinism evidence for the team lead's review point)
- Check 1: `eligible_count`, `linked_people_count`, `hr_employees_count` — all three equal
- Check 2: both duplicate-check queries return zero rows
- Check 3: the test employee resolves through the full chain, `hr_employee_id` populated
- Check 4: `should_be_zero` for `LOCAL_TEST_ADMIN` is actually `0`

## Step 6 — Add and backfill the new columns

Apply `008a`, `008b`, `008c`, `008d`, in any order (independently
reversible per module). Each file ends with its own "expect zero
unresolved rows" check — confirm each before moving to the next.

**Known exception, discovered on first live run**: `leave.leave_ledger`
rejects any `UPDATE` (an append-only immutability trigger,
`trg_leave_ledger_immutable` — by design, not a bug). `008a` does NOT
backfill this table's `hr_employee_id`; its pre-cutover rows stay `NULL`
permanently, which is the historically correct state (they predate the
shared-core model). `008a`'s own check output labels this row
explicitly so it isn't mistaken for a failure — only `leave_requests`,
`leave_accruals`, and `leave_adjustments` need to show zero.

## Step 7 — Post-apply regression check

Re-run Step 2's query. Every count must be **identical** to Step 2's
output — this batch only adds new tables/columns, never touches an
existing row.

```sql
SELECT schemaname, tablename, rowsecurity FROM pg_tables WHERE schemaname = 'core';
-- expect 4 rows (organizations, people, person_user_links, departments), all rowsecurity: true
SELECT schemaname, tablename, rowsecurity FROM pg_tables WHERE schemaname = 'hr' AND tablename = 'employees';
-- expect 1 row, rowsecurity: true
```

Report the output of Steps 1 (file exists, non-empty), 4, 5, and 7 back
for confirmation — same evidence standard as every prior module.

**Do not proceed to wiring `core.provision_person_for_user()` into the
signup flow, or to applying `009`-`011`, until this batch is confirmed
clean.**

---

# Batch 2 (009-011): Dual-write cutover + held legacy-drop

Covers `009_core_resolve_hr_employee_id_helper.sql` through
`011_drop_legacy_employee_id.sql`. **Only apply this after Batch 1 above
is fully confirmed clean.**

## Scope decision, flagged for confirmation before applying

`009a`-`009d` are **dual-write, not a full authorization switch** —
every RPC keeps its exact existing `auth.uid()`/`employee_id`-based
identity and authorization logic completely unchanged; the only
addition is that each RPC now also resolves and stores
`hr_employee_id` on every row it inserts, using the new
`core.resolve_hr_employee_id()` helper. Full details and reasoning are
in `009`'s file header. This is a refinement to the original plan
wording ("switches ... instead of") — surfaced here for your
confirmation, not decided unilaterally: recommending the actual
authorization switch (RLS policies and RPC checks depending on
`hr_employee_id` instead of `employee_id`) happen atomically together
with `011`'s column drop, not before, so the legacy path stays a safety
net for the entire validation window. `011`'s own header lists exactly
what that later rewrite touches.

## Step 1 — Apply the helper and per-module cutover files

In order, one file per SQL Editor query:
1. `009_core_resolve_hr_employee_id_helper.sql`
2. `009a_leave_rls_rpc_cutover.sql`
3. `009b_attendance_rls_rpc_cutover.sql`
4. `009c_assets_rls_rpc_cutover.sql`
5. `009d_contracts_rls_rpc_cutover.sql`

Each `CREATE OR REPLACE FUNCTION` uses the exact same signature as the
version already live — no `DROP FUNCTION` needed, existing
`GRANT`/`REVOKE` stay valid untouched.

## Step 2 — Behavioral regression pass (the real check for this batch)

Re-run each module's own existing end-to-end test script exactly as it
was originally verified, and confirm identical results:
- Leave: submit → approve → ledger deduction
- Attendance: submit → approve → attendance day updated
- Assets: submit → approve → fulfill (all three steps)
- Contracts: create → approve → ACTIVE

If any of these break, the break is in one of the `009x` files'
structure (wrong column list, typo) — the underlying business logic
was left untouched, so it isn't the place to look first.

## Step 3 — Full validation

Run `010_full_validation.sql`. Check 1 confirms `hr_employee_id`
populates on new activity (via the counts query — `total >
with_hr_employee_id` is *expected* for accounts with no `hr.employees`
row yet, not a failure). Check 4 exercises the three
`provision_person_for_user()` branches directly (new signup, re-call,
and revoke-then-reactivate for rehire) — walk through it and confirm
each `action_taken` value matches what's expected.

Report back: Step 2's four pass/fail results, and Check 1 and Check 4's
output from Step 3.

## Step 4 — `011` stays held

`011_drop_legacy_employee_id.sql` is written and ready, but **not
executed** as part of this batch. It needs:
- A separate go-ahead from you specifically for this file, after Step 3
  above is confirmed clean.
- The authorization rewrite listed in `011`'s own header, done first,
  in the same sign-off cycle.
- A real grep across the Next.js frontend/API code for any direct
  `*.employee_id` reads that would break once the column is gone — not
  assumed safe from the SQL side alone.

