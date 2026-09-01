"use client";
// src/app/dashboard/leave/requests/page.tsx

import { useState } from "react";
import { Plus, X } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { LeaveRequestForm } from "@/components/sections/LeaveRequestForm";
import { LeaveRequestCard } from "@/components/leave/LeaveRequestCard";
import { useMyLeaveRequests } from "@/hooks/useLeaveRequests";

export default function LeaveRequestsPage() {
  const [showForm, setShowForm] = useState(false);
  const { data: requests, isLoading } = useMyLeaveRequests();

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Leave Requests</h1>
        <Button onClick={() => setShowForm((v) => !v)} variant={showForm ? "secondary" : "primary"}>
          {showForm ? <X className="h-4 w-4" /> : <Plus className="h-4 w-4" />}
          {showForm ? "Cancel" : "New Request"}
        </Button>
      </div>

      {showForm && <LeaveRequestForm onSuccess={() => setShowForm(false)} />}

      <div className="flex flex-col gap-2">
        {isLoading && <p className="text-sm text-gray-500">Loading...</p>}
        {!isLoading && requests?.length === 0 && (
          <p className="text-sm text-gray-500">No leave requests yet. Submit your first one above.</p>
        )}
        {requests?.map((request) => (
          <LeaveRequestCard key={request.id} request={request} />
        ))}
      </div>
    </div>
  );
}
