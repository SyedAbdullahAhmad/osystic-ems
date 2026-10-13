# Onboarding Module — Proposal v2

Status: all 4 open questions from v1 now **confirmed** by Arslan, plus
the state-transition/consistency rules he asked for added below (§6.2,
new). Per his reply: *"With those decisions and the state-transition
rules made explicit, I'm happy with the design and you can proceed to
the migration/build phase."* This version is that final design — ready
for migrations once read through.

Sections 1-5 are unchanged from v1 (architecture, flow, table shape,
workflow pattern, permissions, RLS) except where a decision below
updates them. Confirmed decisions folded in below rather than left as
open questions.

---

## 1-5. (unchanged from v1 — see that file for full detail)

Core architecture confirmed as-is: `core.people`/`CANDIDATE` reused via
the already-live `provision_person_for_user()`; `onboarding.onboarding_records`
as the module's own business table; `PERMISSION`-type workflow assignee
(`ONBOARDING_MANAGE`) following the Assets/Contracts precedent, not the
Leave/Attendance one.

## 6. Confirmed decisions (were v1's open questions)

**1. `CANDIDATE` → `EMPLOYEE` transition: a separate, explicit HR
action — not automatic on approval or on first login.**
Approval and actually becoming an employee are different business
events (a candidate can be approved and still decline, withdraw, or
have their start date postponed; first login is an identity event, not
an employment event). Confirmed flow:

```
CANDIDATE → onboarding approved → signup/linking → actual hire confirmed by HR → EMPLOYEE + hr.employees
```

The exact HR action/date is finalized at implementation time, but
neither approval nor login itself triggers the conversion. Implemented
as one RPC, `onboarding.confirm_employee_hire()` — see §6.2 for why it
must be one atomic operation.

**2. Rejected/withdrawn candidates: archived, not deleted — but as a
separate, intentional action, not an automatic side effect.**
Preserves `core.people` identity/history (consistent with the
shared-core "never delete identity history" principle) and keeps the
onboarding record itself at its terminal `REJECTED`/`WITHDRAWN` status.
Archiving the *person* (`core.people.status = 'ARCHIVED'`) is a
**separate action** an HR user takes deliberately — never cascaded
automatically from an onboarding record reaching a terminal status,
since that same person might have another active relationship or
workflow elsewhere in the system that a silent archive would break.

**3. No Onboarding-specific department seed data.**
`core.departments` stays the single canonical, shared-core-owned
source. If the authoritative department list exists already, it gets
seeded centrally there — not invented here just to satisfy this
module. Onboarding keeps its plain `department_id` reference and
simply has no seed data of its own; populated once the canonical list
is confirmed, independent of this module's build.

**4. `ONBOARDING_MANAGE` is a new permission, not a reuse of
`PEOPLE_MANAGE`.**
Onboarding/recruiting authorization can legitimately differ from
general people administration — reusing `PEOPLE_MANAGE` would couple
two different authorization boundaries. Confirmed:
`assignee_type = 'PERMISSION'`, `permission_code = 'ONBOARDING_MANAGE'`.

## 6.1 Updated table shape

One addition to `onboarding.onboarding_records` from v1: a `HIRED`
status is needed to represent decision #1's fourth, distinct step (HR
confirming the actual hire) — `APPROVED` alone can no longer represent
that.

```
id                  uuid, pk
person_id           uuid, NOT NULL, references core.people(id)
position_title      varchar(255)
department_id       uuid, references core.departments(id)
proposed_start_date date
status              enum: DRAFT | SUBMITTED | APPROVED | REJECTED | WITHDRAWN | HIRED
workflow_request_id uuid, references workflow.approval_requests(id)
submitted_at        timestamptz
hired_at            timestamptz  -- NEW: set only by confirm_employee_hire()
hired_by            uuid, references auth.users(id)  -- NEW: the HR actor, distinct from created_by/updated_by
created_at/updated_at/created_by/updated_by/version  (standard)
```

Also proposing (not explicitly asked, flagged as an addition worth
confirming): a partial unique index,
`UNIQUE (person_id) WHERE status IN ('DRAFT','SUBMITTED','APPROVED')` —
prevents a candidate from having two concurrent, un-terminated
onboarding attempts at once. This index itself doesn't prevent a person
from having multiple terminal (`REJECTED`/`WITHDRAWN`/`HIRED`) records
over time at the SCHEMA level — but that's not the same as rehire being
supported end-to-end in v1.

> **CORRECTION (per Arslan's implementation review, item 11):**
> rehire is NOT actually supported by the v1 implementation as built,
> despite the "e.g. rehire scenarios" phrasing above. The create RPC
> (`create_and_submit_onboarding_request`, 003) always creates a brand
> new `core.people` row and will hit `core.people`'s own unique index
> and fail outright if the email already belongs to an existing person
> — it never attempts to match/reuse one. The hire RPC
> (`confirm_employee_hire`, 006) explicitly rejects proceeding if an
> `hr.employees` row already exists for the person. So: **rehire /
> existing-person matching is explicitly out of scope for Phase 8 v1.**
> The schema doesn't structurally forbid a future version from adding
> it (that's what the index above is actually for), but no current code
> path supports taking a former employee through onboarding again as
> the same person — attempting to do so today just fails on the
> duplicate-email check, which is acceptable v1 behavior (forces manual
> resolution) but should not be read as "rehire works." A real rehire
> workflow — matching an existing `core.people` row by email/identity,
> deciding what happens to their existing (terminated) `hr.employees`
> row, etc. — is a later, explicit, separately-designed feature, not an
> accidental byproduct of this index.

## 6.2 State-transition rules & cross-table consistency invariants

This is the piece requested before migrations get written — making
explicit exactly which combined states across `onboarding_records.status`,
`core.people.person_type`, and `hr.employees` are valid, so the
inconsistent states named (an approved record with `person_type =
EMPLOYEE` but no `hr.employees` row; a withdrawn record that already
converted the person) are structurally prevented, not just avoided by
convention.

### `onboarding_records.status` state machine

```
DRAFT ──▶ SUBMITTED ──▶ APPROVED ──▶ HIRED  (terminal)
              │             │
              ▼             ▼
          REJECTED      WITHDRAWN
          (terminal)    (terminal)
```

Allowed transitions only:
- `DRAFT → SUBMITTED`
- `SUBMITTED → APPROVED` (workflow approval)
- `SUBMITTED → REJECTED` (workflow rejection — only reachable pre-approval)
- `SUBMITTED → WITHDRAWN` or `APPROVED → WITHDRAWN` (candidate withdraws, before or after approval, but only before hire is confirmed)
- `APPROVED → HIRED` (via `confirm_employee_hire()` only — the *only*
  path to `HIRED`; cannot be reached from `SUBMITTED` directly)

Forbidden, enforced at the database level (`CHECK`/trigger on
`onboarding_records`, guarding every `UPDATE` to `status`), not just by
convention:
- Any transition **out of** `HIRED`, `REJECTED`, or `WITHDRAWN` — all
  three are terminal. This is exactly what prevents "a withdrawn record
  that already converted the person": once `HIRED`, it can never become
  `WITHDRAWN`, and the reverse is structurally impossible too since
  `WITHDRAWN` is terminal.
- `APPROVED → REJECTED` — rejection is only meaningful pre-approval;
  post-approval non-continuation is `WITHDRAWN`.
- Any direct jump skipping `APPROVED` on the way to `HIRED`.

### Cross-table invariants (the actual consistency guarantee)

| Invariant | Enforcement |
|---|---|
| `hr.employees` row exists for a person **if and only if** `core.people.person_type = 'EMPLOYEE'` for that person | `confirm_employee_hire()` is the **only** RPC permitted to set `person_type = 'EMPLOYEE'`, and it does so in the **same transaction** as creating the `hr.employees` row and setting `onboarding_records.status = 'HIRED'` — all three writes succeed together or none do. No other code path may set `person_type = 'EMPLOYEE'`. |
| `onboarding_records.status = 'HIRED'` **implies** `core.people.person_type = 'EMPLOYEE'` **and** a corresponding `hr.employees` row exists | Same atomic RPC as above — `HIRED` is only ever written alongside the other two, never independently. |
| `onboarding_records.status = 'WITHDRAWN'`/`'REJECTED'` can **never** occur on a record that already reached `HIRED` | `HIRED` is terminal in the state machine above (DB-level guard) — structurally impossible, not just application-level discipline. |
| Archiving `core.people.status = 'ARCHIVED'` is **never** an automatic consequence of `onboarding_records` reaching `WITHDRAWN`/`REJECTED` | No trigger connects the two tables for this; archiving is its own separate, explicit RPC/action a person can call independently, per decision #2. |
| At most one non-terminal onboarding record per person | Partial unique index, §6.1. |

**Open implementation detail, flagged rather than silently decided**:
should `confirm_employee_hire()` *require* the candidate to already have
an `ACTIVE` `core.person_user_links` row (i.e. they've actually signed
up) before HR can confirm the hire, or is that just the expected
typical order without being a hard gate? Recommending **soft** (allow
it either order, since Arslan's own description separates "signup/
linking" and "hire confirmed by HR" as distinct events without stating
one strictly gates the other) — but calling this out explicitly for
confirmation before the RPC is written, rather than assuming either
way.

## 7. What this proposal deliberately does NOT cover

Unchanged from v1: payroll/compensation fields, background-check
integration, equipment pre-provisioning — all out of scope for this
slice.
