"use client";
// src/app/dashboard/leave/balance/page.tsx

import { useMyLeaveBalances } from "@/hooks/useLeaveBalance";
import { LeaveBalanceCard } from "@/components/leave/LeaveBalanceCard";

export default function LeaveBalancePage() {
  const { data: balances, isLoading } = useMyLeaveBalances();

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Leave Balance</h1>

      {isLoading && <p className="text-sm text-gray-500">Loading...</p>}

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {balances?.map((balance) => (
          <LeaveBalanceCard key={balance.leaveTypeId} balance={balance} />
        ))}
      </div>
    </div>
  );
}
