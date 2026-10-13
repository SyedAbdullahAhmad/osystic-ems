// src/types/onboarding.types.ts
import type { OnboardingStatus } from "./database.types";

export interface OnboardingRecord {
  id: string;
  personId: string;
  // Resolved from core.people when the viewer is allowed to read it; null
  // otherwise (UI falls back to "Candidate <short id>").
  candidateName: string | null;
  candidateEmail: string | null;
  positionTitle: string | null;
  departmentId: string | null;
  proposedStartDate: string | null;
  status: OnboardingStatus;
  workflowRequestId: string | null;
  submittedAt: string | null;
  hiredAt: string | null;
  withdrawnAt: string | null;
  withdrawalReason: string | null;
  createdBy: string | null;
  createdAt: string;
  version: number;
}

export interface Department {
  id: string;
  name: string;
}

export interface CreateOnboardingInput {
  fullName: string;
  email: string;
  idempotencyKey: string;
  positionTitle?: string | null;
  departmentId?: string | null;
  proposedStartDate?: string | null;
}

export interface CreateOnboardingResult {
  onboardingRecordId: string;
  personId: string;
  workflowRequestId: string | null;
  onboardingStatus: string;
  workflowStatus: string;
  idempotentReplay: boolean;
}

export interface ConfirmHireInput {
  onboardingRecordId: string;
  employeeNumber?: string | null;
  hireDate?: string | null;
}

export interface ConfirmHireResult {
  onboardingRecordId: string;
  personId: string;
  hrEmployeeId: string;
  employeeLinked: boolean;
  idempotentReplay: boolean;
  status: string;
}

export interface WithdrawOnboardingInput {
  onboardingRecordId: string;
  reason?: string | null;
}

export interface WithdrawOnboardingResult {
  onboardingRecordId: string;
  status: string;
  idempotentReplay: boolean;
  workflowCancelled: boolean;
}

export interface OnboardingHistoryEntry {
  fromStatus: string | null;
  toStatus: string;
  changedAt: string;
  reason: string | null;
}
