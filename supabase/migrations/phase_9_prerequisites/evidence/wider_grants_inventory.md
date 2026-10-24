# Wider grants inventory (read-only) - test database

Scope: schemas core, hr, workflow, leave, attendance, assets, onboarding, audit.
Roles checked: anon, authenticated. **anon holds no grants on any table in these schemas.**
RLS is **enabled on every base table and forced on none** (rls_forced = false everywhere).
Nothing was revoked or changed. Live policies were read from pg_policies; live triggers from pg_trigger.

Classification key: **HYGIENE** = unneeded privilege, not reachable from the app | **DB-ROLE** = reachable only with a direct database connection as the role | **APP BYPASS** = reachable through the application API.
(PostgREST only issues SELECT/INSERT/UPDATE/DELETE, so TRUNCATE, TRIGGER and REFERENCES are never app-reachable.)

## A. TRUNCATE, TRIGGER, REFERENCES still granted (14 tables)

| Schema.table | Role | Unexpected privilege | RLS enabled | RLS forced | Reachable via app? | Class |
|---|---|---|---|---|---|---|
| assets.asset_categories | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE |
| assets.asset_requests | authenticated | TRUNCATE, TRIGGER, REFERENCES (+ INSERT, see B) | yes | no | no (INSERT: yes) | HYGIENE / DB-ROLE |
| attendance.attendance_days | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE |
| attendance.correction_requests | authenticated | TRUNCATE, TRIGGER, REFERENCES (+ INSERT, see B) | yes | no | no (INSERT: yes) | HYGIENE / DB-ROLE |
| core.departments | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE |
| core.organizations | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE |
| core.people | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE (sensitive) |
| core.person_user_links | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE (sensitive) |
| hr.contract_requests | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE |
| leave.leave_accruals | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE |
| leave.leave_adjustments | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE |
| leave.leave_ledger | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE (sensitive: TRUNCATE skips the immutability trigger) |
| leave.leave_requests | authenticated | TRUNCATE, TRIGGER, REFERENCES (+ INSERT, see B) | yes | no | no (INSERT: yes) | HYGIENE / DB-ROLE |
| leave.leave_types | authenticated | TRUNCATE, TRIGGER, REFERENCES | yes | no | no | HYGIENE / DB-ROLE |

## B. Direct INSERT on request tables (application-accessible)

| Table | Policy | Guard | Result |
|---|---|---|---|
| leave.leave_requests | leave_requests_insert: WITH CHECK (employee_id = auth.uid()) | only created_by/updated_by triggers, no status guard | **APP BYPASS - CONFIRMED** (direct insert with request_status='APPROVED' succeeded; rolled back) |
| attendance.correction_requests | correction_requests_insert: same check | same triggers | **APP BYPASS - expected, test pending** |
| assets.asset_requests | asset_requests_insert: same check | same triggers | **APP BYPASS - expected, test pending** |

Context: no UPDATE policy on these tables, so inserted rows cannot be edited by the user. Frontend (79 files) has no direct writes; submit_leave_request / submit_correction_request / submit_asset_request are all SECURITY DEFINER.

## C. Approval/balance views (5)

| View | Role | Unexpected privilege | RLS | Reachable via app? | Class |
|---|---|---|---|---|---|
| leave.v_leave_balances | authenticated | INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES | n/a (view, security_invoker=true) | not meaningfully (plain views, runs under caller RLS) | HYGIENE |
| leave.v_leave_request_approvals | authenticated | same | n/a | same | HYGIENE |
| attendance.v_correction_request_approvals | authenticated | same | n/a | same | HYGIENE |
| assets.v_asset_request_approvals | authenticated | same | n/a | same | HYGIENE |
| hr.v_contract_approvals | authenticated | same | n/a | same | HYGIENE |

## D. Test artefact

| Table | Role | Privilege | RLS | Notes | Class |
|---|---|---|---|---|---|
| workflow._test_results | authenticated | INSERT | disabled | 50 rows from Phase 2 suites; created and granted by supabase/tests/007_workflow_contract_tests.sql, so a one-off drop returns on the next run | HYGIENE (INSERT only, no SELECT grant) |

## E. Already correct

- P01 tables (hr.employees, hr.contracts, hr.contract_versions, assets.assets, assets.asset_assignments): only SELECT/INSERT/UPDATE/DELETE remain.
- hr.employee_status_history and onboarding.onboarding_records: SELECT only.
- workflow tables: SELECT only, or INSERT/SELECT/UPDATE on config tables; no DELETE anywhere.
- Write grants on tables whose only policies are SELECT (leave_ledger, leave_accruals, leave_adjustments, attendance_days, contract_requests, asset_assignments) are inert under RLS.

## F. Observations for review
- ALL policies on hr.contracts, hr.contract_versions, assets.assets let CONTRACT_MANAGE / ASSET_MANAGE holders write directly (to be checked in the Contracts regression).
- assets_select and asset_categories_select are `true`: every logged-in user can read the full asset inventory.
