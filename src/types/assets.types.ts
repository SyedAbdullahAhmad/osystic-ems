// src/types/assets.types.ts
import type { AssetRequestStatus, AssetStatus } from "./database.types";

export interface AssetCategory {
  id: string;
  categoryCode: string;
  categoryName: string;
  description: string | null;
}

export interface Asset {
  id: string;
  assetCategoryId: string;
  assetCode: string;
  assetName: string;
  serialNumber: string | null;
  currentStatus: AssetStatus;
}

export interface AssetRequest {
  id: string;
  employeeId: string;
  assetCategoryId: string;
  categoryName?: string;
  justification: string;
  requestStatus: AssetRequestStatus;
  workflowRequestId: string | null;
  submittedAt: string | null;
  createdAt: string;
}

export interface SubmitAssetRequestInput {
  assetCategoryId: string;
  justification: string;
}

export interface AssetRequestApprovalHistoryEntry {
  fromStatus: string | null;
  toStatus: string;
  changedAt: string;
  reason: string | null;
  actorUserId: string | null;
  action: string | null;
  actionComments: string | null;
}

export interface FulfillAssetRequestInput {
  assetRequestId: string;
  assetId: string;
}

export interface FulfillAssetRequestResult {
  assignmentId: string;
  assetId: string;
  status: string;
}
