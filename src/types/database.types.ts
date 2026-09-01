// src/types/database.types.ts
//
// Hand-written to match the migrations in
// supabase/migrations/P0/phase_2_leave_module/. Once this is actually
// applied to a live Supabase project, regenerate the real thing with:
//   npx supabase gen types typescript --project-id <ref> > src/types/database.types.ts
// and merge in the workflow-schema types the same way. Keeping this
// hand-written version in the meantime so the app is still fully typed.

export type LeaveTypeStatus = "ACTIVE" | "INACTIVE";
export type LedgerMovementType = "ACCRUAL" | "DEDUCTION" | "ADJUSTMENT" | "CARRYOVER" | "FORFEITURE";
export type LeaveRequestStatus = "DRAFT" | "SUBMITTED" | "APPROVED" | "REJECTED" | "CANCELLED";

export interface Database {
  core: {
    Tables: {
      permissions: {
        Row: {
          id: string;
          code: string;
          name: string;
          module: string;
          action: string;
          description: string | null;
          is_system: boolean;
          created_at: string;
          updated_at: string;
          created_by: string | null;
        };
      };
      roles: {
        Row: {
          id: string;
          name: string;
          display_name: string;
          description: string | null;
          is_system: boolean;
          level: number;
        };
      };
    };
    Functions: {
      get_user_permissions: {
        Args: { p_user_id: string };
        Returns: {
          code: string;
          module: string;
          action: string;
          data_scope: string;
          amount_limit: number | null;
        }[];
      };
      has_permission: {
        Args: { p_user_id: string; p_permission_code: string };
        Returns: boolean;
      };
    };
  };
  leave: {
    Tables: {
      leave_types: {
        Row: {
          id: string;
          leave_code: string;
          leave_name: string;
          description: string | null;
          requires_approval: boolean;
          is_paid: boolean;
          max_days_per_year: number | null;
          status: LeaveTypeStatus;
          created_at: string;
          updated_at: string;
          created_by: string;
          updated_by: string | null;
          version: number;
        };
        Insert: Partial<Database["leave"]["Tables"]["leave_types"]["Row"]>;
        Update: Partial<Database["leave"]["Tables"]["leave_types"]["Row"]>;
      };
      leave_requests: {
        Row: {
          id: string;
          employee_id: string;
          leave_type_id: string;
          start_date: string;
          end_date: string;
          total_days: number;
          reason: string | null;
          request_status: LeaveRequestStatus;
          workflow_request_id: string | null;
          submitted_at: string | null;
          created_at: string;
          updated_at: string;
          created_by: string;
          updated_by: string | null;
          version: number;
        };
        Insert: Partial<Database["leave"]["Tables"]["leave_requests"]["Row"]>;
        Update: Partial<Database["leave"]["Tables"]["leave_requests"]["Row"]>;
      };
      leave_ledger: {
        Row: {
          id: string;
          employee_id: string;
          leave_type_id: string;
          movement_type: LedgerMovementType;
          amount_days: number;
          effective_date: string;
          policy_version_id: string | null;
          source_request_id: string | null;
          created_at: string;
          created_by: string;
          version: number;
        };
        Insert: Partial<Database["leave"]["Tables"]["leave_ledger"]["Row"]>;
        Update: never; // append-only, enforced server-side too
      };
    };
    Views: {
      v_leave_balances: {
        Row: {
          employee_id: string;
          leave_type_id: string;
          balance_days: number;
        };
      };
      v_leave_request_approvals: {
        Row: {
          leave_request_id: string;
          employee_id: string;
          from_status: string | null;
          to_status: string;
          changed_at: string;
          reason: string | null;
          actor_user_id: string | null;
          action: string | null;
          action_comments: string | null;
        };
      };
    };
    Functions: {
      submit_leave_request: {
        Args: {
          p_leave_type_id: string;
          p_start_date: string;
          p_end_date: string;
          p_total_days: number;
          p_reason?: string | null;
          p_idempotency_key?: string | null;
        };
        Returns: {
          leave_request_id: string;
          workflow_request_id: string | null;
          status: string;
        };
      };
    };
  };
  workflow: {
    Tables: {
      approval_requests: {
        Row: {
          id: string;
          workflow_definition_id: string;
          workflow_version_id: string;
          entity_type: string;
          entity_id: string;
          current_status: string;
          current_step_no: number | null;
          is_open: boolean;
          initiated_by_user_id: string;
          completed_at: string | null;
          version: number;
        };
      };
    };
    Functions: {
      process_approval_action: {
        Args: {
          p_approval_request_id: string;
          p_action: "APPROVE" | "REJECT" | "SKIP";
          p_approval_step_id: string;
          p_comments?: string | null;
          p_metadata?: Record<string, unknown> | null;
          p_idempotency_key: string;
          p_expected_version: number;
        };
        Returns: Record<string, unknown>;
      };
    };
  };
}