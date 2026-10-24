# Pre-P05 evidence: vulnerable state captured before any fix

Date captured: 2026-10-21
Database: test/scratch database (roles LOCAL_TEST_ADMIN, TEST_WORKFLOW_ADMIN). Nothing applied; every test below ran as role `authenticated` inside a DO block that ends with a deliberate exception, so all changes were rolled back.
Scripts: `PRE_P05_bypass_evidence_tests.sql` (Block 1, Block 2, Block 3) plus the A4 block below.
Note: the same account (2d48e4e3-fee2-4034-8b8d-a3cce8298ce2) held both CONTRACT_MANAGE and ASSET_MANAGE during Block 2.

## Block 1: direct INSERT on the three request tables (raw output)

```
ERROR:  P0001: BLOCK 1 RESULTS (rolled back; fixtures used: day=af24d417-9fda-457c-ab2d-776ee0a5c932, category=557de4a1-2fb0-4f28-b660-b86ffd3da9e9, leave_type=be31a304-d473-4725-983f-6b1eb4e4dfe4)
LEAVE: INSERT SUCCEEDED id=3dcb9fdf-69cf-490f-bc17-a389a9aabb45 status=APPROVED
ATTENDANCE: INSERT SUCCEEDED id=b3ed0d1e-4c15-430d-9424-2209ccaea3ba status=APPROVED
ASSETS: INSERT SUCCEEDED id=d7380edd-b9ea-4778-aff7-b3db0cb20fca status=FULFILLED
CONTEXT:  PL/pgSQL function inline_code_block line 40 at RAISE
```

## Block 2: CONTRACT_MANAGE / ASSET_MANAGE direct state changes (raw output)

```
ERROR:  P0001: BLOCK 2 RESULTS (rolled back; contract_manager=2d48e4e3-fee2-4034-8b8d-a3cce8298ce2, asset_manager=2d48e4e3-fee2-4034-8b8d-a3cce8298ce2)
C0 direct INSERT of a DRAFT contract: SUCCEEDED
C1 direct UPDATE DRAFT -> ACTIVE (skipping workflow): rows=1 status_now=ACTIVE
C2 UPDATE to TERMINATED: FAILED P0001 HR_CONTRACT_TERMINATION_NOT_SANCTIONED: contract 0b60ce9d-fe21-457b-a06a-20fcbf90779a can only become TERMINATED through the sanctioned termination function
C4 direct DELETE of the contract: rows=1
C3 direct INSERT of an ACTIVE contract (no workflow): SUCCEEDED
A0 direct INSERT of an AVAILABLE asset (inventory registration): SUCCEEDED
A1 direct UPDATE assets.current_status -> ASSIGNED (no assignment row): rows=1 status_now=ASSIGNED
A3 INSERT asset_assignments: FAILED 42501 (42501 = denied; 23503 = RLS allowed)
A4 direct UPDATE asset_requests -> FULFILLED: rows=0 of 0 visible SUBMITTED (0 of >0 = blocked; 0 of 0 = untested)
A5 direct UPDATE asset_assignments.returned_at: rows=0 of 2 open assignments (0 of >0 = blocked; 0 of 0 = untested)
CONTEXT:  PL/pgSQL function inline_code_block line 101 at RAISE
```

## A4 re-test with a fixture row (raw output)

```
ERROR:  P0001: A4 RESULT (rolled back): rows=0 status_now=SUBMITTED (rows=0 = blocked)
CONTEXT:  PL/pgSQL function inline_code_block line 15 at RAISE
```

## Block 3: live INSERT policy baseline (raw output, 3 rows)

```json
[
  {"schemaname": "assets", "tablename": "asset_requests", "policyname": "asset_requests_insert", "cmd": "INSERT", "permissive": "PERMISSIVE", "roles": "{public}", "qual": null, "with_check": "(employee_id = auth.uid())"},
  {"schemaname": "attendance", "tablename": "correction_requests", "policyname": "correction_requests_insert", "cmd": "INSERT", "permissive": "PERMISSIVE", "roles": "{public}", "qual": null, "with_check": "(employee_id = auth.uid())"},
  {"schemaname": "leave", "tablename": "leave_requests", "policyname": "leave_requests_insert", "cmd": "INSERT", "permissive": "PERMISSIVE", "roles": "{public}", "qual": null, "with_check": "(employee_id = auth.uid())"}
]
```

## Summary

| Test | Result |
|---|---|
| Leave direct INSERT as APPROVED | BYPASS (succeeded) |
| Attendance direct INSERT as APPROVED | BYPASS (succeeded) |
| Assets direct INSERT as FULFILLED | BYPASS (succeeded) |
| Contracts direct INSERT (DRAFT and ACTIVE) | BYPASS (succeeded) |
| Contracts direct UPDATE DRAFT -> ACTIVE | BYPASS (rows=1) |
| Contracts direct DELETE | BYPASS (rows=1) |
| Contracts direct UPDATE -> TERMINATED | blocked (P03 guard) |
| Assets direct UPDATE current_status -> ASSIGNED | BYPASS (rows=1) |
| Assets direct INSERT into asset_assignments | blocked (42501) |
| Assets direct UPDATE asset_assignments.returned_at | blocked (0 of 2 rows) |
| Assets direct UPDATE asset_requests status | blocked (0 rows, with fixture) |

Not tested: hr.contract_versions direct writes (same ALL-policy shape) and direct DELETE on assets.assets.
