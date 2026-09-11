// src/services/assets.service.ts
//
// Data-access layer for the Assets module. Mirrors leave.service.ts /
// attendance.service.ts's exact convention: components/hooks call these,
// never Supabase directly.
//
// One thing genuinely new vs. Leave/Attendance: fulfillment. Approval
// only flips asset_requests.request_status to APPROVED (via the
// workflow-status trigger, same as the other two modules) - it does NOT
// hand over a physical unit. fetchAvailableAssetsForCategory() +
// fulfillAssetRequest() below are the extra step an ASSET_MANAGE holder
// takes afterwards to actually assign a specific unit. See
// assets.fulfill_asset_request()'s own header for why this is
// deliberately not automatic.

import { assetsDB } from "@/lib/supabase";
import type {
  AssetCategory,
  Asset,
  AssetRequest,
  SubmitAssetRequestInput,
  AssetRequestApprovalHistoryEntry,
  FulfillAssetRequestInput,
  FulfillAssetRequestResult,
} from "@/types/assets.types";

export async function fetchAssetCategories(): Promise<AssetCategory[]> {
  const { data, error } = await assetsDB
    .from("asset_categories")
    .select("*")
    .order("category_name");

  if (error) throw new Error(`Failed to load asset categories: ${error.message}`);

  return (data ?? []).map((row) => ({
    id: row.id,
    categoryCode: row.category_code,
    categoryName: row.category_name,
    description: row.description,
  }));
}

export async function fetchMyAssetRequests(): Promise<AssetRequest[]> {
  const { data, error } = await assetsDB
    .from("asset_requests")
    .select("*, asset_categories(category_name)")
    .order("created_at", { ascending: false });

  if (error) throw new Error(`Failed to load asset requests: ${error.message}`);

  return (data ?? []).map((row: any) => ({
    id: row.id,
    employeeId: row.employee_id,
    assetCategoryId: row.asset_category_id,
    categoryName: row.asset_categories?.category_name,
    justification: row.justification,
    requestStatus: row.request_status,
    workflowRequestId: row.workflow_request_id,
    submittedAt: row.submitted_at,
    createdAt: row.created_at,
  }));
}

export async function fetchAssetRequestById(id: string): Promise<AssetRequest | null> {
  const { data, error } = await assetsDB
    .from("asset_requests")
    .select("*, asset_categories(category_name)")
    .eq("id", id)
    .maybeSingle();

  if (error) throw new Error(`Failed to load asset request: ${error.message}`);
  if (!data) return null;

  const row = data as any;
  return {
    id: row.id,
    employeeId: row.employee_id,
    assetCategoryId: row.asset_category_id,
    categoryName: row.asset_categories?.category_name,
    justification: row.justification,
    requestStatus: row.request_status,
    workflowRequestId: row.workflow_request_id,
    submittedAt: row.submitted_at,
    createdAt: row.created_at,
  };
}

export async function fetchAssetRequestApprovalHistory(assetRequestId: string): Promise<AssetRequestApprovalHistoryEntry[]> {
  const { data, error } = await assetsDB
    .from("v_asset_request_approvals")
    .select("*")
    .eq("asset_request_id", assetRequestId)
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

export async function submitAssetRequest(
  input: SubmitAssetRequestInput
): Promise<{ assetRequestId: string; workflowRequestId: string | null; status: string }> {
  const { data, error } = await assetsDB.rpc("submit_asset_request", {
    p_asset_category_id: input.assetCategoryId,
    p_justification: input.justification,
  });

  if (error) throw new Error(error.message);

  return {
    assetRequestId: (data as any).asset_request_id,
    workflowRequestId: (data as any).workflow_request_id,
    status: (data as any).status,
  };
}

// Used by the fulfillment panel - only units that are AVAILABLE and in
// the requested category are offered, matching fulfill_asset_request()'s
// own server-side checks (ASSETS_ASSET_NOT_AVAILABLE / CATEGORY_MISMATCH).
export async function fetchAvailableAssetsForCategory(assetCategoryId: string): Promise<Asset[]> {
  const { data, error } = await assetsDB
    .from("assets")
    .select("*")
    .eq("asset_category_id", assetCategoryId)
    .eq("current_status", "AVAILABLE")
    .order("asset_code");

  if (error) throw new Error(`Failed to load available assets: ${error.message}`);

  return (data ?? []).map((row) => ({
    id: row.id,
    assetCategoryId: row.asset_category_id,
    assetCode: row.asset_code,
    assetName: row.asset_name,
    serialNumber: row.serial_number,
    currentStatus: row.current_status,
  }));
}

export async function fulfillAssetRequest(input: FulfillAssetRequestInput): Promise<FulfillAssetRequestResult> {
  const { data, error } = await assetsDB.rpc("fulfill_asset_request", {
    p_asset_request_id: input.assetRequestId,
    p_asset_id: input.assetId,
  });

  if (error) throw new Error(error.message);

  const result = data as any;
  return {
    assignmentId: result.assignment_id,
    assetId: result.asset_id,
    status: result.status,
  };
}
