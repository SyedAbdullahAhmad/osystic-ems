# Assets Module — Migration Proposal (Draft, Not Yet Applied)

Written and ready for review, same process as Attendance Corrections:
submit for review before applying. **Nothing in this package has been run
against Supabase yet.**

## 1. What this covers

A **request-and-fulfill** slice of asset management: an employee requests
an asset by category, an Asset Manager approves it through the workflow
engine, then hands over a specific physical unit. The DBML's broader
asset lifecycle (usage events, returns, condition verifications, damage
reports, offboarding clearance links) is real future scope, not built
here — same "a slice, not the whole draft" approach used for Attendance
Corrections.

## 2. Why Assets, chosen deliberately

Both Leave and Attendance Corrections hit the same wall: the approver has
to be a `test-admin`/role-name placeholder because there's no HR/
org-structure module to resolve a real manager. Assets doesn't have that
problem — the approver is resolved by **permission** (`ASSET_MANAGE`),
not by a per-employee manager lookup. `workflow.start_approval_request()`
already supports `PERMISSION`-type assignees natively (confirmed against
the actual engine code in `phase_2_workflow_engine`), resolving eligible
approvers dynamically at request time. That means:

- **No placeholder assignee, no version-2-later TODO.** `004`'s seed
  activates the workflow version immediately — the only operational
  precondition is that at least one real user actually holds
  `ASSET_MANAGE`, which is a normal permission grant, not a blocker.
- As a bonus, this also gives us a path to prove an **eligible** approver
  clicking Approve through the real browser UI — something Leave and
  Attendance couldn't do, since `test-admin` has no real login.
  `LOCAL_TEST_ADMIN` (`2d48e4e3-...`) is a real, loggable-in account, and
  the bootstrap script grants it `ASSET_MANAGE`.

## 3. DBML gaps vs. EMS_part2_revised.dbml's assets.* tables

Different shape of issue than Leave/Attendance: the DBML's asset tables
have **no approval_status/approved_by columns at all** — there's simply
no workflow integration in the draft to begin with, and no request stage
either (it jumps straight from an asset existing to it being assigned).
So this isn't "remove a duplicate field," it's "add the integration
point that was never there":

1. **`created_by`/`updated_by`/`assigned_by` referenced `core.profiles.id`**
   in the DBML. Changed to `auth.users(id)`, consistent with every other
   module.
2. **`employee_id` referenced `hr.employees.id`**, which doesn't exist.
   Changed to `auth.users(id)` directly, same deliberate simplification
   as Leave/Attendance.
3. **`assets.asset_requests` doesn't exist in the DBML** — added as the
   actual link to `workflow.approval_requests`, same architectural role
   as `leave_requests`/`correction_requests`.

## 4. Design choices flagged for review

- **Fulfillment is a separate, manual step from approval** — the workflow
  trigger only flips `request_status` to `APPROVED`/`REJECTED`; it does
  *not* auto-pick a physical unit. `fulfill_asset_request()` is a
  separate, `ASSET_MANAGE`-gated RPC that requires explicitly choosing an
  available asset of the right category. Rationale: handing over a
  specific serial-numbered unit is a real logistics decision, and
  auto-assigning risks picking a unit that's actually broken/missing
  despite its DB status, or leaving an approval stuck if none are
  currently `AVAILABLE`.
- **Single-step approval** (`asset_manager_approval` only), same
  reasoning as Attendance's single-step design your team lead already
  approved — proportionate to the request, not a policy decision needing
  multiple sign-offs.

## 5. What's genuinely open

- `ASSET_VIEW_ALL`/`ASSET_MANAGE` still need real `core.roles` mapping
  for production use (the `006a`-style blocker), same as every other
  module — but note this doesn't block *activation* or *testing* the way
  it did for Leave/Attendance, only the eventual "give the real Asset
  Manager role this permission for real" step.
- No frontend built yet — backend-only, matching how Attendance
  Corrections' backend was proposed and reviewed first.
- Sample inventory (`006`'s 3 asset rows) is placeholder test data, not
  real stock — flagged the same way test-fixture data was flagged for
  Leave/Attendance.

## 6. Files in this package

```
supabase/migrations/phase_5_assets_module/
├── 001_assets_schema.sql
├── 002_assets_rls_grants.sql
├── 003_assets_submit_and_fulfill_request.sql
├── 004_asset_request_workflow_definition_SEED.sql
├── 005_assets_permissions_seed.sql
├── 006_asset_categories_seed.sql
├── TEST_bootstrap_assets_workflow.sql
└── TEST_submit_approve_fulfill_asset_request.sql
```

Every referenced `workflow`/`core` table, column, and function
(`start_approval_request`, `process_approval_action`, `can_view_request`,
`has_permission`, `activate_workflow_version`, `workflow_step_assignees`'
`PERMISSION` assignee type) was checked against the actual applied
migration files in `phase_1_foundation`/`phase_2_workflow_engine`, not
assumed.
