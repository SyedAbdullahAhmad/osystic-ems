"use client";
// src/hooks/useAssetRequests.ts
//
// Mirrors useAttendanceCorrections.ts's exact convention - error toasts
// are handled globally by QueryProvider's QueryCache for QUERIES (see
// useLeaveRequests.ts's header for why per-hook throwOnError/onError on
// a query would be an unsafe render-phase state update);
// onSuccess/onError on a MUTATION is safe since mutations fire from
// event handlers, not render.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";
import {
  fetchAssetCategories,
  fetchMyAssetRequests,
  fetchAssetRequestById,
  fetchAssetRequestApprovalHistory,
  submitAssetRequest,
  fetchAvailableAssetsForCategory,
  fulfillAssetRequest,
} from "@/services/assets.service";
import type { SubmitAssetRequestInput, FulfillAssetRequestInput } from "@/types/assets.types";

export function useAssetCategories() {
  return useQuery({
    queryKey: ["asset-categories"],
    queryFn: fetchAssetCategories,
  });
}

export function useMyAssetRequests() {
  return useQuery({
    queryKey: ["asset-requests"],
    queryFn: fetchMyAssetRequests,
  });
}

export function useAssetRequest(id: string | undefined) {
  return useQuery({
    queryKey: ["asset-requests", id],
    queryFn: () => fetchAssetRequestById(id!),
    enabled: !!id,
  });
}

export function useAssetRequestApprovalHistory(assetRequestId: string | undefined) {
  return useQuery({
    queryKey: ["asset-request-approval-history", assetRequestId],
    queryFn: () => fetchAssetRequestApprovalHistory(assetRequestId!),
    enabled: !!assetRequestId,
  });
}

export function useSubmitAssetRequest() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (input: SubmitAssetRequestInput) => submitAssetRequest(input),
    onSuccess: () => {
      toast.success("Asset request submitted");
      queryClient.invalidateQueries({ queryKey: ["asset-requests"] });
    },
    onError: (error: Error) => {
      toast.error(error.message || "Failed to submit asset request");
    },
  });
}

// Only meaningful once a request is APPROVED and the category is known -
// callers pass undefined until then and the query stays disabled.
export function useAvailableAssetsForCategory(assetCategoryId: string | undefined) {
  return useQuery({
    queryKey: ["available-assets", assetCategoryId],
    queryFn: () => fetchAvailableAssetsForCategory(assetCategoryId!),
    enabled: !!assetCategoryId,
  });
}

export function useFulfillAssetRequest() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (input: FulfillAssetRequestInput) => fulfillAssetRequest(input),
    onSuccess: (_result, variables) => {
      toast.success("Asset request fulfilled");
      queryClient.invalidateQueries({ queryKey: ["asset-requests"] });
      queryClient.invalidateQueries({ queryKey: ["asset-requests", variables.assetRequestId] });
      queryClient.invalidateQueries({ queryKey: ["available-assets"] });
    },
    onError: (error: Error) => {
      toast.error(error.message || "Failed to fulfill asset request");
    },
  });
}
