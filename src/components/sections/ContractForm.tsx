"use client";
// src/components/sections/ContractForm.tsx
//
// The one genuinely new gating requirement in this project: creation
// itself is HR/Admin-only (CONTRACT_MANAGE), not employee-initiated like
// every other module's form. Gated client-side by usePermissions() -
// same UX-convenience-only principle as the Approve/Reject buttons and
// FulfillAssetPanel elsewhere; the real gate is server-side inside
// hr.create_contract() itself.
//
// employeeId is a plain UUID text field, not a name-based picker - see
// this component's own comment on that below. No document upload field:
// document_file_id has no file-storage table anywhere in this project
// yet (per design notes, optional/nullable for this slice), so there's
// nothing to attach to. Left unset here, not silently faked.

import { useState } from "react";
import { z } from "zod";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Button } from "@/components/ui/Button";
import { usePermissions } from "@/context/PermissionContext";
import { useCreateContract } from "@/hooks/useContracts";
import type { ContractType } from "@/types/database.types";

const CONTRACT_TYPES: { value: ContractType; label: string }[] = [
  { value: "PERMANENT", label: "Permanent" },
  { value: "FIXED_TERM", label: "Fixed-Term" },
  { value: "PROBATION", label: "Probation" },
  { value: "INTERNSHIP", label: "Internship" },
  { value: "CONTRACTOR", label: "Contractor" },
];

const contractSchema = z
  .object({
    employeeId: z.string().uuid("Must be a valid user ID (UUID)"),
    contractType: z.string().min(1, "Select a contract type"),
    effectiveFrom: z.string().min(1, "Effective-from date is required"),
    effectiveTo: z.string().optional(),
    notes: z.string().optional(),
  })
  .refine((data) => !data.effectiveTo || data.effectiveTo >= data.effectiveFrom, {
    message: "Effective-to date cannot be before effective-from",
    path: ["effectiveTo"],
  });

type ContractFormValues = z.infer<typeof contractSchema>;

interface ContractFormProps {
  onSuccess?: () => void;
}

export function ContractForm({ onSuccess }: ContractFormProps) {
  const { hasPermission } = usePermissions();
  const createMutation = useCreateContract();

  const [values, setValues] = useState<ContractFormValues>({
    employeeId: "",
    contractType: "",
    effectiveFrom: "",
    effectiveTo: "",
    notes: "",
  });
  const [errors, setErrors] = useState<Partial<Record<keyof ContractFormValues, string>>>({});

  // Not just hiding the submit button - the whole form doesn't render
  // for a non-holder, same as FulfillAssetPanel's approach.
  if (!hasPermission("CONTRACT_MANAGE")) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const result = contractSchema.safeParse(values);
    if (!result.success) {
      const fieldErrors: typeof errors = {};
      for (const issue of result.error.issues) {
        const key = issue.path[0] as keyof ContractFormValues;
        fieldErrors[key] = issue.message;
      }
      setErrors(fieldErrors);
      return;
    }
    setErrors({});

    await createMutation.mutateAsync({
      employeeId: result.data.employeeId,
      contractType: result.data.contractType as ContractType,
      effectiveFrom: result.data.effectiveFrom,
      effectiveTo: result.data.effectiveTo || null,
      notes: result.data.notes || null,
    });

    setValues({ employeeId: "", contractType: "", effectiveFrom: "", effectiveTo: "", notes: "" });
    onSuccess?.();
  };

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4 rounded-lg border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-950">
      <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Create a Contract</h2>

      {/* Plain UUID field, not a name-based picker - this project has no
          employee directory (no core.profiles/hr.employees) anywhere yet.
          Find the UUID under Supabase Authentication -> Users. Flagged as
          a real gap worth solving properly before Onboarding, not
          something worked around here with fake data. */}
      <Input
        label="Employee User ID"
        placeholder="e.g. ed761a27-783e-43d2-8fcd-ac2f64b29249"
        value={values.employeeId}
        onChange={(e) => setValues((v) => ({ ...v, employeeId: e.target.value }))}
        error={errors.employeeId}
      />
      <p className="-mt-3 text-xs text-gray-400">
        Find this under Supabase → Authentication → Users. No employee directory exists in this app yet.
      </p>

      <Select
        label="Contract Type"
        value={values.contractType}
        onChange={(e) => setValues((v) => ({ ...v, contractType: e.target.value }))}
        error={errors.contractType}
      >
        <option value="">Select a type</option>
        {CONTRACT_TYPES.map((t) => (
          <option key={t.value} value={t.value}>
            {t.label}
          </option>
        ))}
      </Select>

      <div className="grid grid-cols-2 gap-4">
        <Input
          type="date"
          label="Effective From"
          value={values.effectiveFrom}
          onChange={(e) => setValues((v) => ({ ...v, effectiveFrom: e.target.value }))}
          error={errors.effectiveFrom}
        />
        <Input
          type="date"
          label="Effective To (optional)"
          value={values.effectiveTo}
          onChange={(e) => setValues((v) => ({ ...v, effectiveTo: e.target.value }))}
          error={errors.effectiveTo}
        />
      </div>

      <Input
        label="Notes (optional)"
        placeholder="Any context worth recording with this version"
        value={values.notes}
        onChange={(e) => setValues((v) => ({ ...v, notes: e.target.value }))}
      />

      <Button type="submit" loading={createMutation.isPending}>
        Create &amp; Submit for Approval
      </Button>
    </form>
  );
}
