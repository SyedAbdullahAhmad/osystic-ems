// src/services/leave.service.ts
//
// Data-access layer for the leave module. Components/hooks call these,
// never Supabase directly - keeps query shape/error handling in one
// place, matching Finance's services/ convention.

import { leaveDB } from "@/lib/supabase";
import type { LeaveRequest, LeaveType, LeaveBalance, SubmitLeaveRequestInput, ApprovalHistoryEntry } from "@/types/leave.types";

export async function fetchLeaveTypes(): Promise<LeaveType[]> {
  const { data, error } = await leaveDB
    .from("leave_types")
    .select("*")
    .eq("status", "ACTIVE")
    .order("leave_name");

  if (error) throw new Error(`Failed to load leave types: ${error.message}`);

  return (data ?? []).map((row) => ({
    id: row.id,
    leaveCode: row.leave_code,
    leaveName: row.leave_name,
    description: row.description,
    requiresApproval: row.requires_approval,
    isPaid: row.is_paid,
    maxDaysPerYear: row.max_days_per_year,
    status: row.status,
  }));
}

export async function fetchMyLeaveRequests(): Promise<LeaveRequest[]> {
  const { data, error } = await leaveDB
    .from("leave_requests")
    .select("*, leave_types(leave_name)")
    .order("created_at", { ascending: false });

  if (error) throw new Error(`Failed to load leave requests: ${error.message}`);

  return (data ?? []).map((row: any) => ({
    id: row.id,
    employeeId: row.employee_id,
    leaveTypeId: row.leave_type_id,
    leaveTypeName: row.leave_types?.leave_name,
    startDate: row.start_date,
    endDate: row.end_date,
    totalDays: row.total_days,
    reason: row.reason,
    requestStatus: row.request_status,
    workflowRequestId: row.workflow_request_id,
    submittedAt: row.submitted_at,
    createdAt: row.created_at,
  }));
}

export async function fetchLeaveRequestById(id: string): Promise<LeaveRequest | null> {
  const { data, error } = await leaveDB
    .from("leave_requests")
    .select("*, leave_types(leave_name)")
    .eq("id", id)
    .maybeSingle();

  if (error) throw new Error(`Failed to load leave request: ${error.message}`);
  if (!data) return null;

  const row = data as any;
  return {
    id: row.id,
    employeeId: row.employee_id,
    leaveTypeId: row.leave_type_id,
    leaveTypeName: row.leave_types?.leave_name,
    startDate: row.start_date,
    endDate: row.end_date,
    totalDays: row.total_days,
    reason: row.reason,
    requestStatus: row.request_status,
    workflowRequestId: row.workflow_request_id,
    submittedAt: row.submitted_at,
    createdAt: row.created_at,
  };
}

export async function fetchMyLeaveBalances(): Promise<LeaveBalance[]> {
  const [{ data: balances, error: balError }, types] = await Promise.all([
    leaveDB.from("v_leave_balances").select("*"),
    fetchLeaveTypes(),
  ]);

  if (balError) throw new Error(`Failed to load leave balances: ${balError.message}`);

  const typeById = new Map(types.map((t) => [t.id, t]));

  return (balances ?? []).map((row) => {
    const type = typeById.get(row.leave_type_id);
    return {
      leaveTypeId: row.leave_type_id,
      leaveTypeName: type?.leaveName ?? "Unknown",
      balanceDays: row.balance_days,
      maxDaysPerYear: type?.maxDaysPerYear ?? null,
    };
  });
}

export async function fetchApprovalHistory(leaveRequestId: string): Promise<ApprovalHistoryEntry[]> {
  const { data, error } = await leaveDB
    .from("v_leave_request_approvals")
    .select("*")
    .eq("leave_request_id", leaveRequestId)
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

export async function submitLeaveRequest(input: SubmitLeaveRequestInput): Promise<{ leaveRequestId: string; status: string }> {
  const { data, error } = await leaveDB.rpc("submit_leave_request", {
    p_leave_type_id: input.leaveTypeId,
    p_start_date: input.startDate,
    p_end_date: input.endDate,
    p_total_days: input.totalDays,
    p_reason: input.reason ?? null,
  });

  if (error) throw new Error(error.message);

  return {
    leaveRequestId: (data as any).leave_request_id,
    status: (data as any).status,
  };
}
