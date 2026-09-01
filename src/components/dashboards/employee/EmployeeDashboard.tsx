"use client";
// src/components/dashboards/employee/EmployeeDashboard.tsx

import { CalendarCheck, Clock, Wallet } from "lucide-react";
import { StatCard } from "@/components/dashboards/shared/StatCard";
import { useMyLeaveRequests } from "@/hooks/useLeaveRequests";
import { useMyLeaveBalances } from "@/hooks/useLeaveBalance";
import { LeaveRequestCard } from "@/components/leave/LeaveRequestCard";

export function EmployeeDashboard() {
  const { data: requests, isLoading: requestsLoading } = useMyLeaveRequests();
  const { data: balances, isLoading: balancesLoading } = useMyLeaveBalances();

  const pendingCount = requests?.filter((r) => r.requestStatus === "SUBMITTED").length ?? 0;
  const approvedCount = requests?.filter((r) => r.requestStatus === "APPROVED").length ?? 0;
  const totalBalance = balances?.reduce((sum, b) => sum + b.balanceDays, 0) ?? 0;

  return (
    <div className="flex flex-col gap-6">
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <StatCard label="Pending Requests" value={requestsLoading ? "..." : pendingCount} icon={Clock} />
        <StatCard label="Approved This Year" value={requestsLoading ? "..." : approvedCount} icon={CalendarCheck} />
        <StatCard label="Total Days Remaining" value={balancesLoading ? "..." : totalBalance} icon={Wallet} />
      </div>

      <div>
        <h3 className="mb-3 text-sm font-semibold text-gray-700 dark:text-gray-300">Recent Requests</h3>
        <div className="flex flex-col gap-2">
          {requestsLoading && <p className="text-sm text-gray-500">Loading...</p>}
          {!requestsLoading && requests?.length === 0 && (
            <p className="text-sm text-gray-500">No leave requests yet.</p>
          )}
          {requests?.slice(0, 5).map((request) => (
            <LeaveRequestCard key={request.id} request={request} />
          ))}
        </div>
      </div>
    </div>
  );
}
