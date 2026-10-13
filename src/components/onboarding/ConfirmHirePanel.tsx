"use client";
// src/components/onboarding/ConfirmHirePanel.tsx
//
// Same role as FulfillAssetPanel: a deliberate manual step after approval.
// Only rendered by the parent page when status is APPROVED. The
// hasPermission gate is UX only - confirm_employee_hire() enforces its
// permissions itself, server-side.

import { useState } from "react";
import { UserCheck } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { usePermissions } from "@/context/PermissionContext";
import { useConfirmHire } from "@/hooks/useOnboarding";

interface ConfirmHirePanelProps {
  onboardingRecordId: string;
  onConfirmed?: () => void;
}

export function ConfirmHirePanel({ onboardingRecordId, onConfirmed }: ConfirmHirePanelProps) {
  const { hasPermission } = usePermissions();
  const confirmMutation = useConfirmHire();
  const [employeeNumber, setEmployeeNumber] = useState("");
  const [hireDate, setHireDate] = useState("");

  if (!hasPermission("ONBOARDING_MANAGE")) return null;

  const handleConfirm = async () => {
    await confirmMutation.mutateAsync({
      onboardingRecordId,
      employeeNumber: employeeNumber.trim() || null,
      hireDate: hireDate || null,
    });
    onConfirmed?.();
  };

  return (
    <div className="flex flex-col gap-3 rounded-lg border border-blue-200 bg-blue-50 p-4 dark:border-blue-900 dark:bg-blue-950">
      <p className="text-sm font-medium text-blue-800 dark:text-blue-300">
        Approved — confirm the hire to turn this candidate into an employee
      </p>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Input
          label="Employee number (optional)"
          placeholder="Leave blank to assign later"
          value={employeeNumber}
          onChange={(e) => setEmployeeNumber(e.target.value)}
        />
        <Input type="date" label="Hire date (optional)" value={hireDate} onChange={(e) => setHireDate(e.target.value)} />
      </div>
      <div>
        <Button size="sm" loading={confirmMutation.isPending} onClick={handleConfirm}>
          <UserCheck className="h-4 w-4" /> Confirm hire
        </Button>
      </div>
    </div>
  );
}
