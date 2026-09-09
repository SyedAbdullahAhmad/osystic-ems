// src/services/attendance.service.ts
//
// Data-access layer for the Attendance Corrections module. Mirrors
// leave.service.ts's exact convention: components/hooks call these,
// never Supabase directly.

import { attendanceDB } from "@/lib/supabase";
import type {
  CorrectionRequest,
  SubmitCorrectionRequestInput,
  CorrectionApprovalHistoryEntry,
} from "@/types/attendance.types";

export async function fetchMyCorrectionRequests(): Promise<CorrectionRequest[]> {
  const { data, error } = await attendanceDB
    .from("correction_requests")
    .select("*, attendance_days(attendance_date)")
    .order("created_at", { ascending: false });

  if (error) throw new Error(`Failed to load correction requests: ${error.message}`);

  return (data ?? []).map((row: any) => ({
    id: row.id,
    attendanceDayId: row.attendance_day_id,
    employeeId: row.employee_id,
    attendanceDate: row.attendance_days?.attendance_date,
    requestedCheckIn: row.requested_check_in,
    requestedCheckOut: row.requested_check_out,
    reason: row.reason,
    requestStatus: row.request_status,
    workflowRequestId: row.workflow_request_id,
    submittedAt: row.submitted_at,
    createdAt: row.created_at,
  }));
}

export async function fetchCorrectionRequestById(id: string): Promise<CorrectionRequest | null> {
  const { data, error } = await attendanceDB
    .from("correction_requests")
    .select("*, attendance_days(attendance_date, first_check_in, last_check_out, attendance_status)")
    .eq("id", id)
    .maybeSingle();

  if (error) throw new Error(`Failed to load correction request: ${error.message}`);
  if (!data) return null;

  const row = data as any;
  return {
    id: row.id,
    attendanceDayId: row.attendance_day_id,
    employeeId: row.employee_id,
    attendanceDate: row.attendance_days?.attendance_date,
    requestedCheckIn: row.requested_check_in,
    requestedCheckOut: row.requested_check_out,
    reason: row.reason,
    requestStatus: row.request_status,
    workflowRequestId: row.workflow_request_id,
    submittedAt: row.submitted_at,
    createdAt: row.created_at,
  };
}

export async function fetchCorrectionApprovalHistory(correctionRequestId: string): Promise<CorrectionApprovalHistoryEntry[]> {
  const { data, error } = await attendanceDB
    .from("v_correction_request_approvals")
    .select("*")
    .eq("correction_request_id", correctionRequestId)
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

export async function submitCorrectionRequest(
  input: SubmitCorrectionRequestInput
): Promise<{ correctionRequestId: string; status: string }> {
  const { data, error } = await attendanceDB.rpc("submit_correction_request", {
    p_attendance_date: input.attendanceDate,
    p_requested_check_in: input.requestedCheckIn ?? null,
    p_requested_check_out: input.requestedCheckOut ?? null,
    p_reason: input.reason,
  });

  if (error) throw new Error(error.message);

  return {
    correctionRequestId: (data as any).correction_request_id,
    status: (data as any).status,
  };
}
