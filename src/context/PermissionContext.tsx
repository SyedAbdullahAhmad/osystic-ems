"use client";
// src/context/PermissionContext.tsx
//
// Uses core.get_user_permissions() (confirmed real, existing Finance RPC -
// see LEAVE_MODULE_HANDOFF.md section 4) rather than a profiles-table
// flag check. Fetches once per session and caches - permission checks in
// components are then synchronous (hasPermission("LEAVE_VIEW_ALL")),
// not an async call per check.

import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { supabase, coreDB } from "@/lib/supabase";
import { useAuth } from "./AuthContext";

interface Permission {
  code: string;
  module: string;
  action: string;
  dataScope: string;
  amountLimit: number | null;
}

interface PermissionContextValue {
  permissions: Permission[];
  loading: boolean;
  hasPermission: (code: string) => boolean;
  refetch: () => Promise<void>;
}

const PermissionContext = createContext<PermissionContextValue | undefined>(undefined);

export function PermissionProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth();
  const [permissions, setPermissions] = useState<Permission[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchPermissions = async () => {
    if (!user) {
      setPermissions([]);
      setLoading(false);
      return;
    }

    setLoading(true);
    const { data, error } = await coreDB.rpc("get_user_permissions", { p_user_id: user.id });

    if (error) {
      console.error("Failed to load permissions:", error.message);
      setPermissions([]);
    } else {
      setPermissions(
        (data ?? []).map((row: any) => ({
          code: row.code,
          module: row.module,
          action: row.action,
          dataScope: row.data_scope,
          amountLimit: row.amount_limit,
        }))
      );
    }
    setLoading(false);
  };

  useEffect(() => {
    fetchPermissions();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user?.id]);

  const hasPermission = (code: string) => permissions.some((p) => p.code === code);

  return (
    <PermissionContext.Provider value={{ permissions, loading, hasPermission, refetch: fetchPermissions }}>
      {children}
    </PermissionContext.Provider>
  );
}

export function usePermissions() {
  const ctx = useContext(PermissionContext);
  if (!ctx) throw new Error("usePermissions must be used within PermissionProvider");
  return ctx;
}