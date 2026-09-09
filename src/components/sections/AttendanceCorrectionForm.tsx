"use client";
// src/components/sections/AttendanceCorrectionForm.tsx
//
// Mirrors LeaveRequestForm.tsx's exact structure/conventions. Date and
// time-of-day are captured as separate inputs (clearer UX for "what time
// did you actually check in") and combined into a single timestamptz per
// field before calling the RPC - matches what
// attendance.submit_correction_request() expects.

import { useState } from "react";
import { z } from "zod";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { useSubmitCorrectionRequest } from "@/hooks/useAttendanceCorrections";

const todayStr = () => new Date().toISOString().slice(0, 10);

const correctionRequestSchema = z
  .object({
    attendanceDate: z
      .string()
      .min(1, "Date is required")
      .refine((d) => d <= todayStr(), "Date cannot be in the future"),
    checkInTime: z.string().optional(),
    checkOutTime: z.string().optional(),
    reason: z.string().min(1, "Reason is required"),
  })
  .refine((data) => !!data.checkInTime || !!data.checkOutTime, {
    message: "Provide at least a corrected check-in or check-out time",
    path: ["checkInTime"],
  });

type CorrectionFormValues = z.infer<typeof correctionRequestSchema>;

interface AttendanceCorrectionFormProps {
  onSuccess?: () => void;
}

export function AttendanceCorrectionForm({ onSuccess }: AttendanceCorrectionFormProps) {
  const submitMutation = useSubmitCorrectionRequest();

  const [values, setValues] = useState<CorrectionFormValues>({
    attendanceDate: "",
    checkInTime: "",
    checkOutTime: "",
    reason: "",
  });
  const [errors, setErrors] = useState<Partial<Record<keyof CorrectionFormValues, string>>>({});

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const result = correctionRequestSchema.safeParse(values);
    if (!result.success) {
      const fieldErrors: typeof errors = {};
      for (const issue of result.error.issues) {
        const key = issue.path[0] as keyof CorrectionFormValues;
        fieldErrors[key] = issue.message;
      }
      setErrors(fieldErrors);
      return;
    }
    setErrors({});

    const { attendanceDate, checkInTime, checkOutTime, reason } = result.data;

    await submitMutation.mutateAsync({
      attendanceDate,
      requestedCheckIn: checkInTime ? new Date(`${attendanceDate}T${checkInTime}`).toISOString() : null,
      requestedCheckOut: checkOutTime ? new Date(`${attendanceDate}T${checkOutTime}`).toISOString() : null,
      reason,
    });

    setValues({ attendanceDate: "", checkInTime: "", checkOutTime: "", reason: "" });
    onSuccess?.();
  };

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4 rounded-lg border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-950">
      <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Request an Attendance Correction</h2>

      <Input
        type="date"
        label="Date"
        max={todayStr()}
        value={values.attendanceDate}
        onChange={(e) => setValues((v) => ({ ...v, attendanceDate: e.target.value }))}
        error={errors.attendanceDate}
      />

      <div className="grid grid-cols-2 gap-4">
        <Input
          type="time"
          label="Corrected Check-In"
          value={values.checkInTime}
          onChange={(e) => setValues((v) => ({ ...v, checkInTime: e.target.value }))}
          error={errors.checkInTime}
        />
        <Input
          type="time"
          label="Corrected Check-Out"
          value={values.checkOutTime}
          onChange={(e) => setValues((v) => ({ ...v, checkOutTime: e.target.value }))}
        />
      </div>
      <p className="text-xs text-gray-500 dark:text-gray-400">
        Leave a time blank if only one side needs correcting, or if there's no record for this day at all yet.
      </p>

      <Input
        label="Reason"
        placeholder="e.g. Forgot to check in - was at an off-site client meeting"
        value={values.reason}
        onChange={(e) => setValues((v) => ({ ...v, reason: e.target.value }))}
        error={errors.reason}
      />

      <Button type="submit" loading={submitMutation.isPending}>
        Submit Correction Request
      </Button>
    </form>
  );
}
