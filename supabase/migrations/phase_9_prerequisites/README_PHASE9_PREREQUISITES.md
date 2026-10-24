# Phase 9 prerequisites (P01-P06) - apply, test, rollback order

**Status (2026-10-22):** P01-P06 are applied and verified on the scratch/Track B database; P05 and P06 approved by the team lead. Track A (fresh database: apply, full rollback, exact-restoration proof, re-apply) is still required before final acceptance. Work lives on branch `feature/phase-9-prerequisites`; do not merge until Track A is complete.

## Complete apply and test order (Track B, one paste each; run each file whole)
1. `P01_shared_privilege_hardening.sql` -> `TEST_P01_...`
2. `P02_assets_return_asset.sql` -> `TEST_P02_assets_return_asset.sql`
3. `P03_contracts_termination_and_guard.sql` -> `TEST_P03_contracts_termination_and_guard.sql`  (**pre-P06 acceptance test**: it asserts that a direct contract update by CONTRACT_MANAGE works, which P06 intentionally removes; run it before P06 and keep it that way)
4. `P04_hr_employee_status_history_and_termination.sql` -> `TEST_P04_hr_status_history_and_termination.sql`
5. `P05_privilege_hygiene_and_request_insert_closure.sql` -> `TEST_P05_privilege_hygiene_and_request_insert_closure.sql`
6. `P06_contracts_rpc_only_and_asset_status_guard.sql` -> `TEST_P06_contracts_rpc_only_and_asset_status_guard.sql`
7. Post-P06 regression: `TEST_P9_regression_contract_lifecycle.sql`, `TEST_P02_assets_return_asset.sql` (both are written to pass before and after P06), plus the workflow tests `supabase/tests/007_workflow_contract_tests.sql` then `008_workflow_rls_tests.sql` (008 drops the results table and helper functions when green).
After each migration: `NOTIFY pgrst, 'reload schema';`. Tests end in a result table and raise on any FAIL; a PASS completes normally.

## Rollback order (Track A: fresh database, migrations only, NO test files)
`P06 -> P05 -> P04 -> P03 -> P02 -> P01`. Every rollback has a pre-flight (requires the post-apply state) and a post-check (proves exact restoration, including policy roles/expressions, per-relation grants and function-body hashes). Verify the exact pre-state, then re-apply P01-P06 and run the final post-P06 regression set.

## Evidence scripts (read-only / rolled back)
- `PRE_P05_bypass_evidence_tests.sql` - captured the vulnerable state before P05 (direct INSERT on the three request tables; CONTRACT_MANAGE and ASSET_MANAGE direct writes; live policy baseline). Results: `evidence/PRE_P05_evidence_results.md`.
- `PRE_P06_bypass_evidence_tests.sql` - remaining baseline before P06 (contract_versions writes, asset INSERT as ASSIGNED, asset hard DELETE).
- `evidence/wider_grants_inventory.md` - the per-table grants inventory.

## P05 / P06 notes
- P05: closes direct INSERT on leave.leave_requests, attendance.correction_requests, assets.asset_requests (policy and grant); revokes TRUNCATE/TRIGGER/REFERENCES on 14 more tables; 5 approval/balance views become SELECT-only. Pre-flight asserts exact signatures, policy definitions, privileges (PUBLIC via aclexplode), RLS state.
- P06: contracts RPC-only (hr.contracts / hr.contract_versions lose INSERT/UPDATE/DELETE and the *_manage policies); assets: no hard DELETE, entering/leaving ASSIGNED only through fulfill_asset_request / return_asset via the Assets-owned `assets._sanctioned_transitions` ledger (transaction + asset + target bound, append-only); fulfill_asset_request now bumps assets.version once. Pre-flight pins the baseline function bodies by hash.
- Test edits so older tests run before and after P06: TEST_P9 step 3 accepts privilege denial (42501) or the P03 guard message; TEST_P02 adds a sanction for ASSIGNED fixtures when the ledger exists.
- Not changed here: assets.assets SELECT visibility (separate small change, pending).

---
## Original P01-P04 notes (unchanged below)


Team-lead sequence: P01 shared privilege hardening -> P02 Assets return -> P03 Contracts termination + guard -> P04 HR employee history + sanctioned termination + guard -> regression of existing modules -> then Offboarding 001.

## Apply and test (Track B database), in this order, one paste each
1. `P01_shared_privilege_hardening.sql`, then `TEST_P01_shared_privilege_hardening.sql`
2. `P02_assets_return_asset.sql`, then `TEST_P02_assets_return_asset.sql`
3. `P03_contracts_termination_and_guard.sql`, then `TEST_P03_contracts_termination_and_guard.sql`
4. `P04_hr_employee_status_history_and_termination.sql`, then `TEST_P04_hr_status_history_and_termination.sql`
After each migration: `NOTIFY pgrst, 'reload schema';`. Each test ends with a `99-summary` ALL PASS row and raises on any FAIL (a raise rolls the whole script back).

## Rollback order (Track A: fresh database, run migrations only, NO test files)
`P04 -> P03 -> P02 -> P01`. P03's rollback refuses to run while P04 objects exist. Verify the exact pre-state, then re-apply P01-P04.

## Regression of existing modules (after P04)
1. Re-run the whole Phase 8 suite `TEST_onboarding_full_flow.sql` (it inserts employees through confirm_employee_hire, which now passes through the new employee triggers). Remove the candidate person link first/after as before.
2. UI: Leave, Attendance, Assets, Contracts pages load.
3. UI: create a contract and approve it (the workflow trigger moves PENDING_APPROVAL -> ACTIVE; must be unaffected by the TERMINATED guard).
4. UI: submit and approve one Assets request, then fulfil it.
5. Existing real rows untouched: the three real contracts stay ACTIVE, the two real asset assignments stay open, all employees keep their status (the tests assert this).

## Design decisions to flag to the team lead
- **Sanction ledger instead of a session setting.** The TERMINATED guards (contracts, employees) accept a change only if the sanctioned function wrote a row to `hr._sanctioned_transitions` for that entity in the same transaction. That table has no privileges or policies for application roles and is immutable, so it cannot be forged by `authenticated` (a GUC can).
- **`hr.terminate_contract` and `hr.terminate_employee` are internal-only** (EXECUTE revoked from PUBLIC/anon/authenticated). They are to be called from `offboarding.complete_offboarding()` (SECURITY DEFINER, owner-owned), which performs the caller's authorization. They require an authenticated session only so the actor is recorded.
- **Employees terminal guard:** a TERMINATED employee cannot leave that state (rehire is out of scope). ACTIVE <-> ON_LEAVE and all other edits are untouched.
- **History is automatic** for every status change (insert and update), not only terminations; existing employees are backfilled with one BACKFILL row each. No reason text column exists.
- **Version handling (team-lead rule):** every real state change increments `version` exactly once on each row it changes (assignment + asset; contract + closed contract version; employee). Replay = no increment; rejected = no change. Asserted exactly in the tests.
- **Sanction binding:** the guards accept a sanction only if it matches kind + entity + target status + the current transaction id; the stale/mismatched cases are asserted in TEST_P03 and TEST_P04 (check 21).
- **One history path (P04):** `terminate_employee()` writes the SANCTIONED_TERMINATION row first; the AFTER UPDATE trigger finds a row with the same employee, transaction id, new status and source and inserts nothing, so a termination yields exactly one row. The trigger is the only writer for every other status change.
- **Contract termination date rule:** `effective_to = LEAST(existing effective_to, termination date)`, so termination never extends a version that already ended; replay must use the same date (mismatch error otherwise); no new contract version is created.
- **Test fixtures:** P02 and P03 remove their fixtures. P04's fixtures (people/employees) are permanent because the history is immutable; they are named "P04 TEST ..." with @example.invalid emails. The immutable ledger rows from P03/P04 tests also remain.
- **SQL editor transaction caveat:** a sanction is valid per entity and per transaction; the editor runs a script as one transaction, so the tests use different fixtures for guarded direct attempts and sanctioned calls.
- **Not changed:** DELETE/INSERT/UPDATE grants on the five shared tables (P01 only removes TRUNCATE/TRIGGER/REFERENCES, as instructed).
