"use client";
// src/hooks/useAttendanceCorrections.ts
//
// Error toasts are handled globally by QueryProvider's QueryCache
// (see useLeaveRequests.ts's header for why per-hook throwOnError/onError
// toast calls on QUERIES would be unsafe - render-phase state update).
// onSuccess/onError on a MUTATION is safe here, same as
// useSubmitLeaveRequest - mutations fire from event handlers, not render.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";
import {
  fetchMyCorrectionRequests,
  fetchCorrectionRequestById,
  fetchCorrectionApprovalHistory,
  submitCorrectionRequest,
} from "@/services/attendance.service";
import type { SubmitCorrectionRequestInput } from "@/types/attendance.types";

export function useMyCorrectionRequests() {
  return useQuery({
    queryKey: ["attendance-correction-requests"],
    queryFn: fetchMyCorrectionRequests,
  });
}

export function useCorrectionRequest(id: string | undefined) {
  return useQuery({
    queryKey: ["attendance-correction-requests", id],
    queryFn: () => fetchCorrectionRequestById(id!),
    enabled: !!id,
  });
}

export function useCorrectionApprovalHistory(correctionRequestId: string | undefined) {
  return useQuery({
    queryKey: ["attendance-correction-approval-history", correctionRequestId],
    queryFn: () => fetchCorrectionApprovalHistory(correctionRequestId!),
    enabled: !!correctionRequestId,
  });
}

export function useSubmitCorrectionRequest() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (input: SubmitCorrectionRequestInput) => submitCorrectionRequest(input),
    onSuccess: () => {
      toast.success("Correction request submitted");
      queryClient.invalidateQueries({ queryKey: ["attendance-correction-requests"] });
    },
    onError: (error: Error) => {
      toast.error(error.message || "Failed to submit correction request");
    },
  });
}
