"use client";
// src/app/dashboard/onboarding/page.tsx
// Mirrors src/app/dashboard/contracts/page.tsx: "New" button/form only for
// ONBOARDING_MANAGE holders; the list itself is scoped by RLS.

import { useState } from "react";
import { Plus, X } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { OnboardingForm } from "@/components/sections/OnboardingForm";
import { OnboardingCard } from "@/components/onboarding/OnboardingCard";
import { useOnboardingRecords } from "@/hooks/useOnboarding";
import { usePermissions } from "@/context/PermissionContext";

export default function OnboardingPage() {
  const [showForm, setShowForm] = useState(false);
  const { data: records, isLoading, error } = useOnboardingRecords();
  const { hasPermission } = usePermissions();

  const canManage = hasPermission("ONBOARDING_MANAGE");

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Onboarding</h1>
        {canManage && (
          <Button onClick={() => setShowForm((v) => !v)} variant={showForm ? "secondary" : "primary"}>
            {showForm ? <X className="h-4 w-4" /> : <Plus className="h-4 w-4" />}
            {showForm ? "Cancel" : "New Onboarding Request"}
          </Button>
        )}
      </div>

      {showForm && <OnboardingForm onSuccess={() => setShowForm(false)} />}

      <div className="flex flex-col gap-2">
        {isLoading && <p className="text-sm text-gray-500">Loading...</p>}
        {error && <p className="text-sm text-red-500">{(error as Error).message}</p>}
        {!isLoading && !error && records?.length === 0 && (
          <p className="text-sm text-gray-500">
            {canManage ? "No onboarding requests yet. Create the first one above." : "No onboarding record on file for you."}
          </p>
        )}
        {records?.map((record) => (
          <OnboardingCard key={record.id} record={record} />
        ))}
      </div>
    </div>
  );
}
