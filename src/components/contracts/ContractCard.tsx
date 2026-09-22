// src/components/contracts/ContractCard.tsx
import Link from "next/link";
import { format, parseISO } from "date-fns";
import type { Contract } from "@/types/contracts.types";

const statusStyles: Record<string, string> = {
  DRAFT: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
  PENDING_APPROVAL: "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300",
  APPROVED: "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300",
  REJECTED: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300",
  ACTIVE: "bg-green-100 text-green-700 dark:bg-green-950 dark:text-green-300",
  EXPIRED: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
  TERMINATED: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300",
};

const typeLabels: Record<string, string> = {
  PERMANENT: "Permanent",
  FIXED_TERM: "Fixed-Term",
  PROBATION: "Probation",
  INTERNSHIP: "Internship",
  CONTRACTOR: "Contractor",
};

export function ContractCard({ contract }: { contract: Contract }) {
  return (
    <Link
      href={`/dashboard/contracts/${contract.id}`}
      className="flex items-center justify-between rounded-lg border border-gray-200 bg-white p-4 transition-colors hover:border-blue-300 dark:border-gray-800 dark:bg-gray-950 dark:hover:border-blue-700"
    >
      <div>
        <p className="font-medium text-gray-900 dark:text-white">
          {contract.contractNumber} — {typeLabels[contract.contractType] ?? contract.contractType}
        </p>
        {contract.effectiveFrom && (
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Effective {format(parseISO(contract.effectiveFrom), "MMM d, yyyy")}
            {contract.effectiveTo ? ` – ${format(parseISO(contract.effectiveTo), "MMM d, yyyy")}` : " (no end date)"}
          </p>
        )}
        <p className="text-xs text-gray-400">{format(parseISO(contract.createdAt), "MMM d, yyyy")}</p>
      </div>
      <span className={`rounded-full px-3 py-1 text-xs font-medium ${statusStyles[contract.status]}`}>
        {contract.status.replace("_", " ")}
      </span>
    </Link>
  );
}
