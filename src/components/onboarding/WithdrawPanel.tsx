"use client";
// src/components/onboarding/WithdrawPanel.tsx
//
// Rendered while status is SUBMITTED or APPROVED. A HIRED record can never
// be withdrawn (the RPC rejects it), so the parent page never renders this
// panel for HIRED. Two-step: click, then confirm with an optional reason.

import { useState } from "react";
import { Undo2 } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { usePermissions } from "@/context/PermissionContext";
import { useWithdrawOnboarding } from "@/hooks/useOnboarding";

interface WithdrawPanelProps {
  onboardingRecordId: string;
  onWithdrawn?: () => void;
}

export function WithdrawPanel({ onboardingRecordId, onWithdrawn }: WithdrawPanelProps) {
  const { hasPermission } = usePermissions();
  const withdrawMutation = useWithdrawOnboarding();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");

  if (!hasPermission("ONBOARDING_MANAGE")) return null;

  const handleWithdraw = async () => {
    await withdrawMutation.mutateAsync({ onboardingRecordId, reason: reason || null });
    setOpen(false);
    setReason("");
    onWithdrawn?.();
  };

  if (!open) {
    return (
      <div>
        <Button variant="secondary" size="sm" onClick={() => setOpen(true)}>
          <Undo2 className="h-4 w-4" /> Withdraw request
        </Button>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3 rounded-lg border border-red-200 bg-red-50 p-4 dark:border-red-900 dark:bg-red-950">
      <p className="text-sm font-medium text-red-800 dark:text-red-300">
        Withdraw this onboarding request? This cannot be undone.
      </p>
      <Input
        label="Reason (optional)"
        placeholder="e.g. Candidate declined the offer"
        value={reason}
        onChange={(e) => setReason(e.target.value)}
      />
      <div className="flex gap-2">
        <Button variant="ghost" size="sm" onClick={() => setOpen(false)}>
          Keep request
        </Button>
        <Button variant="danger" size="sm" loading={withdrawMutation.isPending} onClick={handleWithdraw}>
          Confirm withdrawal
        </Button>
      </div>
    </div>
  );
}
