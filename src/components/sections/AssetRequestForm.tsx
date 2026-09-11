"use client";
// src/components/sections/AssetRequestForm.tsx
//
// Mirrors AttendanceCorrectionForm.tsx's exact structure/conventions.
// Category is picked from a dropdown (assets.asset_categories, readable
// by any authenticated employee per 002's RLS) rather than a free-text
// field - the specific physical unit isn't chosen here at all, that
// only happens at fulfillment, after approval (see FulfillAssetPanel).

import { useState } from "react";
import { z } from "zod";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { useAssetCategories, useSubmitAssetRequest } from "@/hooks/useAssetRequests";

const assetRequestSchema = z.object({
  assetCategoryId: z.string().min(1, "Please select a category"),
  justification: z.string().min(1, "Justification is required"),
});

type AssetRequestFormValues = z.infer<typeof assetRequestSchema>;

interface AssetRequestFormProps {
  onSuccess?: () => void;
}

export function AssetRequestForm({ onSuccess }: AssetRequestFormProps) {
  const { data: categories, isLoading: categoriesLoading } = useAssetCategories();
  const submitMutation = useSubmitAssetRequest();

  const [values, setValues] = useState<AssetRequestFormValues>({
    assetCategoryId: "",
    justification: "",
  });
  const [errors, setErrors] = useState<Partial<Record<keyof AssetRequestFormValues, string>>>({});

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const result = assetRequestSchema.safeParse(values);
    if (!result.success) {
      const fieldErrors: typeof errors = {};
      for (const issue of result.error.issues) {
        const key = issue.path[0] as keyof AssetRequestFormValues;
        fieldErrors[key] = issue.message;
      }
      setErrors(fieldErrors);
      return;
    }
    setErrors({});

    await submitMutation.mutateAsync(result.data);

    setValues({ assetCategoryId: "", justification: "" });
    onSuccess?.();
  };

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4 rounded-lg border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-950">
      <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Request an Asset</h2>

      <div className="flex flex-col gap-1">
        <label htmlFor="assetCategoryId" className="text-sm font-medium text-gray-700 dark:text-gray-300">
          Category
        </label>
        <select
          id="assetCategoryId"
          value={values.assetCategoryId}
          onChange={(e) => setValues((v) => ({ ...v, assetCategoryId: e.target.value }))}
          disabled={categoriesLoading}
          className={`rounded-md border px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-900 dark:text-gray-100 ${
            errors.assetCategoryId ? "border-red-500" : "border-gray-300 dark:border-gray-700"
          }`}
        >
          <option value="">{categoriesLoading ? "Loading categories..." : "Select a category"}</option>
          {categories?.map((category) => (
            <option key={category.id} value={category.id}>
              {category.categoryName}
            </option>
          ))}
        </select>
        {errors.assetCategoryId && <span className="text-xs text-red-500">{errors.assetCategoryId}</span>}
      </div>

      <Input
        label="Justification"
        placeholder="e.g. Existing laptop is 5 years old and struggling to run required tools"
        value={values.justification}
        onChange={(e) => setValues((v) => ({ ...v, justification: e.target.value }))}
        error={errors.justification}
      />

      <Button type="submit" loading={submitMutation.isPending}>
        Submit Asset Request
      </Button>
    </form>
  );
}
