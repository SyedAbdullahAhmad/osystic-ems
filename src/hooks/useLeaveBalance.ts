"use client";
// src/hooks/useLeaveBalance.ts
//
// Error toasts are handled globally by QueryProvider's QueryCache -
// see the header comment in useLeaveRequests.ts for why per-hook toast
// calls here would be unsafe (render-phase state update).

import { useQuery } from "@tanstack/react-query";
import { fetchMyLeaveBalances, fetchApprovalHistory } from "@/services/leave.service";

export function useMyLeaveBalances() {
  return useQuery({
    queryKey: ["leave-balances"],
    queryFn: fetchMyLeaveBalances,
  });
}

export function useApprovalHistory(leaveRequestId: string | undefined) {
  return useQuery({
    queryKey: ["leave-approval-history", leaveRequestId],
    queryFn: () => fetchApprovalHistory(leaveRequestId!),
    enabled: !!leaveRequestId,
  });
}