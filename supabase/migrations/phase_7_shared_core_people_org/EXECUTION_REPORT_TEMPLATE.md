# Shared-Core Migration — Execution & Testing Report

Prepared for: Arslan (team lead)
Prepared by: Syed Abdullah Ahmad
Scope: `supabase/migrations/phase_7_shared_core_people_org/`, migrations
`001`-`010` only. **Migration `011` remains excluded/held, not applied.**

Fill in each section with real output as you execute. Nothing below is
pre-filled with assumed results.

---

## 1. Pre-execution

- [ ] `006`'s Step 0 fix verified (fail-fast `RAISE EXCEPTION`, wrapped
      in explicit `BEGIN...COMMIT`) — confirmed by reading the file
      before running it.
- [ ] **Backup taken**: `pg_dump` command run, output file: `___________`, size: `___________`, confirmed non-empty: Y/N
- [ ] **Pre-migration snapshot** (Step 2 of the checklist) — paste the
      real row-count output here:
```
(paste here)
```

## 2. Migrations applied (001-010)

| File | Applied (timestamp) | Result | Notes |
|---|---|---|---|
| 001_shared_core_schema.sql | | ☐ OK ☐ Error | |
| 002_shared_core_rls_grants.sql | | ☐ OK ☐ Error | |
| 003_provision_person_for_user.sql | | ☐ OK ☐ Error | |
| 004_hr_employees_schema.sql | | ☐ OK ☐ Error | |
| 005_people_org_permissions_seed.sql | | ☐ OK ☐ Error | |
| 006_backfill_people_and_links.sql | | ☐ OK ☐ Error | Step 0 NOTICE text: |
| 007_backfill_validation.sql | | ☐ OK ☐ Error | see §3 |
| 008a_leave_employee_id_columns.sql | | ☐ OK ☐ Error | |
| 008b_attendance_employee_id_columns.sql | | ☐ OK ☐ Error | |
| 008c_assets_employee_id_columns.sql | | ☐ OK ☐ Error | |
| 008d_contracts_employee_id_columns.sql | | ☐ OK ☐ Error | |
| 009_core_resolve_hr_employee_id_helper.sql | | ☐ OK ☐ Error | |
| 009a_leave_rls_rpc_cutover.sql | | ☐ OK ☐ Error | |
| 009b_attendance_rls_rpc_cutover.sql | | ☐ OK ☐ Error | |
| 009c_assets_rls_rpc_cutover.sql | | ☐ OK ☐ Error | |
| 009d_contracts_rls_rpc_cutover.sql | | ☐ OK ☐ Error | |
| 010_full_validation.sql | | ☐ OK ☐ Error | see §4 |

## 3. Backfill validation (007) — real output

```
Check 0 (determinism - zero rows expected):
(paste here)

Check 1 (eligible_count / linked_people_count / hr_employees_count - all equal):
(paste here)

Check 2 (duplicate ACTIVE links - zero rows expected, both queries):
(paste here)

Check 3 (test employee resolves through full chain):
(paste here)

Check 4 (LOCAL_TEST_ADMIN correctly excluded - should_be_zero = 0):
(paste here)
```

## 4. Post-migration validation (010) — real output

```
Check 1 (hr_employee_id populating on new activity - total / with_hr_employee_id per table):
(paste here)

Check 4 (provisioning RPC three-branch test - CREATED_NEW_PERSON / ALREADY_LINKED / REACTIVATED_SAME_LOGIN):
(paste here)
```

## 5. Existing module regression tests

| Module | Test script re-run | Result | Notes |
|---|---|---|---|
| Leave | | ☐ Pass ☐ Fail | |
| Attendance | | ☐ Pass ☐ Fail | |
| Assets | | ☐ Pass ☐ Fail | |
| Contracts | | ☐ Pass ☐ Fail | |

## 6. EMS end-to-end functional testing (real application, not just SQL)

For each flow: log in as the relevant test account in the actual
deployed/dev app, walk the flow, confirm it behaves identically to
before this migration.

| Flow | Test account used | Result | Notes |
|---|---|---|---|
| Submit leave request | | ☐ Pass ☐ Fail | |
| Approve/reject leave request | | ☐ Pass ☐ Fail | |
| Submit attendance correction | | ☐ Pass ☐ Fail | |
| Approve/reject attendance correction | | ☐ Pass ☐ Fail | |
| Submit asset request | | ☐ Pass ☐ Fail | |
| Approve + fulfill asset request | | ☐ Pass ☐ Fail | |
| Create contract | | ☐ Pass ☐ Fail | |
| Approve contract → ACTIVE | | ☐ Pass ☐ Fail | |
| New user signup (provisioning RPC fires) | | ☐ Pass ☐ Fail | |

## 7. Issues found and resolution

| Issue | Where found | Fix applied | Re-tested? |
|---|---|---|---|
| `006`: enum literal `'ACTIVE'` in a `SELECT DISTINCT` needed an explicit cast to `hr.employment_status` (Postgres only auto-casts unknown-type literals in plain `VALUES`, not through a `SELECT`) | `006`, applying `hr.employees` insert | Cast added: `'ACTIVE'::"hr"."employment_status"`. Whole script rolled back automatically (wrapped in explicit `BEGIN...COMMIT`), re-ran clean on retry | ☐ |
| `008a`: `leave.leave_ledger` rejects the backfill `UPDATE` — `trg_leave_ledger_immutable` blocks all `UPDATE`/`DELETE` by design (append-only ledger) | `008a`, applying `leave_ledger` backfill | Removed the `leave_ledger` backfill `UPDATE` entirely; pre-cutover rows stay `hr_employee_id = NULL` permanently (historically correct — they predate the shared-core model); new rows get it populated going forward via `009a`. `010`'s Check 1 comment updated to reflect this as a permanent, expected asymmetry, not a failure | ☐ |
| `003`: `provision_person_for_user()`'s own `RETURNS TABLE ("person_id" uuid, ...)` clause implicitly declares a PL/pgSQL variable named `person_id`, colliding with the real `core.person_user_links.person_id` column whenever referenced unqualified — `ERROR: column reference "person_id" is ambiguous` | `010` Check 4, first live call to the RPC | Every query inside the function now table-aliases the column (`pul."person_id"`, not bare `"person_id"`) — 4 spots fixed (2 `SELECT`s, 1 `SELECT EXISTS`, 1 `UPDATE`) | ☐ |
| `003`: same-login reactivation (rehire, same account) only worked if that account's email happened to be confirmed — it went through the email-match gate first, so an unconfirmed-email account fell through to "create new person" and collided with its own already-existing email (`ERROR: duplicate key ... idx_people_primary_email_unique`) | `010` Check 4 Step 4, exercising the revoke→reactivate branch live | Restructured the function: same-`auth.users.id` reactivation is now checked directly by `user_id` *before* the email gate runs at all — it's an unambiguous identity fact from the foreign key itself, not something that needs email verification. The email-match gate now only applies to the genuinely different case: a different login matching an old person record by email | ☐ |
| | | | |

(Add rows as needed.)

## 8. Checks for migration/RLS/RPC/data-integrity/app-compatibility problems

- [ ] No migration errors across `001`-`010`
- [ ] RLS/authorization behaves identically to pre-migration for all 4 modules
- [ ] No RPC errors (`submit_leave_request`, `submit_correction_request`, `submit_asset_request`, `fulfill_asset_request`, `create_contract`, `provision_person_for_user`)
- [ ] No data-integrity issues (row counts match, no orphaned rows, no duplicate ACTIVE links)
- [ ] No application-compatibility issues found reading `*.employee_id` (still present, unchanged) or the new `*.hr_employee_id` columns

## 9. Confirmation

- [ ] Migrations 001-010 applied successfully
- [ ] All validation checks passed (or issues resolved and re-tested clean)
- [ ] EMS functional testing complete against the real migrated environment
- [ ] Regression tests pass for all 4 existing modules
- [ ] **Migration 011 remains excluded — not applied, not modified**

Report prepared: `___________` (date)
