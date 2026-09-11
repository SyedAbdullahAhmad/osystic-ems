"use client";
// src/app/dashboard/assets/requests/page.tsx
// Mirrors src/app/dashboard/attendance/corrections/page.tsx exactly.

import { useState } from "react";
import { Plus, X } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { AssetRequestForm } from "@/components/sections/AssetRequestForm";
import { AssetRequestCard } from "@/components/assets/AssetRequestCard";
import { useMyAssetRequests } from "@/hooks/useAssetRequests";

export default function AssetRequestsPage() {
  const [showForm, setShowForm] = useState(false);
  const { data: requests, isLoading } = useMyAssetRequests();

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Asset Requests</h1>
        <Button onClick={() => setShowForm((v) => !v)} variant={showForm ? "secondary" : "primary"}>
          {showForm ? <X className="h-4 w-4" /> : <Plus className="h-4 w-4" />}
          {showForm ? "Cancel" : "New Request"}
        </Button>
      </div>

      {showForm && <AssetRequestForm onSuccess={() => setShowForm(false)} />}

      <div className="flex flex-col gap-2">
        {isLoading && <p className="text-sm text-gray-500">Loading...</p>}
        {!isLoading && requests?.length === 0 && (
          <p className="text-sm text-gray-500">No asset requests yet. Submit your first one above.</p>
        )}
        {requests?.map((request) => (
          <AssetRequestCard key={request.id} request={request} />
        ))}
      </div>
    </div>
  );
}
