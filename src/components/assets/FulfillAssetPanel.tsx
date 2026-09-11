"use client";
// src/components/assets/FulfillAssetPanel.tsx
//
// New UI, no Leave/Attendance equivalent - fulfillment (handing over a
// specific physical unit) is a deliberate manual step after approval,
// not something the workflow trigger does automatically (see
// assets.fulfill_asset_request()'s own header in
// 003_assets_submit_and_fulfill_request.sql). Only rendered by the
// parent page when request_status is APPROVED.
//
// Client-side hasPermission("ASSET_MANAGE") gate below is a UX
// convenience only, same principle as the Approve/Reject panel on the
// leave/attendance detail pages - the real gate is server-side, inside
// fulfill_asset_request() itself (core.has_permission check). A
// non-eligible user who somehow got here would just get a toast error
// from the RPC, not a silent failure.

import { useState } from "react";
import { PackageCheck } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { usePermissions } from "@/context/PermissionContext";
import { useAvailableAssetsForCategory, useFulfillAssetRequest } from "@/hooks/useAssetRequests";

interface FulfillAssetPanelProps {
  assetRequestId: string;
  assetCategoryId: string;
  onFulfilled?: () => void;
}

export function FulfillAssetPanel({ assetRequestId, assetCategoryId, onFulfilled }: FulfillAssetPanelProps) {
  const { hasPermission } = usePermissions();
  const { data: availableAssets, isLoading } = useAvailableAssetsForCategory(assetCategoryId);
  const fulfillMutation = useFulfillAssetRequest();

  const [selectedAssetId, setSelectedAssetId] = useState("");

  if (!hasPermission("ASSET_MANAGE")) return null;

  const handleFulfill = async () => {
    if (!selectedAssetId) return;
    await fulfillMutation.mutateAsync({ assetRequestId, assetId: selectedAssetId });
    onFulfilled?.();
  };

  return (
    <div className="flex flex-col gap-3 rounded-lg border border-blue-200 bg-blue-50 p-4 dark:border-blue-900 dark:bg-blue-950">
      <p className="text-sm font-medium text-blue-800 dark:text-blue-300">
        Approved — hand over a physical unit to fulfill this request
      </p>

      {isLoading && <p className="text-sm text-blue-700 dark:text-blue-400">Loading available units...</p>}

      {!isLoading && availableAssets?.length === 0 && (
        <p className="text-sm text-blue-700 dark:text-blue-400">
          No AVAILABLE units left in this category. Add more inventory before this request can be fulfilled.
        </p>
      )}

      {!isLoading && availableAssets && availableAssets.length > 0 && (
        <div className="flex items-center gap-3">
          <select
            value={selectedAssetId}
            onChange={(e) => setSelectedAssetId(e.target.value)}
            className="rounded-md border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
          >
            <option value="">Select a unit</option>
            {availableAssets.map((asset) => (
              <option key={asset.id} value={asset.id}>
                {asset.assetCode} — {asset.assetName}
                {asset.serialNumber ? ` (S/N: ${asset.serialNumber})` : ""}
              </option>
            ))}
          </select>
          <Button
            size="sm"
            disabled={!selectedAssetId}
            loading={fulfillMutation.isPending}
            onClick={handleFulfill}
          >
            <PackageCheck className="h-4 w-4" /> Fulfill
          </Button>
        </div>
      )}
    </div>
  );
}
