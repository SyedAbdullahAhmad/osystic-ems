// src/components/assets/AssetRequestCard.tsx
import Link from "next/link";
import { format, parseISO } from "date-fns";
import type { AssetRequest } from "@/types/assets.types";

const statusStyles: Record<string, string> = {
  SUBMITTED: "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300",
  APPROVED: "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300",
  REJECTED: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300",
  CANCELLED: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
  FULFILLED: "bg-green-100 text-green-700 dark:bg-green-950 dark:text-green-300",
};

export function AssetRequestCard({ request }: { request: AssetRequest }) {
  return (
    <Link
      href={`/dashboard/assets/requests/${request.id}`}
      className="flex items-center justify-between rounded-lg border border-gray-200 bg-white p-4 transition-colors hover:border-blue-300 dark:border-gray-800 dark:bg-gray-950 dark:hover:border-blue-700"
    >
      <div>
        <p className="font-medium text-gray-900 dark:text-white">
          {request.categoryName ?? "Asset Request"}
        </p>
        <p className="text-sm text-gray-500 dark:text-gray-400 line-clamp-1">{request.justification}</p>
        <p className="text-xs text-gray-400">
          {format(parseISO(request.createdAt), "MMM d, yyyy")}
        </p>
      </div>
      <span className={`rounded-full px-3 py-1 text-xs font-medium ${statusStyles[request.requestStatus]}`}>
        {request.requestStatus}
      </span>
    </Link>
  );
}
