# EMS Handoff — Workflow Foundation Complete, Starting Leave Module

Paste this whole document as your first message to the other Claude session,
along with the files listed at the bottom. It covers everything needed to
pick up from here without re-deriving context.

---

## 1. Where things stand (all confirmed via real execution, not assumption)

The centralized `workflow` schema (per your team lead's explicit instruction:
*"Please implement a centralized workflow schema for EMS rather than separate
approval tables inside each module... approval_requests, approval_steps,
approval_actions, delegations, status_history, sla_escalations,
workflow_definitions, workflow_versions, transition_rules"*) is fully built,
tested, and proven:

- Migrations `001`–`006` applied cleanly to the EMS scratch Supabase project
  (`006a` is still blocked — see section 3).
- `007_workflow_contract_tests.sql` and `008_workflow_rls_tests.sql`: **0
  failures, 11 suites, 52 assertions**, verified line-by-line against the
  actual engine code (lifecycle, idempotency/replay, delegation +
  maker-checker, MIN_N/ONE_OF/ALL_OF, SKIP quorum-safety, parallel-stage
  resolution, RLS visibility, version immutability, actor-integrity,
  seed-idempotency/provenance, SLA escalation RPC).
- Full rollback (`006`→`001`) run and **verified clean** via a 7-check query
  (schema gone, seeded permissions gone, all test fixtures gone, shared
  objects like `pgcrypto` and the disposable core/audit stub correctly left
  untouched).
- Full re-apply from scratch, then re-ran 007/008 again on the fresh
  database: same result, 0 failures, every assertion ran fresh (not a
  replay/skip), 52/52.
- **Manual security spot-check: DONE, via a real API client** (not the SQL
  `SET LOCAL ROLE` simulation) — confirmed `start_approval_request()` and
  `process_system_action()` both correctly reject a real, genuinely
  authenticated Supabase user (401/403), not just a simulated SQL role.
  This closes the last item on the execution checklist.

**Your team lead has explicitly signed off on this and given the next
instruction (his words):** *"Please complete the manual security spot-check
first... Once the spot-check is confirmed successful, proceed directly with
the Leave Module (backend + frontend) as the first EMS module on top of the
workflow engine."*

That spot-check is done and confirmed successful. **The next task is the
Leave Module — backend and frontend, working code, not another design
document.** Your team lead has been explicit and repeated about this: *"I
need significantly faster execution and visible implementation progress...
working deliverables, not only documents, regular GitHub commits, visible
module completion."*

## 2. Leave Module data model — this is authoritative, the DBML is stale

Your team lead gave this model explicitly, in these exact words:

- `leave.leave_requests` owns the leave business record
- `leave.leave_requests.workflow_request_id` links to `workflow.approval_requests`
- `workflow.approval_steps` owns runtime approval stages
- `workflow.approval_step_assignees` owns resolved approvers
- `workflow.approval_actions` owns approve/reject/skip action evidence
- `workflow.status_history` owns workflow transition history
- **Leave module owns leave-specific policy validation, balance checks, and
  final leave-ledger effects**
- **Do not maintain a second writable `leave.leave_approvals` table.** If the
  UI needs an approval-history dataset, expose a read-only view joining the
  workflow tables — never duplicate approval records into the leave schema.

**`EMS_part2_revised.dbml` (attached) has NOT been updated to reflect this
and should not be followed as-is for these three specific things:**
1. It still defines a writable `leave.leave_approvals` table — explicitly
   disallowed by the instruction above. Do not create this table.
2. `leave.leave_requests` in the DBML has no `workflow_request_id` column —
   it needs to be added; this is the actual link to the workflow engine.
3. Every `created_by`/`updated_by` column in the `leave.*` tables references
   `core.profiles.id` — this table does not match the confirmed real RBAC
   model (see section 4). Actor columns should reference `auth.users(id)`,
   consistent with every table in the `workflow` schema.

Everything else in the DBML's `leave.leave_types`, `leave.leave_ledger`
(including its important rule: balances are ALWAYS derived as
`SUM(amount_days)` grouped by `(employee_id, leave_type_id)` — no code writes
`available_days`/`used_days` directly anywhere), `leave.leave_accruals`, and
`leave.leave_adjustments` appears consistent with the team lead's model and
can be used as a starting point.

## 3. Still open / blocked (does not block Leave Module work)

- `006a_workflow_role_permission_mapping.sql` still has `<<CONFIRM: ...>>`
  placeholders for real `core.roles.name` values (CTO/System Admin,
  Technical Admin, CEO/Executive) — blocked on Umar/Arslan pulling these
  from Finance's UAT project. Nothing else depends on this.

## 4. RBAC model — resolved, confirmed via real Finance code

Early on, your team lead instructed: *"reuse the Finance RBAC tables exactly
as they currently exist: `core.roles`, `core.permissions`,
`core.role_permissions`, `core.user_roles`."* The entire workflow engine is
built on this.

A later Technology Stack Document from Finance described a *different*
model (a `profiles` table with a role field + boolean permission flags) as
Finance's auth approach. This looked like a conflict, so it was checked
against real Finance code — a Phase 3 migration file defining
`core.has_permission()`, `core.has_permission_with_limit()`,
`core.get_data_scope()`, etc. (attached), which is 100% built on
`core.user_roles`/`core.role_permissions`/`core.permissions`/`core.roles`,
zero mention of `profiles` anywhere.

**Conclusion, already sent to the team lead as an FYI (not a blocker): EMS
stays on the `core.roles`/`permissions`/`role_permissions`/`user_roles`
relational model.** The Technology Stack Document's `profiles`-based
description doesn't reflect what's actually implemented — treat it as
inapplicable to authorization decisions. Do NOT build Leave Module
permission checks against a `profiles` table or boolean flags.

## 5. Frontend/backend stack — confirmed, follow this exactly

Team lead's instruction: *"follow the same frontend/backend stack currently
being used for the Finance System."* Confirmed via the Technology Stack
Document (attached). Adopt exactly:

- Next.js `^16.2.10` (App Router), React/React DOM `^19`, TypeScript `^5`
  (strict mode), Tailwind CSS `^3.4.1` (class-based dark mode)
- `@supabase/supabase-js` `^2.110.5`, `@supabase/ssr` `^0.12.2`
- `@tanstack/react-query` `^5.101.4`, `zod` `^4.4.3`, `date-fns` `^4.4.0`,
  `react-hot-toast` `^2.6.0`, `lucide-react` `^1.22.0`, `next-themes` `^0.4.6`
- Dev: `supabase` CLI `^2.109.1`, `eslint` `^9`, `@types/*` matching React 19
- Env vars: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` in
  `.env.local`. Node 18+. npm as package manager. `app/` directory
  convention. Types centralized in a `types/` directory.
- **Multi-schema Supabase client pattern (important architectural point)**:
  Finance creates one typed client per schema (`supabase` for `public`,
  `financeDB` for `finance`, `auditDB` for `audit`, `reportingDB` for
  reporting views). For EMS, mirror this: a client for `workflow`, and a
  client for the `leave` schema.

**Explicitly do NOT add** (Finance-specific, not baseline requirements —
only add if a real Leave Module need arises): `chart.js`/`react-chartjs-2`/
`recharts`, `jspdf`/`jspdf-autotable`, the AI SDK packages (`@ai-sdk/*`,
`ai`, `@google/generative-ai`), `@react-three/*`/`three`, `core-js`.

## 6. Also needs setting up (repo currently empty)

The GitHub repo exists but currently has no files — only Supabase is
configured in it. There is no frontend yet. Your team lead wants regular
commits as visible proof of progress, so the Leave Module work should be
committed incrementally, not delivered as one giant drop at the end.

---

## Files to attach along with this document

1. **`workflow_migration_AUTHORITATIVE.zip`** — the complete, current,
   tested workflow migration set (`001`–`006a`, `007`/`008`, the disposable
   core/audit stub, rollback + verification scripts). Already given to this
   Claude account previously — confirm it still has it, or re-attach.
2. **`EMS_part2_revised.dbml`** — the EMS schema draft, WITH the three
   staleness caveats from section 2 above kept in mind.
3. **`Technology_Stack_Document_Osystic_Finance__1_.docx`** — the Finance
   stack document referenced in section 5.
4. **The Phase 3 permission-functions file** (the one defining
   `core.has_permission()`, `core.get_user_max_level()`, etc., and the RLS
   policies on `core.permissions`/`core.roles`/`core.role_permissions`/
   `core.user_roles`) — proof for section 4's RBAC conclusion. Re-paste or
   re-attach this if the other Claude account doesn't already have it.
5. **`schema.sql`** — the real, full Finance database schema dump (for
   checking exact column names/types/constraints on any shared `core.*` or
   `auth.*` table the Leave Module touches, same way it was used throughout
   the workflow engine's development).
6. **`OSYSTIC_EMS_Phase0_Architecture_v2.docx`** — original EMS architecture
   document, useful for broader module context (leave sits alongside
   attendance, contracts, onboarding, payroll snapshots, assets, NFC access,
   grievances, offboarding — all meant to share this same workflow engine).
7. **`Conversation.md`** — the full team chat history, for anything not
   captured above.
