// src/app/dashboard/page.tsx
import { EmployeeDashboard } from "@/components/dashboards/employee/EmployeeDashboard";

export default function DashboardPage() {
  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Dashboard</h1>
      <EmployeeDashboard />
    </div>
  );
}
