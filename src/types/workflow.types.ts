// src/types/workflow.types.ts
//
// Deliberately generic/reusable - not leave-specific. Any future module
// (attendance, contracts, onboarding, ...) sharing the workflow engine
// uses these same shapes.

export type WorkflowActionType = "APPROVE" | "REJECT" | "SKIP";

export interface WorkflowApprovalStep {
  id: string;
  stepNo: number;
  stepName: string;
  status: "PENDING" | "IN_PROGRESS" | "APPROVED" | "REJECTED" | "SKIPPED";
}

export interface WorkflowActionInput {
  approvalRequestId: string;
  approvalStepId: string;
  action: WorkflowActionType;
  comments?: string;
  expectedVersion: number;
}

export interface WorkflowActionResult {
  status: string;
  [key: string]: unknown;
}
