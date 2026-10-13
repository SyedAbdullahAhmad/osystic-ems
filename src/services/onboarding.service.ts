// src/services/onboarding.service.ts
//
// Data-access layer for the Onboarding module, same convention as
// contracts.service.ts: components/hooks call these, never the schema
// clients directly. Reads rely on RLS (ONBOARDING_MANAGE / ONBOARDING_VIEW_ALL
// see everything; a linked candidate sees only their own record). ALL
// writes go through the three SECURITY DEFINER RPCs - there is no table
// INSERT/UPDATE grant for "authenticated", so there is nothing else to call.

import { onboardingDB, coreDB, workflowDB } from "@/lib/supabase";
import type {
  OnboardingRecord,
  Department,
  CreateOnboardingInput,
  CreateOnboardingResult,
  ConfirmHireInput,
  ConfirmHireResult,
  WithdrawOnboardingInput,
  WithdrawOnboardingResult,
  OnboardingHistoryEntry,
} from "@/types/onboarding.types";

function mapRecord(row: any, person?: { full_name: string | null; primary_email: string | null }): OnboardingRecord {
  return {
    id: row.id,
    personId: row.person_id,
    candidateName: person?.full_name ?? null,
    candidateEmail: person?.primary_email ?? null,
    positionTitle: row.position_title,
    departmentId: row.department_id,
    proposedStartDate: row.proposed_start_date,
    status: row.status,
    workflowRequestId: row.workflow_request_id,
    submittedAt: row.submitted_at,
    hiredAt: row.hired_at,
    withdrawnAt: row.withdrawn_at,
    withdrawalReason: row.withdrawal_reason,
    createdBy: row.created_by,
    createdAt: row.created_at,
    version: row.version,
  };
}

// Best effort: core.people may not be readable for every viewer. A failure
// here must never break the page - the UI falls back to a short id.
async function fetchPeopleByIds(ids: string[]) {
  const map = new Map<string, { full_name: string | null; primary_email: string | null }>();
  if (ids.length === 0) return map;

  const { data, error } = await coreDB.from("people").select("id, full_name, primary_email").in("id", ids);
  if (error || !data) return map;

  for (const p of data as any[]) map.set(p.id, { full_name: p.full_name, primary_email: p.primary_email });
  return map;
}

export async function fetchOnboardingRecords(): Promise<OnboardingRecord[]> {
  const { data, error } = await onboardingDB
    .from("onboarding_records")
    .select("*")
    .order("created_at", { ascending: false });

  if (error) throw new Error(`Failed to load onboarding records: ${error.message}`);

  const rows = (data ?? []) as any[];
  const people = await fetchPeopleByIds(Array.from(new Set(rows.map((r) => r.person_id))));
  return rows.map((row) => mapRecord(row, people.get(row.person_id)));
}

export async function fetchOnboardingRecordById(id: string): Promise<OnboardingRecord | null> {
  const { data, error } = await onboardingDB.from("onboarding_records").select("*").eq("id", id).maybeSingle();

  if (error) throw new Error(`Failed to load onboarding record: ${error.message}`);
  if (!data) return null;

  const people = await fetchPeopleByIds([(data as any).person_id]);
  return mapRecord(data, people.get((data as any).person_id));
}

// Best effort too. Reads workflow.status_history directly (no onboarding
// view exists); if RLS or a column name differs this returns [] instead of
// breaking the detail page.
export async function fetchOnboardingHistory(workflowRequestId: string): Promise<OnboardingHistoryEntry[]> {
  // status_history is not in the hand-written database.types.ts workflow
  // block, so the typed client would reject the table name - hence the cast.
  // Remove the cast once types are regenerated with `supabase gen types`.
  const { data, error } = await (workflowDB as any)
    .from("status_history")
    .select("*")
    .eq("approval_request_id", workflowRequestId);

  if (error || !data) return [];

  return (data as any[])
    .map((row) => ({
      fromStatus: row.from_status ?? null,
      toStatus: row.to_status,
      changedAt: row.changed_at ?? row.created_at,
      reason: row.reason ?? null,
    }))
    .sort((a, b) => String(a.changedAt).localeCompare(String(b.changedAt)));
}

// Optional dropdown data. Column names are an assumption (id, name) - if
// core.departments differs or is not readable this returns [] and the form
// simply hides the department field.
export async function fetchDepartments(): Promise<Department[]> {
  const { data, error } = await coreDB.from("departments").select("id, name").order("name");
  if (error || !data) return [];
  return (data as any[]).map((d) => ({ id: d.id, name: d.name }));
}

export async function createOnboardingRequest(input: CreateOnboardingInput): Promise<CreateOnboardingResult> {
  const { data, error } = await onboardingDB.rpc("create_and_submit_onboarding_request", {
    p_full_name: input.fullName,
    p_email: input.email,
    p_idempotency_key: input.idempotencyKey,
    p_position_title: input.positionTitle ?? null,
    p_department_id: input.departmentId ?? null,
    p_proposed_start_date: input.proposedStartDate ?? null,
  });

  if (error) throw new Error(error.message);

  const r = data as any;
  return {
    onboardingRecordId: r.onboarding_record_id,
    personId: r.person_id,
    workflowRequestId: r.workflow_request_id ?? null,
    onboardingStatus: r.onboarding_status,
    workflowStatus: r.workflow_status,
    idempotentReplay: !!r.idempotent_replay,
  };
}

export async function confirmEmployeeHire(input: ConfirmHireInput): Promise<ConfirmHireResult> {
  const { data, error } = await onboardingDB.rpc("confirm_employee_hire", {
    p_onboarding_record_id: input.onboardingRecordId,
    p_employee_number: input.employeeNumber || null,
    p_hire_date: input.hireDate || null,
  });

  if (error) throw new Error(error.message);

  const r = data as any;
  return {
    onboardingRecordId: r.onboarding_record_id,
    personId: r.person_id,
    hrEmployeeId: r.hr_employee_id,
    employeeLinked: !!r.employee_linked,
    idempotentReplay: !!r.idempotent_replay,
    status: r.status,
  };
}

export async function withdrawOnboardingRequest(input: WithdrawOnboardingInput): Promise<WithdrawOnboardingResult> {
  const { data, error } = await onboardingDB.rpc("withdraw_onboarding_request", {
    p_onboarding_record_id: input.onboardingRecordId,
    p_reason: input.reason?.trim() || null,
  });

  if (error) throw new Error(error.message);

  const r = data as any;
  return {
    onboardingRecordId: r.onboarding_record_id,
    status: r.status,
    idempotentReplay: !!r.idempotent_replay,
    workflowCancelled: !!r.workflow_cancelled,
  };
}
