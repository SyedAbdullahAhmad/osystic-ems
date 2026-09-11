# Contracts Module — Apply Checklist

Team lead approved (2026-09-10): design notes finalized and confirmed,
both documented defaults (§4(a)/(b) of the design notes) accepted,
instructed to share migration files and validation/test results after
implementation. Nothing from this module has been applied to Supabase
yet — this checklist starts from zero, same discipline as Assets.

## Step 1 — Backup

```powershell
pg_dump "postgresql://postgres.kjjeeoeaugrlmmuxpjjf:<YOUR_ENCODED_PASSWORD>@aws-0-<region>.pooler.supabase.com:5432/postgres" --schema=core --schema=workflow --schema=leave --schema=attendance --schema=assets --schema=hr --file=pre_contracts_backup.sql
```
- Session Pooler connection string, same as every prior backup.
- Percent-encode the password if it has special characters.
- Confirm the output file is non-empty before continuing.

## Step 2 — Pre-apply snapshot

Run in the Supabase SQL Editor, **save the output this time** — this was
missed for Assets and had to be reasoned around after the fact instead
of directly diffed. Don't skip it again.
```sql
SELECT 'workflow_definitions' AS "table", count(*) FROM workflow.workflow_definitions
UNION ALL SELECT 'core.permissions', count(*) FROM core.permissions
UNION ALL SELECT 'core.role_permissions', count(*) FROM core.role_permissions
UNION ALL SELECT 'leave.leave_requests', count(*) FROM leave.leave_requests
UNION ALL SELECT 'attendance.correction_requests', count(*) FROM attendance.correction_requests
UNION ALL SELECT 'assets.asset_requests', count(*) FROM assets.asset_requests;
```

## Step 3 — Apply migrations, in order, one file per SQL Editor query

From `supabase/migrations/phase_6_contracts_module/`:
1. `001_contracts_schema.sql`
2. `002_contracts_rls_grants.sql`
3. `003_contracts_create_and_submit_request.sql`
4. `005_contracts_permissions_seed.sql`

**Skip `004` as a standalone run** — same convention as every prior
module, it only defines the seed function; it gets called (not just
created) in Step 5 below.

There is **no equivalent of Assets' `006` categories seed** — flagging
so this isn't mistaken for a missed step. `contract_type` is a plain
enum here, not a lookup table, so there's nothing to seed. If any file
errors, stop and do not proceed to the next one.

## Step 4 — Post-apply regression check

Re-run Step 2's query — **compare directly against the saved output
this time**. Every existing row count must be identical (no schema
outside `hr` should change from these migrations). Then confirm the new
schema:
```sql
SELECT schemaname, tablename, rowsecurity FROM pg_tables WHERE schemaname = 'hr';
-- expect 3 rows (contracts, contract_versions, contract_requests), all rowsecurity: true
```

## Step 5 — Bootstrap the workflow (grant CONTRACT_MANAGE + activate)

Run `TEST_bootstrap_contracts_workflow.sql` in full, as one paste. Same
as Assets, this activates immediately — permission-based assignee, no
placeholder-swap step. Expect the verification query to show
`status: ACTIVE`, `assignee_type: PERMISSION`,
`permission_code: CONTRACT_MANAGE`, and
`local_test_admin_has_contract_manage: true`.

## Step 6 — End-to-end proof

Run `TEST_create_approve_contract.sql` in full, as one paste. This
creates AND approves a contract as the same account, `LOCAL_TEST_ADMIN`
— expected, not a bug, since this slice has no segregation-of-duties
split (see the script's own header). Expect `status: ACTIVE`, a set
`current_version_id`, and the approval-history view showing the
transition with `LOCAL_TEST_ADMIN` as actor.

Report the output of Steps 1 (file exists, non-empty), 4, 5, and 6 back
for confirmation — same evidence standard as every prior module. Once
confirmed, this is the point to share migration files + these results
with the team lead, per their explicit request.
