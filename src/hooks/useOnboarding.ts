"use client";
// src/hooks/useOnboarding.ts
// Mirrors useContracts.ts's exact convention.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";
import {
  fetchOnboardingRecords,
  fetchOnboardingRecordById,
  fetchOnboardingHistory,
  fetchDepartments,
  createOnboardingRequest,
  confirmEmployeeHire,
  withdrawOnboardingRequest,
} from "@/services/onboarding.service";
import type {
  CreateOnboardingInput,
  ConfirmHireInput,
  WithdrawOnboardingInput,
} from "@/types/onboarding.types";

export function useOnboardingRecords() {
  return useQuery({ queryKey: ["onboarding"], queryFn: fetchOnboardingRecords });
}

export function useOnboardingRecord(id: string | undefined) {
  return useQuery({
    queryKey: ["onboarding", id],
    queryFn: () => fetchOnboardingRecordById(id!),
    enabled: !!id,
  });
}

export function useOnboardingHistory(workflowRequestId: string | null | undefined) {
  return useQuery({
    queryKey: ["onboarding-history", workflowRequestId],
    queryFn: () => fetchOnboardingHistory(workflowRequestId!),
    enabled: !!workflowRequestId,
  });
}

export function useDepartments() {
  return useQuery({ queryKey: ["departments"], queryFn: fetchDepartments, staleTime: 5 * 60 * 1000 });
}

export function useCreateOnboarding() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (input: CreateOnboardingInput) => createOnboardingRequest(input),
    onSuccess: (result) => {
      toast.success(
        result.idempotentReplay
          ? "This request was already submitted - showing the existing one"
          : "Onboarding request created and submitted for approval"
      );
      queryClient.invalidateQueries({ queryKey: ["onboarding"] });
    },
    onError: (error: Error) => {
      toast.error(error.message || "Failed to create onboarding request");
    },
  });
}

export function useConfirmHire() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (input: ConfirmHireInput) => confirmEmployeeHire(input),
    onSuccess: () => {
      toast.success("Hire confirmed - the candidate is now an employee");
      queryClient.invalidateQueries({ queryKey: ["onboarding"] });
    },
    onError: (error: Error) => {
      toast.error(error.message || "Failed to confirm hire");
    },
  });
}

export function useWithdrawOnboarding() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (input: WithdrawOnboardingInput) => withdrawOnboardingRequest(input),
    onSuccess: () => {
      toast.success("Onboarding request withdrawn");
      queryClient.invalidateQueries({ queryKey: ["onboarding"] });
      queryClient.invalidateQueries({ queryKey: ["onboarding-history"] });
    },
    onError: (error: Error) => {
      toast.error(error.message || "Failed to withdraw onboarding request");
    },
  });
}
