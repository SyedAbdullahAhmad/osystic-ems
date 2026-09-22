// src/types/contracts.types.ts
import type { ContractType, ContractStatus } from "./database.types";

export interface Contract {
  id: string;
  employeeId: string;
  contractNumber: string;
  contractType: ContractType;
  status: ContractStatus;
  currentVersionId: string | null;
  effectiveFrom?: string;
  effectiveTo?: string | null;
  notes?: string | null;
  versionNo?: number;
  workflowRequestId?: string | null;
  createdAt: string;
}

export interface CreateContractInput {
  employeeId: string;
  contractType: ContractType;
  effectiveFrom: string;
  effectiveTo?: string | null;
  documentFileId?: string | null;
  notes?: string | null;
  contractNumber?: string | null;
}

export interface ContractApprovalHistoryEntry {
  fromStatus: string | null;
  toStatus: string;
  changedAt: string;
  reason: string | null;
  actorUserId: string | null;
  action: string | null;
  actionComments: string | null;
}
