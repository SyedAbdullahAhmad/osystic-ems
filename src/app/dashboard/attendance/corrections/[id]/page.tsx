"use client";
// src/app/dashboard/attendance/corrections/[id]/page.tsx
//
// Mirrors src/app/dashboard/leave/requests/[id]/page.tsx exactly,
// including reusing workflow.service.ts as-is (it was deliberately built
// module-agnostic for precisely this reuse - see that file's header).
// Eligibility to act is enforced server-side by
// workflow.process_approval_action(), not guessed at client-side - an
// ineligible click surfaces as a toast error from the RPC itself.

import { use, useEffect, useState } from "react";
import { format, parseISO } from "date-fns";
import toast from "react-hot-toast";
import { CheckCircle2, XCircle } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { useCorrectionRequest, useCorrectionApprovalHistory } from "@/hooks/useAttendanceCorrections";
import { fetchApprovalSteps, performWorkflowAction } from "@/services/workflow.service";
import { workflowDB } from "@/lib/supabase";

interface PageProps {
  params: Promise<{ id: string }>;
}

export default function CorrectionRequestDetailPage({ params }: PageProps) {
  const { id } = use(params);
  const { data: request, isLoading, refetch } = useCorrectionRequest(id);
  const { data: history } = useCorrectionApprovalHistory(id);

  const [openStep, setOpenStep] = useState<{ id: string; stepName: string } | null>(null);
  const [requestVersion, setRequestVersion] = useState<number | null>(null);
  const [actingOn, setActingOn] = useState<"APPROVE" | "REJECT" | null>(null);

  useEffect(() => {
    if (!request?.workflowRequestId) return;

    fetchApprovalSteps(request.workflowRequestId).then((steps) => {
      const pending = steps.find((s) => s.status === "PENDING" || s.status === "IN_PROGRESS");
      setOpenStep(pending ? { id: pending.id, stepName: pending.step_name } : null);
    });

    workflowDB
      .from("approval_requests")
      .select("version")
      .eq("id", request.workflowRequestId)
      .single()
      .then(({ data }) => setRequestVersion(data?.version ?? null));
  }, [request?.workflowRequestId]);

  const handleAction = async (action: "APPROVE" | "REJECT") => {
    if (!request?.workflowRequestId || !openStep || requestVersion === null) return;

    setActingOn(action);
    try {
      await performWorkflowAction({
        approvalRequestId: request.workflowRequestId,
        approvalStepId: openStep.id,
        action,
        expectedVersion: requestVersion,
      });
      toast.success(action === "APPROVE" ? "Approved" : "Rejected");
      refetch();
      setOpenStep(null);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Action failed");
    } finally {
      setActingOn(null);
    }
  };

  if (isLoading) return <p className="text-sm text-gray-500">Loading...</p>;
  if (!request) return <p className="text-sm text-gray-500">Correction request not found.</p>;

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">
          {request.attendanceDate ? format(parseISO(request.attendanceDate), "MMM d, yyyy") : "Attendance Correction"}
        </h1>
        <p className="text-sm text-gray-500 dark:text-gray-400">
          {request.requestedCheckIn && <>Check-in: {format(parseISO(request.requestedCheckIn), "HH:mm")} </>}
          {request.requestedCheckOut && <>Check-out: {format(parseISO(request.requestedCheckOut), "HH:mm")}</>}
        </p>
        {request.reason && <p className="mt-2 text-sm text-gray-700 dark:text-gray-300">{request.reason}</p>}
      </div>

      {openStep && (
        <div className="flex items-center justify-between rounded-lg border border-amber-200 bg-amber-50 p-4 dark:border-amber-900 dark:bg-amber-950">
          <p className="text-sm font-medium text-amber-800 dark:text-amber-300">
            Awaiting your action: {openStep.stepName}
          </p>
          <div className="flex gap-2">
            <Button variant="danger" size="sm" loading={actingOn === "REJECT"} onClick={() => handleAction("REJECT")}>
              <XCircle className="h-4 w-4" /> Reject
            </Button>
            <Button variant="primary" size="sm" loading={actingOn === "APPROVE"} onClick={() => handleAction("APPROVE")}>
              <CheckCircle2 className="h-4 w-4" /> Approve
            </Button>
          </div>
        </div>
      )}

      <div>
        <h2 className="mb-3 text-sm font-semibold text-gray-700 dark:text-gray-300">Approval History</h2>
        <div className="flex flex-col gap-2">
          {history?.length === 0 && <p className="text-sm text-gray-500">No history yet.</p>}
          {history?.map((entry, i) => (
            <div key={i} className="rounded-md border border-gray-200 bg-white p-3 text-sm dark:border-gray-800 dark:bg-gray-950">
              <p className="text-gray-900 dark:text-white">
                {entry.fromStatus ?? "—"} → {entry.toStatus}
                {entry.action && <span className="text-gray-500"> ({entry.action})</span>}
              </p>
              {entry.actionComments && <p className="mt-1 text-gray-600 dark:text-gray-400">{entry.actionComments}</p>}
              <p className="mt-1 text-xs text-gray-400">{format(parseISO(entry.changedAt), "MMM d, yyyy HH:mm")}</p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
