"use client";
// src/hooks/useContracts.ts
// Mirrors useAssetRequests.ts's exact convention.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";
import {
  fetchContracts,
  fetchContractById,
  fetchContractApprovalHistory,
  createContract,
} from "@/services/contracts.service";
import type { CreateContractInput } from "@/types/contracts.types";

export function useContracts() {
  return useQuery({
    queryKey: ["contracts"],
    queryFn: fetchContracts,
  });
}

export function useContract(id: string | undefined) {
  return useQuery({
    queryKey: ["contracts", id],
    queryFn: () => fetchContractById(id!),
    enabled: !!id,
  });
}

export function useContractApprovalHistory(contractId: string | undefined) {
  return useQuery({
    queryKey: ["contract-approval-history", contractId],
    queryFn: () => fetchContractApprovalHistory(contractId!),
    enabled: !!contractId,
  });
}

export function useCreateContract() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (input: CreateContractInput) => createContract(input),
    onSuccess: () => {
      toast.success("Contract created and submitted for approval");
      queryClient.invalidateQueries({ queryKey: ["contracts"] });
    },
    onError: (error: Error) => {
      toast.error(error.message || "Failed to create contract");
    },
  });
}
