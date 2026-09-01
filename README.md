# OSYSTIC EMS

Employee Management System, built on a centralized `workflow` schema
shared by every module (leave, attendance corrections, contracts,
onboarding, payroll snapshots, assets, NFC access, grievances,
offboarding), following the same folder structure and technology stack
as the Finance System.

## Status

- **`supabase/migrations/phase_1_foundation/`**: schemas, extensions,
  helper functions, and now real core RBAC tables (`core.roles`,
  `core.permissions`, `core.role_permissions`, `core.user_roles`) with
  `has_permission()` and related functions matching Finance's actual
  production implementation exactly.
- **`supabase/migrations/phase_2_workflow_engine/`**: complete and
  proven. 007/008 test suites (`supabase/tests/`): 0 failures, 52
  assertions across 11 suites, verified through a full
  apply -> test -> rollback -> verify -> re-apply -> re-test cycle,
  plus a manual security spot-check via a real API client.
- **`supabase/migrations/phase_3_leave_module/`**: backend + frontend
  scaffolded and working. See "Known open items" below before treating
  this as fully usable end-to-end.

## Stack

Next.js (App Router) - TypeScript (strict) - Tailwind CSS v4
(CSS-first config, class-based dark mode) - Supabase
(`@supabase/supabase-js` + `@supabase/ssr`) - TanStack React Query -
Zod - date-fns - react-hot-toast - lucide-react

## Getting started

```bash
npm install
cp .env.example .env.local   # fill in your Supabase project URL + anon key
npm run dev
```

## Applying migrations

In filename order, within each phase folder, in this order:

1. `phase_1_foundation/` - all files EXCEPT none needed skipping here;
   run 001 through 007 in order (003/006/007 may still be placeholders
   pending further modules - check each file's own header).
2. `phase_2_workflow_engine/` - run 001 through 006 in order. **Skip
   `006a`** - still blocked on real `core.roles.name` values for
   CTO/Technical Admin/CEO from Umar/Arslan (Finance's UAT project).
3. `phase_3_leave_module/` - run 001, 002, 003, 006 as normal
   migrations. **`004_leave_workflow_definition_SEED.sql` and
   `005_leave_types_seed.sql` cannot run as plain migrations** - both
   write to actor-integrity-protected tables that require a real
   authenticated session, not a bare service-role script. Read each
   file's header before running it.

After applying, in the Supabase dashboard: **Project Settings -> API ->
Exposed schemas**, confirm `workflow` and `leave` are listed (already
added to `supabase/config.toml` for local dev), then in the SQL Editor:
`NOTIFY pgrst, 'reload schema';`

## Known open items

1. **`006a`** (real role-permission mapping) still blocked on
   Umar/Arslan pulling exact `core.roles.name` values from Finance's UAT
   project.
2. **`phase_1_foundation`'s `core.has_permission(permission_code text)`**
   (1-arg placeholder, always returns `false`) is superseded by the real
   2-arg `core.has_permission(user_id, permission_code)` in
   `005_rls_policies.sql`, but not removed - nothing in this codebase
   calls the old one; safe to delete once confirmed unused elsewhere.
3. **Audit triggers** on the RBAC tables (present in Finance's real
   migration) were intentionally left out of
   `phase_1_foundation/005_rls_policies.sql` - `audit.trigger_audit_log()`
   doesn't exist anywhere in this repo yet. Add once an audit-schema
   migration defines it.
4. **Leave workflow definition is seeded but NOT activated** - real
   manager/HR role assignees need to be wired into
   `workflow_step_assignees` before `workflow.activate_workflow_version()`
   is called. See `004_leave_workflow_definition_SEED.sql`'s NOTICE
   output after running it.
5. **`leave.leave_requests.employee_id` references `auth.users(id)`
   directly** - the original DBML design referenced `hr.employees`,
   which doesn't exist yet. Revisit once an HR/org-structure module
   exists; this is a deliberate, flagged simplification.
6. **`database.types.ts` is hand-written**, not generated - regenerate
   with `npx supabase gen types typescript` once applied to a live
   project.
7. Frontend covers: submit a leave request, view my requests, view
   balance, view/act on a request I'm an approver for, login/signup.
   Not yet built: an admin UI for managing leave types, a dedicated "my
   approvals" inbox view, and org/manager-lookup-based real approver
   assignment.

See `LEAVE_MODULE_HANDOFF.md` for the full architectural context this
was built against.
