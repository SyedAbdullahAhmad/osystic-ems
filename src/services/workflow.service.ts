// src/services/workflow.service.ts
//
// Generic workflow-action data access - deliberately module-agnostic.
// Any future module (attendance, contracts, onboarding, ...) reuses this
// exact service for approve/reject/skip, rather than each module
// reinventing its own approval-calling code.

import { workflowDB } from "@/lib/supabase";
import type { WorkflowActionInput, WorkflowActionResult } from "@/types/workflow.types";

export async function fetchApprovalSteps(approvalRequestId: string) {
  // step_name lives on workflow_steps (the template), not on
  // approval_steps (the runtime table) - approval_steps only has
  // workflow_step_id pointing back to it. Embedded-resource select via
  // that FK, same fix as the step_key issue in the approval SQL scripts.
  // approval_steps has TWO foreign keys into workflow_steps - the plain
  // workflow_step_id -> workflow_steps.id, and a composite
  // (workflow_step_id, workflow_version_id) one named
  // approval_steps_step_version_fk (see 003_workflow_constraints_indexes.sql),
  // added for extra integrity so a step can't reference a workflow_step
  // from the wrong version. PostgREST sees two valid embed paths and
  // refuses to guess - the constraint name must be given explicitly.
  const { data, error } = await workflowDB
    .from("approval_steps")
    .select("id, step_no, status, workflow_steps!approval_steps_step_version_fk(step_name)")
    .eq("approval_request_id", approvalRequestId)
    .order("step_no");

  if (error) throw new Error(`Failed to load approval steps: ${error.message}`);

  return (data ?? []).map((row: any) => ({
    id: row.id,
    step_no: row.step_no,
    status: row.status,
    step_name: row.workflow_steps?.step_name ?? "Approval Step",
  }));
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
