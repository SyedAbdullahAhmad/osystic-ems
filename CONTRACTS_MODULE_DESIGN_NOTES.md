# Contracts Module — Design Notes (Finalized, Pre-Migration)

Status: **decisions received from team lead (2026-09-10), design
finalized below.** Two remaining points were resolved with a documented
default rather than sent back for another round-trip — flagged clearly
as such, not silently assumed, and both are low-risk/reversible if
wrong. Nothing has been written or applied yet.

## 1. Scope

`hr.contracts` + `hr.contract_versions` + a new `hr.contract_requests`
link table (workflow integration point, same role as
`asset_requests`/`leave_requests`/`correction_requests`).
`hr.employment_terms` / `hr.compensation_term_refs` stay out of scope —
separate concern, future module.

`hr.contracts`: `employee_id`, `contract_number` (unique),
`contract_type`, `current_version_id`, `status`, standard audit columns.

`hr.contract_versions`: `contract_id`, `version_no`, `effective_from`,
`effective_to`, `document_file_id` (nullable), `notes`, unique on
`(contract_id, version_no)`.

## 2. Decisions from team lead

- **Initiator: HR/Admin only.** Employee-initiated flow (e.g.
  amendments) explicitly out of scope for this slice.
- **Approver: permission-based, `CONTRACT_MANAGE`.** No manager/org-chart
  dependency — same clean pattern as `ASSET_MANAGE`, not the placeholder
  workaround Leave/Attendance needed.
- **`document_file_id`: optional/nullable.** Contract can be created with
  or without a file attached.
- **`contract_type` (real enum values):**
  `PERMANENT`, `FIXED_TERM`, `PROBATION`, `INTERNSHIP`, `CONTRACTOR`
- **`status` (real enum values):**
  `DRAFT`, `PENDING_APPROVAL`, `APPROVED`, `REJECTED`, `ACTIVE`,
  `EXPIRED`, `TERMINATED`
- Add `contract_requests` link table + apply the established FK
  corrections (`hr.employees.id` → `auth.users(id)`,
  `core.profiles.id` → `auth.users(id)`, same as every prior module).

## 3. Gaps vs. the DBML — resolution

1. **`employee_id`, `manager_employee_id` reference `hr.employees.id`**,
   which doesn't exist — `auth.users(id)` directly, same fix as
   Leave/Attendance/Assets.
2. **`created_by`/`updated_by` reference `core.profiles.id`** — changed
   to `auth.users(id)`, consistent with every other module.
3. **No workflow integration in the draft** — resolved by adding
   `hr.contract_requests`, same role as `asset_requests` etc.
4. **`current_version_id` circular reference** — resolved via §4(a)
   below.
5. **`document_file_id`** — resolved: nullable, optional, per team
   lead's decision above. No file-storage bucket/upload mechanism is
   being built in this slice — the column just holds a reference for
   whenever that exists; leaving it unused is fine for now.

## 4. Two points resolved with a documented default, not escalated

**(a) `current_version_id` circular reference.** Resolving via a direct
nullable FK, set by the create-contract RPC itself in the same
transaction as the version insert (`INSERT contracts` →
`INSERT contract_versions` → `UPDATE contracts.current_version_id`) —
not a computed view. Simpler given there's exactly one write path in
this slice.

**(b) The `APPROVED` → `ACTIVE` transition.** `status` deliberately lists
`APPROVED` and `ACTIVE` as two separate values, and `contract_versions`
has `effective_from`/`effective_to` dates — so there's a real question
of whether activation is automatic on approval, or gated by
`effective_from` being reached (a new-hire contract approved today but
starting next Monday shouldn't necessarily read as ACTIVE today).

**Default for this slice:** the workflow-status trigger flips
`contract_requests.request_status` and `hr.contracts.status` straight to
`ACTIVE` on approval — same direct-flip mechanism as Leave/Attendance,
no separate manual step (unlike Assets' fulfillment step, which exists
because a *specific physical unit* needs manual picking; nothing
analogous blocks a contract from activating automatically). Date-gated
activation (only going `ACTIVE` once `effective_from` arrives, via a
scheduled job or computed view) is flagged as a natural follow-up, not
built now.

**Also default, not separately escalated:** creation and approval both
gate on the single `CONTRACT_MANAGE` permission for this slice — no
segregation-of-duties split (a different permission for "may draft" vs
"may approve"). Real compliance processes often want that split; noting
it as a plausible future enhancement rather than building it
speculatively now.

`EXPIRED`/`TERMINATED` are out of scope for this slice's RPCs — they
exist in the enum for completeness/future work, same as how Assets left
`IN_REPAIR`/`RETIRED` unused by any RPC in its first pass.

## 5. Proposed file plan (not yet written)

Mirroring Assets' migration file shape:
1. `001_contracts_schema.sql` — schema, enums, 3 tables
2. `002_contracts_rls_grants.sql` — RLS, grants, approval-history view
3. `003_contracts_create_and_submit_request.sql` — the create+submit RPC
   (contract + v1 + request + `workflow.start_approval_request()` in one
   call, HR/Admin-only via `CONTRACT_MANAGE`) + the workflow-status
   trigger (direct flip to ACTIVE/REJECTED, per §4(b) above)
4. `004_contract_request_workflow_definition_SEED.sql` — seed function
   only, called via bootstrap test, not standalone (same convention)
5. `005_contracts_permissions_seed.sql` — `CONTRACT_MANAGE`,
   `CONTRACT_VIEW_ALL`
6. No categories-style seed file needed — `contract_type` is a plain
   enum here, not a lookup table like Assets' categories, so there's
   nothing equivalent to seed. Flagging the difference so it isn't
   mistaken for a missed step later.

No remaining blockers I'm aware of. Ready to move to migrations once §4's
two defaults are confirmed acceptable — either directly, or after one
more pass by the team lead if preferred before SQL gets written.
