// src/components/leave/LeaveRequestCard.tsx
import Link from "next/link";
import { format, parseISO } from "date-fns";
import type { LeaveRequest } from "@/types/leave.types";

const statusStyles: Record<string, string> = {
  DRAFT: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300",
  SUBMITTED: "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300",
  APPROVED: "bg-green-100 text-green-700 dark:bg-green-950 dark:text-green-300",
  REJECTED: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300",
  CANCELLED: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
};

export function LeaveRequestCard({ request }: { request: LeaveRequest }) {
  return (
    <Link
      href={`/dashboard/leave/requests/${request.id}`}
      className="flex items-center justify-between rounded-lg border border-gray-200 bg-white p-4 transition-colors hover:border-blue-300 dark:border-gray-800 dark:bg-gray-950 dark:hover:border-blue-700"
    >
      <div>
        <p className="font-medium text-gray-900 dark:text-white">{request.leaveTypeName ?? "Leave Request"}</p>
        <p className="text-sm text-gray-500 dark:text-gray-400">
          {format(parseISO(request.startDate), "MMM d, yyyy")} - {format(parseISO(request.endDate), "MMM d, yyyy")}
          {" "}({request.totalDays} day{request.totalDays !== 1 ? "s" : ""})
        </p>
      </div>
      <span className={`rounded-full px-3 py-1 text-xs font-medium ${statusStyles[request.requestStatus]}`}>
        {request.requestStatus}
      </span>
    </Link>
  );
}
