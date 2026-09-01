// src/services/workflow.service.ts
//
// Generic workflow-action data access - deliberately module-agnostic.
// Any future module (attendance, contracts, onboarding, ...) reuses this
// exact service for approve/reject/skip, rather than each module
// reinventing its own approval-calling code.

import { workflowDB } from "@/lib/supabase";
import type { WorkflowActionInput, WorkflowActionResult } from "@/types/workflow.types";

export async function fetchApprovalSteps(approvalRequestId: string) {
  const { data, error } = await workflowDB
    .from("approval_steps")
    .select("id, step_no, step_name, status")
    .eq("approval_request_id", approvalRequestId)
    .order("step_no");

  if (error) throw new Error(`Failed to load approval steps: ${error.message}`);
  return data ?? [];
}

export async function performWorkflowAction(input: WorkflowActionInput): Promise<WorkflowActionResult> {
  const idempotencyKey = `${input.approvalRequestId}-${input.approvalStepId}-${input.action}-${Date.now()}`;

  const { data, error } = await workflowDB.rpc("process_approval_action", {
    p_approval_request_id: input.approvalRequestId,
    p_action: input.action,
    p_approval_step_id: input.approvalStepId,
    p_comments: input.comments ?? null,
    p_metadata: null,
    p_idempotency_key: idempotencyKey,
    p_expected_version: input.expectedVersion,
  });

  if (error) throw new Error(error.message);
  return data as WorkflowActionResult;
}
