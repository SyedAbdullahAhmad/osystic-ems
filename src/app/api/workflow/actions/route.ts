// src/app/api/workflow/actions/route.ts
//
// Deliberately module-agnostic - reused by every future module
// (attendance, contracts, onboarding, ...) for approve/reject/skip,
// rather than each module building its own copy. Thin wrapper over
// workflow.process_approval_action(), which does the actual
// eligibility/maker-checker/concurrency/idempotency enforcement.

import { NextResponse } from "next/server";
import { createClient, createWorkflowDB } from "@/lib/supabase-server";

export async function POST(request: Request) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return NextResponse.json({ error: "Unauthenticated" }, { status: 401 });
  }

  const body = await request.json();
  const { approvalRequestId, approvalStepId, action, comments, expectedVersion } = body;

  if (!approvalRequestId || !approvalStepId || !action || expectedVersion === undefined) {
    return NextResponse.json({ error: "Missing required fields" }, { status: 400 });
  }
  if (!["APPROVE", "REJECT", "SKIP"].includes(action)) {
    return NextResponse.json({ error: "Invalid action" }, { status: 400 });
  }

  const idempotencyKey = `${approvalRequestId}-${approvalStepId}-${action}-${Date.now()}`;

  const workflowDB = await createWorkflowDB();
  const { data, error } = await workflowDB.rpc("process_approval_action", {
    p_approval_request_id: approvalRequestId,
    p_action: action,
    p_approval_step_id: approvalStepId,
    p_comments: comments ?? null,
    p_metadata: null,
    p_idempotency_key: idempotencyKey,
    p_expected_version: expectedVersion,
  });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({ data });
}
