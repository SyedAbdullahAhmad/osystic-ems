"use client";
// src/app/dashboard/onboarding/[id]/page.tsx
//
// Mirrors the Contracts detail page (approve/reject through the generic
// workflow.service.ts) and adds the two onboarding-specific manual actions:
// Confirm hire (APPROVED only) and Withdraw (SUBMITTED/APPROVED only).
// Every button below is a UX convenience - the RPCs and the workflow engine
// enforce the real rules (maker-checker, status guards, permissions).

import { use, useEffect, useState } from "react";
import { format, parseISO } from "date-fns";
import toast from "react-hot-toast";
import { CheckCircle2, XCircle } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { ConfirmHirePanel } from "@/components/onboarding/ConfirmHirePanel";
import { WithdrawPanel } from "@/components/onboarding/WithdrawPanel";
import { candidateLabel, onboardingStatusStyles } from "@/components/onboarding/OnboardingCard";
import { useOnboardingRecord, useOnboardingHistory } from "@/hooks/useOnboarding";
import { fetchApprovalSteps, performWorkflowAction } from "@/services/workflow.service";
import { workflowDB } from "@/lib/supabase";
import { useAuth } from "@/context/AuthContext";

interface PageProps {
  params: Promise<{ id: string }>;
}

export default function OnboardingDetailPage({ params }: PageProps) {
  const { id } = use(params);
  const { user } = useAuth();
  const { data: record, isLoading, refetch } = useOnboardingRecord(id);
  const { data: history, refetch: refetchHistory } = useOnboardingHistory(record?.workflowRequestId);

  const [openStep, setOpenStep] = useState<{ id: string; stepName: string } | null>(null);
  const [requestVersion, setRequestVersion] = useState<number | null>(null);
  const [actingOn, setActingOn] = useState<"APPROVE" | "REJECT" | null>(null);

  const status = record?.status;

  useEffect(() => {
    // Only a SUBMITTED record can have an open approval step.
    if (!record?.workflowRequestId || record.status !== "SUBMITTED") {
      setOpenStep(null);
      return;
    }

    fetchApprovalSteps(record.workflowRequestId).then((steps) => {
      const pending = steps.find((s) => s.status === "PENDING" || s.status === "IN_PROGRESS");
      setOpenStep(pending ? { id: pending.id, stepName: pending.step_name } : null);
    });

    workflowDB
      .from("approval_requests")
      .select("version")
      .eq("id", record.workflowRequestId)
      .single()
      .then(({ data }) => setRequestVersion(data?.version ?? null));
  }, [record?.workflowRequestId, record?.status]);

  const refreshAll = () => {
    refetch();
    refetchHistory();
  };

  const handleAction = async (action: "APPROVE" | "REJECT") => {
    if (!record?.workflowRequestId || !openStep || requestVersion === null) return;

    setActingOn(action);
    try {
      await performWorkflowAction({
        approvalRequestId: record.workflowRequestId,
        approvalStepId: openStep.id,
        action,
        expectedVersion: requestVersion,
      });
      toast.success(action === "APPROVE" ? "Approved" : "Rejected");
      setOpenStep(null);
      refreshAll();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Action failed");
    } finally {
      setActingOn(null);
    }
  };

  if (isLoading) return <p className="text-sm text-gray-500">Loading...</p>;
  if (!record) return <p className="text-sm text-gray-500">Onboarding record not found.</p>;

  // Maker-checker: the person who created the request cannot approve it.
  // Hiding the buttons is UX only - the engine rejects it regardless.
  const isInitiator = !!user && record.createdBy === user.id;
  const canWithdraw = status === "SUBMITTED" || status === "APPROVED";

  return (
    <div className="flex flex-col gap-6">
      <div>
        <div className="flex items-center gap-3">
          <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">{candidateLabel(record)}</h1>
          <span className={`rounded-full px-3 py-1 text-xs font-medium ${onboardingStatusStyles[record.status]}`}>
            {record.status}
          </span>
        </div>
        {record.candidateEmail && <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{record.candidateEmail}</p>}
        {record.positionTitle && <p className="mt-2 text-sm text-gray-700 dark:text-gray-300">{record.positionTitle}</p>}
        {record.proposedStartDate && (
          <p className="mt-1 text-sm text-gray-700 dark:text-gray-300">
            Proposed start {format(parseISO(record.proposedStartDate), "MMM d, yyyy")}
          </p>
        )}
        <p className="mt-1 text-xs text-gray-400">
          Created {format(parseISO(record.createdAt), "MMM d, yyyy HH:mm")} · Version {record.version}
        </p>
        {record.hiredAt && (
          <p className="mt-1 text-sm text-green-700 dark:text-green-300">
            Hired {format(parseISO(record.hiredAt), "MMM d, yyyy HH:mm")}
          </p>
        )}
        {record.status === "WITHDRAWN" && (
          <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
            Withdrawn{record.withdrawnAt ? ` ${format(parseISO(record.withdrawnAt), "MMM d, yyyy HH:mm")}` : ""}
            {record.withdrawalReason ? ` — ${record.withdrawalReason}` : ""}
          </p>
        )}
      </div>

      {openStep && !isInitiator && (
        <div className="flex items-center justify-between rounded-lg border border-amber-200 bg-amber-50 p-4 dark:border-amber-900 dark:bg-amber-950">
          <p className="text-sm font-medium text-amber-800 dark:text-amber-300">Awaiting your action: {openStep.stepName}</p>
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

      {openStep && isInitiator && (
        <p className="rounded-lg border border-gray-200 bg-white p-4 text-sm text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
          Waiting for a different approver — you created this request, so you cannot approve it yourself.
        </p>
      )}

      {status === "APPROVED" && <ConfirmHirePanel onboardingRecordId={record.id} onConfirmed={refreshAll} />}

      {canWithdraw && <WithdrawPanel onboardingRecordId={record.id} onWithdrawn={refreshAll} />}

      <div>
        <h2 className="mb-3 text-sm font-semibold text-gray-700 dark:text-gray-300">Approval History</h2>
        <div className="flex flex-col gap-2">
          {(!history || history.length === 0) && <p className="text-sm text-gray-500">No history yet.</p>}
          {history?.map((entry, i) => (
            <div key={i} className="rounded-md border border-gray-200 bg-white p-3 text-sm dark:border-gray-800 dark:bg-gray-950">
              <p className="text-gray-900 dark:text-white">
                {entry.fromStatus ?? "—"} → {entry.toStatus}
              </p>
              {entry.reason && <p className="mt-1 text-gray-600 dark:text-gray-400">{entry.reason}</p>}
              <p className="mt-1 text-xs text-gray-400">{format(parseISO(entry.changedAt), "MMM d, yyyy HH:mm")}</p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
