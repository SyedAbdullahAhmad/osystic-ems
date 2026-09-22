"use client";
// src/app/dashboard/contracts/page.tsx
// Mirrors src/app/dashboard/assets/requests/page.tsx, with one
// difference: the "New Contract" button/form only renders for
// CONTRACT_MANAGE holders (ContractForm.tsx handles that gate itself -
// this page just conditionally shows the toggle button around it).

import { useState } from "react";
import { Plus, X } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { ContractForm } from "@/components/sections/ContractForm";
import { ContractCard } from "@/components/contracts/ContractCard";
import { useContracts } from "@/hooks/useContracts";
import { usePermissions } from "@/context/PermissionContext";

export default function ContractsPage() {
  const [showForm, setShowForm] = useState(false);
  const { data: contracts, isLoading } = useContracts();
  const { hasPermission } = usePermissions();

  const canManage = hasPermission("CONTRACT_MANAGE");

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Contracts</h1>
        {canManage && (
          <Button onClick={() => setShowForm((v) => !v)} variant={showForm ? "secondary" : "primary"}>
            {showForm ? <X className="h-4 w-4" /> : <Plus className="h-4 w-4" />}
            {showForm ? "Cancel" : "New Contract"}
          </Button>
        )}
      </div>

      {showForm && <ContractForm onSuccess={() => setShowForm(false)} />}

      <div className="flex flex-col gap-2">
        {isLoading && <p className="text-sm text-gray-500">Loading...</p>}
        {!isLoading && contracts?.length === 0 && (
          <p className="text-sm text-gray-500">
            {canManage ? "No contracts yet. Create your first one above." : "No contracts on record for you yet."}
          </p>
        )}
        {contracts?.map((contract) => (
          <ContractCard key={contract.id} contract={contract} />
        ))}
      </div>
    </div>
  );
}
