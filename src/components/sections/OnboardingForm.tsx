"use client";
// src/components/sections/OnboardingForm.tsx
//
// Creation is HR-only (ONBOARDING_MANAGE), like ContractForm: the whole
// form does not render for a non-holder; the real gate is server-side in
// create_and_submit_onboarding_request().
//
// Idempotency: the RPC dedupes on idempotency_key + payload hash. A key is
// reused when the SAME payload is resubmitted (double-click / retry after a
// network error returns the existing record), and a NEW key is generated
// whenever the payload changed - reusing a key with a different payload is
// rejected by the server (ONBOARDING_IDEMPOTENCY_KEY_PAYLOAD_MISMATCH).

import { useRef, useState } from "react";
import { z } from "zod";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Button } from "@/components/ui/Button";
import { usePermissions } from "@/context/PermissionContext";
import { useCreateOnboarding, useDepartments } from "@/hooks/useOnboarding";

const onboardingSchema = z.object({
  fullName: z.string().trim().min(2, "Full name is required"),
  email: z.string().trim().email("Enter a valid email address"),
  positionTitle: z.string().optional(),
  departmentId: z.string().optional(),
  proposedStartDate: z.string().optional(),
});

type OnboardingFormValues = z.infer<typeof onboardingSchema>;

const EMPTY: OnboardingFormValues = {
  fullName: "",
  email: "",
  positionTitle: "",
  departmentId: "",
  proposedStartDate: "",
};

interface OnboardingFormProps {
  onSuccess?: () => void;
}

export function OnboardingForm({ onSuccess }: OnboardingFormProps) {
  const { hasPermission } = usePermissions();
  const createMutation = useCreateOnboarding();
  const { data: departments } = useDepartments();

  const [values, setValues] = useState<OnboardingFormValues>(EMPTY);
  const [errors, setErrors] = useState<Partial<Record<keyof OnboardingFormValues, string>>>({});

  const keyRef = useRef<{ payload: string; key: string } | null>(null);

  if (!hasPermission("ONBOARDING_MANAGE")) return null;

  const keyFor = (payload: string) => {
    if (keyRef.current?.payload !== payload) {
      keyRef.current = { payload, key: crypto.randomUUID() };
    }
    return keyRef.current.key;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const result = onboardingSchema.safeParse(values);
    if (!result.success) {
      const fieldErrors: typeof errors = {};
      for (const issue of result.error.issues) {
        fieldErrors[issue.path[0] as keyof OnboardingFormValues] = issue.message;
      }
      setErrors(fieldErrors);
      return;
    }
    setErrors({});

    const d = result.data;
    const payload = JSON.stringify([d.fullName, d.email.toLowerCase(), d.positionTitle || "", d.departmentId || "", d.proposedStartDate || ""]);

    await createMutation.mutateAsync({
      fullName: d.fullName,
      email: d.email,
      positionTitle: d.positionTitle || null,
      departmentId: d.departmentId || null,
      proposedStartDate: d.proposedStartDate || null,
      idempotencyKey: keyFor(payload),
    });

    keyRef.current = null;
    setValues(EMPTY);
    onSuccess?.();
  };

  return (
    <form
      onSubmit={handleSubmit}
      className="flex flex-col gap-4 rounded-lg border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-950"
    >
      <h2 className="text-lg font-semibold text-gray-900 dark:text-white">New Onboarding Request</h2>

      <Input
        label="Candidate full name"
        value={values.fullName}
        onChange={(e) => setValues((v) => ({ ...v, fullName: e.target.value }))}
        error={errors.fullName}
      />
      <Input
        type="email"
        label="Candidate email"
        value={values.email}
        onChange={(e) => setValues((v) => ({ ...v, email: e.target.value }))}
        error={errors.email}
      />
      <Input
        label="Position title (optional)"
        value={values.positionTitle}
        onChange={(e) => setValues((v) => ({ ...v, positionTitle: e.target.value }))}
      />

      {departments && departments.length > 0 && (
        <Select
          label="Department (optional)"
          value={values.departmentId}
          onChange={(e) => setValues((v) => ({ ...v, departmentId: e.target.value }))}
        >
          <option value="">No department</option>
          {departments.map((d) => (
            <option key={d.id} value={d.id}>
              {d.name}
            </option>
          ))}
        </Select>
      )}

      <Input
        type="date"
        label="Proposed start date (optional)"
        value={values.proposedStartDate}
        onChange={(e) => setValues((v) => ({ ...v, proposedStartDate: e.target.value }))}
      />

      <Button type="submit" loading={createMutation.isPending}>
        Create &amp; Submit for Approval
      </Button>
    </form>
  );
}
