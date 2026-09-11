# Assets Module — Apply Checklist

Team lead approved (2026-09-xx): "I will review it, you can proceed, and
make sure to take backup before you start implementation." Nothing from
this module has been applied to Supabase yet — this checklist starts
from zero, same discipline as Attendance Corrections.

## Step 1 — Backup

```powershell
pg_dump "postgresql://postgres.kjjeeoeaugrlmmuxpjjf:<YOUR_ENCODED_PASSWORD>@aws-0-<region>.pooler.supabase.com:5432/postgres" --schema=core --schema=workflow --schema=leave --schema=attendance --schema=assets --file=pre_assets_backup.sql
```
- Use the **Session Pooler** connection string (Direct connection resolves IPv6-only and fails on this network — already hit and solved once).
- Percent-encode the password if it has special characters (`@`→`%40`, `#`→`%23`, `/`→`%2F`, etc.).
- Confirm the output file is non-empty before continuing.

## Step 2 — Pre-apply snapshot

Run in the Supabase SQL Editor, save the output:
```sql
SELECT 'workflow_definitions' AS "table", count(*) FROM workflow.workflow_definitions
UNION ALL SELECT 'core.permissions', count(*) FROM core.permissions
UNION ALL SELECT 'core.role_permissions', count(*) FROM core.role_permissions
UNION ALL SELECT 'leave.leave_requests', count(*) FROM leave.leave_requests
UNION ALL SELECT 'attendance.correction_requests', count(*) FROM attendance.correction_requests;
```

## Step 3 — Apply migrations, in order, one file per SQL Editor query

From `supabase/migrations/phase_5_assets_module/`:
1. `001_assets_schema.sql`
2. `002_assets_rls_grants.sql`
3. `003_assets_submit_and_fulfill_request.sql`
4. `005_assets_permissions_seed.sql`
5. `006_asset_categories_seed.sql` — **note:** this file requires setting the admin session first (`set_config` line at its top) — it is NOT a bare migration, same actor-integrity constraint as everything else. Run its full contents including that line as one paste.

**Skip `004` as a standalone run** — it only defines the seed function; it gets called (not just created) in Step 5 below. If any file errors, stop and do not proceed to the next one.

## Step 4 — Post-apply regression check

Re-run Step 2's query. Every existing row count must be identical (no schema outside `assets` should change from these migrations). Then confirm the new schema:
```sql
SELECT schemaname, tablename, rowsecurity FROM pg_tables WHERE schemaname = 'assets';
-- expect 4 rows (asset_categories, assets, asset_requests, asset_assignments), all rowsecurity: true
```

## Step 5 — Bootstrap the workflow (grant ASSET_MANAGE + activate)

Run `TEST_bootstrap_assets_workflow.sql` in full, as one paste. Unlike Leave/Attendance, this activates immediately — no placeholder-swap step, because the approver is resolved by the `ASSET_MANAGE` **permission**, not a fixed user or role name. Expect the verification query to show `status: ACTIVE`, `assignee_type: PERMISSION`, `permission_code: ASSET_MANAGE`, and `local_test_admin_has_asset_manage: true`.

## Step 6 — End-to-end proof

Run `TEST_submit_approve_fulfill_asset_request.sql` in full, as one paste. This submits a request as the test employee, approves it as `LOCAL_TEST_ADMIN` (a real, loggable-in account — unlike `test-admin`), and fulfills it with a sample laptop unit. Expect `request_status: FULFILLED`, `asset_status: ASSIGNED`, and a real `assigned_at` timestamp.

Report the output of Steps 1 (file exists, non-empty), 4, 5, and 6 back for confirmation — same evidence standard as every prior module.
