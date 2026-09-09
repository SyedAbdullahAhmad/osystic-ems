// src/types/attendance.types.ts
import type { AttendanceCorrectionRequestStatus, AttendanceStatus } from "./database.types";

export interface AttendanceDay {
  id: string;
  employeeId: string;
  attendanceDate: string;
  firstCheckIn: string | null;
  lastCheckOut: string | null;
  workedMinutes: number | null;
  attendanceStatus: AttendanceStatus;
}

export interface CorrectionRequest {
  id: string;
  attendanceDayId: string;
  employeeId: string;
  attendanceDate?: string;
  requestedCheckIn: string | null;
  requestedCheckOut: string | null;
  reason: string;
  requestStatus: AttendanceCorrectionRequestStatus;
  workflowRequestId: string | null;
  submittedAt: string | null;
  createdAt: string;
}

export interface SubmitCorrectionRequestInput {
  attendanceDate: string;
  requestedCheckIn?: string | null;
  requestedCheckOut?: string | null;
  reason: string;
}

export interface CorrectionApprovalHistoryEntry {
  fromStatus: string | null;
  toStatus: string;
  changedAt: string;
  reason: string | null;
  actorUserId: string | null;
  action: string | null;
  actionComments: string | null;
}
