// src/components/onboarding/OnboardingCard.tsx
import Link from "next/link";
import { format, parseISO } from "date-fns";
import type { OnboardingRecord } from "@/types/onboarding.types";

export const onboardingStatusStyles: Record<string, string> = {
  DRAFT: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
  SUBMITTED: "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300",
  APPROVED: "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300",
  REJECTED: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300",
  WITHDRAWN: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
  HIRED: "bg-green-100 text-green-700 dark:bg-green-950 dark:text-green-300",
};

export function candidateLabel(record: OnboardingRecord) {
  return record.candidateName ?? `Candidate ${record.personId.slice(0, 8)}`;
}

export function OnboardingCard({ record }: { record: OnboardingRecord }) {
  return (
    <Link
      href={`/dashboard/onboarding/${record.id}`}
      className="flex items-center justify-between rounded-lg border border-gray-200 bg-white p-4 transition-colors hover:border-blue-300 dark:border-gray-800 dark:bg-gray-950 dark:hover:border-blue-700"
    >
      <div>
        <p className="font-medium text-gray-900 dark:text-white">
          {candidateLabel(record)}
          {record.positionTitle ? ` — ${record.positionTitle}` : ""}
        </p>
        {record.candidateEmail && <p className="text-sm text-gray-500 dark:text-gray-400">{record.candidateEmail}</p>}
        {record.proposedStartDate && (
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Proposed start {format(parseISO(record.proposedStartDate), "MMM d, yyyy")}
          </p>
        )}
        <p className="text-xs text-gray-400">{format(parseISO(record.createdAt), "MMM d, yyyy")}</p>
      </div>
      <span className={`rounded-full px-3 py-1 text-xs font-medium ${onboardingStatusStyles[record.status]}`}>
        {record.status}
      </span>
    </Link>
  );
}
