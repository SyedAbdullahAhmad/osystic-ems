"use client";
// src/app/dashboard/leave/requests/[id]/page.tsx
//
// Shows the request, its full approval history (via the read-only view -
// never a writable leave.leave_approvals table, per the architecture),
// and an approve/reject panel. Eligibility to actually act is enforced
// server-side by workflow.process_approval_action() (proven in 008's
// delegation_maker_checker/rls_visibility suites) - this page shows the
// action buttons to anyone who can view the request and lets the RPC be
// the actual authority; an ineligible click surfaces as a toast error,
// not a client-side guess at who's allowed to act.

import { use, useEffect, useState } from "react";
import { format, parseISO } from "date-fns";
import toast from "react-hot-toast";
import { CheckCircle2, XCircle } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { useLeaveRequest } from "@/hooks/useLeaveRequests";
import { useApprovalHistory } from "@/hooks/useLeaveBalance";
import { fetchApprovalSteps, performWorkflowAction } from "@/services/workflow.service";
import { workflowDB } from "@/lib/supabase";

interface PageProps {
  params: Promise<{ id: string }>;
}

export default function LeaveRequestDetailPage({ params }: PageProps) {
  const { id } = use(params);
  const { data: request, isLoading, refetch } = useLeaveRequest(id);
  const { data: history } = useApprovalHistory(id);

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
  if (!request) return <p className="text-sm text-gray-500">Leave request not found.</p>;

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">{request.leaveTypeName}</h1>
        <p className="text-sm text-gray-500 dark:text-gray-400">
          {format(parseISO(request.startDate), "MMM d, yyyy")} - {format(parseISO(request.endDate), "MMM d, yyyy")}
          {" "}({request.totalDays} day{request.totalDays !== 1 ? "s" : ""})
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
