// src/services/contracts.service.ts
//
// Data-access layer for the Contracts module. Mirrors assets.service.ts's
// exact convention: components/hooks call these, never contractsDB
// directly.
//
// One real difference from Leave/Attendance/Assets: creation is
// HR/Admin-only (createContract() will fail server-side, via
// hr.create_contract()'s own CONTRACT_MANAGE check, for anyone else -
// the UI additionally hides the create form entirely for non-holders,
// see ContractForm.tsx). There's also no separate "fetch my own vs
// fetch all" distinction the way Leave/Attendance have - RLS already
// scopes fetchContracts() to "your own contract if you're the employee
// it's for, or everything if you hold CONTRACT_VIEW_ALL/CONTRACT_MANAGE",
// same reliance-on-RLS pattern used everywhere else in this project.

import { contractsDB } from "@/lib/supabase";
import type { Contract, CreateContractInput, ContractApprovalHistoryEntry } from "@/types/contracts.types";

function mapContractRow(row: any): Contract {
  const version = row.contract_versions;
  const request = Array.isArray(row.contract_requests) ? row.contract_requests[0] : row.contract_requests;

  return {
    id: row.id,
    employeeId: row.employee_id,
    contractNumber: row.contract_number,
    contractType: row.contract_type,
    status: row.status,
    currentVersionId: row.current_version_id,
    effectiveFrom: version?.effective_from,
    effectiveTo: version?.effective_to,
    notes: version?.notes,
    versionNo: version?.version_no,
    workflowRequestId: request?.workflow_request_id ?? null,
    createdAt: row.created_at,
  };
}

const CONTRACT_SELECT = "*, contract_versions:current_version_id(effective_from, effective_to, notes, version_no), contract_requests(workflow_request_id)";

export async function fetchContracts(): Promise<Contract[]> {
  const { data, error } = await contractsDB
    .from("contracts")
    .select(CONTRACT_SELECT)
    .order("created_at", { ascending: false });

  if (error) throw new Error(`Failed to load contracts: ${error.message}`);

  return (data ?? []).map(mapContractRow);
}

export async function fetchContractById(id: string): Promise<Contract | null> {
  const { data, error } = await contractsDB
    .from("contracts")
    .select(CONTRACT_SELECT)
    .eq("id", id)
    .maybeSingle();

  if (error) throw new Error(`Failed to load contract: ${error.message}`);
  if (!data) return null;

  return mapContractRow(data);
}

export async function fetchContractApprovalHistory(contractId: string): Promise<ContractApprovalHistoryEntry[]> {
  const { data, error } = await contractsDB
    .from("v_contract_approvals")
    .select("*")
    .eq("contract_id", contractId)
    .order("changed_at");

  if (error) throw new Error(`Failed to load approval history: ${error.message}`);

  return (data ?? []).map((row) => ({
    fromStatus: row.from_status,
    toStatus: row.to_status,
    changedAt: row.changed_at,
    reason: row.reason,
    actorUserId: row.actor_user_id,
    action: row.action,
    actionComments: row.action_comments,
  }));
}

export async function createContract(
  input: CreateContractInput
): Promise<{ contractId: string; contractNumber: string; workflowRequestId: string | null; status: string }> {
  const { data, error } = await contractsDB.rpc("create_contract", {
    p_employee_id: input.employeeId,
    p_contract_type: input.contractType,
    p_effective_from: input.effectiveFrom,
    p_effective_to: input.effectiveTo ?? null,
    p_document_file_id: input.documentFileId ?? null,
    p_notes: input.notes ?? null,
    p_contract_number: input.contractNumber ?? null,
  });

  if (error) throw new Error(error.message);

  const result = data as any;
  return {
    contractId: result.contract_id,
    contractNumber: result.contract_number,
    workflowRequestId: result.workflow_request_id,
    status: result.status,
  };
}
