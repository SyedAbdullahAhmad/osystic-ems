"use client";
// src/hooks/useUserRole.ts
// Thin convenience wrapper over PermissionContext, matching Finance's
// useUserRole.ts naming convention.

import { usePermissions } from "@/context/PermissionContext";

export function useUserRole() {
  const { permissions, loading, hasPermission } = usePermissions();

  return {
    loading,
    hasPermission,
    isLeaveAdmin: hasPermission("LEAVE_CONFIG_MANAGE"),
    canViewAllLeave: hasPermission("LEAVE_VIEW_ALL"),
    permissions,
  };
}
