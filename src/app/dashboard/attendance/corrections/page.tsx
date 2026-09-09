"use client";
// src/app/dashboard/attendance/corrections/page.tsx

import { useState } from "react";
import { Plus, X } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { AttendanceCorrectionForm } from "@/components/sections/AttendanceCorrectionForm";
import { CorrectionRequestCard } from "@/components/attendance/CorrectionRequestCard";
import { useMyCorrectionRequests } from "@/hooks/useAttendanceCorrections";

export default function AttendanceCorrectionsPage() {
  const [showForm, setShowForm] = useState(false);
  const { data: requests, isLoading } = useMyCorrectionRequests();

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Attendance Corrections</h1>
        <Button onClick={() => setShowForm((v) => !v)} variant={showForm ? "secondary" : "primary"}>
          {showForm ? <X className="h-4 w-4" /> : <Plus className="h-4 w-4" />}
          {showForm ? "Cancel" : "New Correction"}
        </Button>
      </div>

      {showForm && <AttendanceCorrectionForm onSuccess={() => setShowForm(false)} />}

      <div className="flex flex-col gap-2">
        {isLoading && <p className="text-sm text-gray-500">Loading...</p>}
        {!isLoading && requests?.length === 0 && (
          <p className="text-sm text-gray-500">No correction requests yet. Submit your first one above.</p>
        )}
        {requests?.map((request) => (
          <CorrectionRequestCard key={request.id} request={request} />
        ))}
      </div>
    </div>
  );
}
