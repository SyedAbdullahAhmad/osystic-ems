// src/types/leave.types.ts
import type { LeaveRequestStatus } from "./database.types";

export interface LeaveType {
  id: string;
  leaveCode: string;
  leaveName: string;
  description: string | null;
  requiresApproval: boolean;
  isPaid: boolean;
  maxDaysPerYear: number | null;
  status: "ACTIVE" | "INACTIVE";
}

export interface LeaveRequest {
  id: string;
  employeeId: string;
  leaveTypeId: string;
  leaveTypeName?: string;
  startDate: string;
  endDate: string;
  totalDays: number;
  reason: string | null;
  requestStatus: LeaveRequestStatus;
  workflowRequestId: string | null;
  submittedAt: string | null;
  createdAt: string;
}

export interface LeaveBalance {
  leaveTypeId: string;
  leaveTypeName: string;
  balanceDays: number;
  maxDaysPerYear: number | null;
}

export interface SubmitLeaveRequestInput {
  leaveTypeId: string;
  startDate: string;
  endDate: string;
  totalDays: number;
  reason?: string;
}

export interface ApprovalHistoryEntry {
  fromStatus: string | null;
  toStatus: string;
  changedAt: string;
  reason: string | null;
  actorUserId: string | null;
  action: string | null;
  actionComments: string | null;
}
