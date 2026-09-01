"use client";
// src/hooks/useLeaveRequests.ts
//
// Error toasts are handled globally by QueryProvider's QueryCache
// (see src/providers/QueryProvider.tsx) - do NOT add per-hook
// throwOnError/onError toast calls here. Calling toast() from inside
// a query option callback can run synchronously during React's render
// phase and trigger "Cannot update a component while rendering a
// different component" - the global QueryCache.onError runs when a
// query settles, outside the render cycle, which is the safe place
// for this kind of side effect.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";
import {
  fetchMyLeaveRequests,
  fetchLeaveRequestById,
  fetchLeaveTypes,
  submitLeaveRequest,
} from "@/services/leave.service";
import type { SubmitLeaveRequestInput } from "@/types/leave.types";

export function useLeaveTypes() {
  return useQuery({
    queryKey: ["leave-types"],
    queryFn: fetchLeaveTypes,
  });
}

export function useMyLeaveRequests() {
  return useQuery({
    queryKey: ["leave-requests"],
    queryFn: fetchMyLeaveRequests,
  });
}

export function useLeaveRequest(id: string | undefined) {
  return useQuery({
    queryKey: ["leave-requests", id],
    queryFn: () => fetchLeaveRequestById(id!),
    enabled: !!id,
  });
}

export function useSubmitLeaveRequest() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (input: SubmitLeaveRequestInput) => submitLeaveRequest(input),
    onSuccess: () => {
      toast.success("Leave request submitted");
      queryClient.invalidateQueries({ queryKey: ["leave-requests"] });
      queryClient.invalidateQueries({ queryKey: ["leave-balances"] });
    },
    onError: (error: Error) => {
      toast.error(error.message || "Failed to submit leave request");
    },
  });
}