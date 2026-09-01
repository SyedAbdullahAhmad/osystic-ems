// src/components/leave/LeaveBalanceCard.tsx
import type { LeaveBalance } from "@/types/leave.types";

export function LeaveBalanceCard({ balance }: { balance: LeaveBalance }) {
  const percentUsed = balance.maxDaysPerYear
    ? Math.min(100, Math.max(0, 100 - (balance.balanceDays / balance.maxDaysPerYear) * 100))
    : null;

  return (
    <div className="rounded-lg border border-gray-200 bg-white p-4 dark:border-gray-800 dark:bg-gray-950">
      <p className="text-sm font-medium text-gray-500 dark:text-gray-400">{balance.leaveTypeName}</p>
      <p className="mt-1 text-2xl font-semibold text-gray-900 dark:text-white">
        {balance.balanceDays} <span className="text-sm font-normal text-gray-500">days</span>
      </p>
      {balance.maxDaysPerYear && (
        <>
          <div className="mt-3 h-2 w-full overflow-hidden rounded-full bg-gray-100 dark:bg-gray-800">
            <div className="h-full bg-blue-500" style={{ width: `${percentUsed}%` }} />
          </div>
          <p className="mt-1 text-xs text-gray-400">of {balance.maxDaysPerYear} days/year</p>
        </>
      )}
    </div>
  );
}
