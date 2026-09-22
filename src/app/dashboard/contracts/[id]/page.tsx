"use client";
// src/app/dashboard/contracts/[id]/page.tsx
//
// Mirrors the Assets/Attendance detail page pattern, reusing
// workflow.service.ts as-is for Approve/Reject. One thing that does NOT
// appear here unlike the Assets detail page: no fulfillment-panel
// equivalent - approval flips status straight to ACTIVE via the
// workflow-status trigger (003's header explains why nothing here needs
// a manual post-approval step the way Assets does).

import { use, useEffect, useState } from "react";
import { format, parseISO } from "date-fns";
import toast from "react-hot-toast";
import { CheckCircle2, XCircle } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { useContract, useContractApprovalHistory } from "@/hooks/useContracts";
import { fetchApprovalSteps, performWorkflowAction } from "@/services/workflow.service";
import { workflowDB } from "@/lib/supabase";

interface PageProps {
  params: Promise<{ id: string }>;
}

const typeLabels: Record<string, string> = {
  PERMANENT: "Permanent",
  FIXED_TERM: "Fixed-Term",
  PROBATION: "Probation",
  INTERNSHIP: "Internship",
  CONTRACTOR: "Contractor",
};

export default function ContractDetailPage({ params }: PageProps) {
  const { id } = use(params);
  const { data: contract, isLoading, refetch } = useContract(id);
  const { data: history } = useContractApprovalHistory(id);

  const [openStep, setOpenStep] = useState<{ id: string; stepName: string } | null>(null);
  const [requestVersion, setRequestVersion] = useState<number | null>(null);
  const [actingOn, setActingOn] = useState<"APPROVE" | "REJECT" | null>(null);

  useEffect(() => {
    if (!contract?.workflowRequestId) return;

    fetchApprovalSteps(contract.workflowRequestId).then((steps) => {
      const pending = steps.find((s) => s.status === "PENDING" || s.status === "IN_PROGRESS");
      setOpenStep(pending ? { id: pending.id, stepName: pending.step_name } : null);
    });

    workflowDB
      .from("approval_requests")
      .select("version")
      .eq("id", contract.workflowRequestId)
      .single()
      .then(({ data }) => setRequestVersion(data?.version ?? null));
  }, [contract?.workflowRequestId]);

  const handleAction = async (action: "APPROVE" | "REJECT") => {
    if (!contract?.workflowRequestId || !openStep || requestVersion === null) return;

    setActingOn(action);
    try {
      await performWorkflowAction({
        approvalRequestId: contract.workflowRequestId,
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
  if (!contract) return <p className="text-sm text-gray-500">Contract not found.</p>;

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">
          {contract.contractNumber} — {typeLabels[contract.contractType] ?? contract.contractType}
        </h1>
        {contract.effectiveFrom && (
          <p className="mt-2 text-sm text-gray-700 dark:text-gray-300">
            Effective {format(parseISO(contract.effectiveFrom), "MMM d, yyyy")}
            {contract.effectiveTo ? ` – ${format(parseISO(contract.effectiveTo), "MMM d, yyyy")}` : " (no end date)"}
          </p>
        )}
        {contract.notes && <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{contract.notes}</p>}
        <p className="mt-1 text-xs text-gray-400">
          Created {format(parseISO(contract.createdAt), "MMM d, yyyy HH:mm")} · Version {contract.versionNo ?? 1}
        </p>
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
