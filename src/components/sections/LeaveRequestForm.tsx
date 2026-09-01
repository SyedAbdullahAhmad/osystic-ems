"use client";
// src/components/sections/LeaveRequestForm.tsx

import { useState } from "react";
import { z } from "zod";
import { differenceInCalendarDays, parseISO } from "date-fns";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Button } from "@/components/ui/Button";
import { useLeaveTypes } from "@/hooks/useLeaveRequests";
import { useSubmitLeaveRequest } from "@/hooks/useLeaveRequests";

const leaveRequestSchema = z
  .object({
    leaveTypeId: z.string().min(1, "Select a leave type"),
    startDate: z.string().min(1, "Start date is required"),
    endDate: z.string().min(1, "End date is required"),
    reason: z.string().optional(),
  })
  .refine((data) => data.endDate >= data.startDate, {
    message: "End date must be on or after start date",
    path: ["endDate"],
  });

type LeaveRequestFormValues = z.infer<typeof leaveRequestSchema>;

interface LeaveRequestFormProps {
  onSuccess?: () => void;
}

export function LeaveRequestForm({ onSuccess }: LeaveRequestFormProps) {
  const { data: leaveTypes, isLoading: typesLoading } = useLeaveTypes();
  const submitMutation = useSubmitLeaveRequest();

  const [values, setValues] = useState<LeaveRequestFormValues>({
    leaveTypeId: "",
    startDate: "",
    endDate: "",
    reason: "",
  });
  const [errors, setErrors] = useState<Partial<Record<keyof LeaveRequestFormValues, string>>>({});

  const totalDays =
    values.startDate && values.endDate && values.endDate >= values.startDate
      ? differenceInCalendarDays(parseISO(values.endDate), parseISO(values.startDate)) + 1
      : 0;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const result = leaveRequestSchema.safeParse(values);
    if (!result.success) {
      const fieldErrors: typeof errors = {};
      for (const issue of result.error.issues) {
        const key = issue.path[0] as keyof LeaveRequestFormValues;
        fieldErrors[key] = issue.message;
      }
      setErrors(fieldErrors);
      return;
    }
    setErrors({});

    await submitMutation.mutateAsync({
      leaveTypeId: result.data.leaveTypeId,
      startDate: result.data.startDate,
      endDate: result.data.endDate,
      totalDays,
      reason: result.data.reason,
    });

    setValues({ leaveTypeId: "", startDate: "", endDate: "", reason: "" });
    onSuccess?.();
  };

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4 rounded-lg border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-950">
      <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Request Leave</h2>

      <Select
        label="Leave Type"
        value={values.leaveTypeId}
        onChange={(e) => setValues((v) => ({ ...v, leaveTypeId: e.target.value }))}
        error={errors.leaveTypeId}
        disabled={typesLoading}
      >
        <option value="">Select a leave type...</option>
        {leaveTypes?.map((type) => (
          <option key={type.id} value={type.id}>
            {type.leaveName}
            {type.maxDaysPerYear ? ` (max ${type.maxDaysPerYear} days/year)` : ""}
          </option>
        ))}
      </Select>

      <div className="grid grid-cols-2 gap-4">
        <Input
          type="date"
          label="Start Date"
          value={values.startDate}
          onChange={(e) => setValues((v) => ({ ...v, startDate: e.target.value }))}
          error={errors.startDate}
        />
        <Input
          type="date"
          label="End Date"
          value={values.endDate}
          onChange={(e) => setValues((v) => ({ ...v, endDate: e.target.value }))}
          error={errors.endDate}
        />
      </div>

      {totalDays > 0 && (
        <p className="text-sm text-gray-600 dark:text-gray-400">
          Total: <span className="font-medium">{totalDays}</span> day{totalDays !== 1 ? "s" : ""}
        </p>
      )}

      <Input
        label="Reason (optional)"
        placeholder="Brief reason for this leave request"
        value={values.reason}
        onChange={(e) => setValues((v) => ({ ...v, reason: e.target.value }))}
      />

      <Button type="submit" loading={submitMutation.isPending} disabled={totalDays === 0}>
        Submit Request
      </Button>
    </form>
  );
}
