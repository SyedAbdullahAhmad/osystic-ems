// src/types/database.types.ts
//
// Hand-written to match the migrations in supabase/migrations/. Once
// this is actually applied to a live Supabase project, regenerate the
// real thing with:
//   npx supabase gen types typescript --project-id <ref> > src/types/database.types.ts
// and merge in anything hand-added since (e.g. this file's Functions
// blocks). Keeping this hand-written version in the meantime so the app
// is still fully typed.
//
// IMPORTANT - real bug fixed here, not just a style choice: every schema
// object below MUST have Tables + Views + Functions, and every table/view
// entry MUST have Row + Insert + Update + Relationships (Relationships
// can be an empty array if you don't need typed embeds - see
// GenericTable/GenericSchema in
// node_modules/@supabase/postgrest-js/dist/index.d.mts). Earlier versions
// of this file omitted Insert/Update/Relationships/Views on several
// entries; @supabase/supabase-js's SupabaseClient generic silently
// resolves the whole per-schema Schema type to `never` if ANY of these
// are missing anywhere in that schema, which is what caused `next build`
// to fail with ".from()/.rpc() argument not assignable to `never`/
// `undefined`" across leave.service.ts, workflow.service.ts,
// attendance.service.ts, and PermissionContext.tsx - confirmed by
// checking @supabase/postgrest-js's actual type requirements, not
// guessed. Keep this shape complete for every table/view added in the
// future, or the same class of error will silently come back.
//
// Also required: pass the SchemaName as an explicit second generic
// argument at each createBrowserClient<Database, "schema_name">(...)
// call site in lib/supabase.ts - without it, TypeScript can't infer
// which schema key to use from the runtime `db: { schema: "..." }`
// option alone.

export type LeaveTypeStatus = "ACTIVE" | "INACTIVE";
export type LedgerMovementType = "ACCRUAL" | "DEDUCTION" | "ADJUSTMENT" | "CARRYOVER" | "FORFEITURE";
export type LeaveRequestStatus = "DRAFT" | "SUBMITTED" | "APPROVED" | "REJECTED" | "CANCELLED";
export type AttendanceStatus = "PRESENT" | "ABSENT" | "LATE" | "HALF_DAY" | "ON_LEAVE";
export type AttendanceCorrectionRequestStatus = "SUBMITTED" | "APPROVED" | "REJECTED" | "CANCELLED";
export type AssetStatus = "AVAILABLE" | "ASSIGNED" | "IN_REPAIR" | "RETIRED";
export type AssetRequestStatus = "SUBMITTED" | "APPROVED" | "REJECTED" | "CANCELLED" | "FULFILLED";
export type ContractType = "PERMANENT" | "FIXED_TERM" | "PROBATION" | "INTERNSHIP" | "CONTRACTOR";
export type ContractStatus = "DRAFT" | "PENDING_APPROVAL" | "APPROVED" | "REJECTED" | "ACTIVE" | "EXPIRED" | "TERMINATED";

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
        Insert: Partial<Database["core"]["Tables"]["permissions"]["Row"]>;
        Update: Partial<Database["core"]["Tables"]["permissions"]["Row"]>;
        Relationships: [];
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
        Insert: Partial<Database["core"]["Tables"]["roles"]["Row"]>;
        Update: Partial<Database["core"]["Tables"]["roles"]["Row"]>;
        Relationships: [];
      };
    };
    Views: {};
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
        Relationships: [];
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
        Relationships: [];
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
        Update: Record<string, never>; // append-only, enforced server-side too
        Relationships: [];
      };
    };
    Views: {
      v_leave_balances: {
        Row: {
          employee_id: string;
          leave_type_id: string;
          balance_days: number;
        };
        Relationships: [];
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
        Relationships: [];
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
  attendance: {
    Tables: {
      attendance_days: {
        Row: {
          id: string;
          employee_id: string;
          attendance_date: string;
          first_check_in: string | null;
          last_check_out: string | null;
          worked_minutes: number | null;
          attendance_status: AttendanceStatus;
          created_at: string;
          updated_at: string;
          created_by: string;
          updated_by: string | null;
          version: number;
        };
        Insert: Partial<Database["attendance"]["Tables"]["attendance_days"]["Row"]>;
        Update: Partial<Database["attendance"]["Tables"]["attendance_days"]["Row"]>;
        Relationships: [];
      };
      correction_requests: {
        Row: {
          id: string;
          attendance_day_id: string;
          employee_id: string;
          requested_check_in: string | null;
          requested_check_out: string | null;
          reason: string;
          request_status: AttendanceCorrectionRequestStatus;
          workflow_request_id: string | null;
          submitted_at: string | null;
          created_at: string;
          updated_at: string;
          created_by: string;
          updated_by: string | null;
          version: number;
        };
        Insert: Partial<Database["attendance"]["Tables"]["correction_requests"]["Row"]>;
        Update: Partial<Database["attendance"]["Tables"]["correction_requests"]["Row"]>;
        Relationships: [
          {
            foreignKeyName: "correction_requests_attendance_day_id_fkey";
            columns: ["attendance_day_id"];
            isOneToOne: false;
            referencedRelation: "attendance_days";
            referencedColumns: ["id"];
          }
        ];
      };
    };
    Views: {
      v_correction_request_approvals: {
        Row: {
          correction_request_id: string;
          employee_id: string;
          from_status: string | null;
          to_status: string;
          changed_at: string;
          reason: string | null;
          actor_user_id: string | null;
          action: string | null;
          action_comments: string | null;
        };
        Relationships: [];
      };
    };
    Functions: {
      submit_correction_request: {
        Args: {
          p_attendance_date: string;
          p_requested_check_in?: string | null;
          p_requested_check_out?: string | null;
          p_reason?: string | null;
          p_idempotency_key?: string | null;
        };
        Returns: {
          correction_request_id: string;
          attendance_day_id: string;
          workflow_request_id: string | null;
          status: string;
        };
      };
    };
  };
  assets: {
    Tables: {
      asset_categories: {
        Row: {
          id: string;
          category_code: string;
          category_name: string;
          description: string | null;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
          version: number;
        };
        Insert: Partial<Database["assets"]["Tables"]["asset_categories"]["Row"]>;
        Update: Partial<Database["assets"]["Tables"]["asset_categories"]["Row"]>;
        Relationships: [];
      };
      assets: {
        Row: {
          id: string;
          asset_category_id: string;
          asset_code: string;
          asset_name: string;
          serial_number: string | null;
          current_status: AssetStatus;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
          version: number;
        };
        Insert: Partial<Database["assets"]["Tables"]["assets"]["Row"]>;
        Update: Partial<Database["assets"]["Tables"]["assets"]["Row"]>;
        Relationships: [
          {
            foreignKeyName: "assets_asset_category_id_fkey";
            columns: ["asset_category_id"];
            isOneToOne: false;
            referencedRelation: "asset_categories";
            referencedColumns: ["id"];
          }
        ];
      };
      asset_requests: {
        Row: {
          id: string;
          employee_id: string;
          asset_category_id: string;
          justification: string;
          request_status: AssetRequestStatus;
          workflow_request_id: string | null;
          submitted_at: string | null;
          created_at: string;
          updated_at: string;
          created_by: string;
          updated_by: string | null;
          version: number;
        };
        Insert: Partial<Database["assets"]["Tables"]["asset_requests"]["Row"]>;
        Update: Partial<Database["assets"]["Tables"]["asset_requests"]["Row"]>;
        Relationships: [
          {
            foreignKeyName: "asset_requests_asset_category_id_fkey";
            columns: ["asset_category_id"];
            isOneToOne: false;
            referencedRelation: "asset_categories";
            referencedColumns: ["id"];
          }
        ];
      };
      asset_assignments: {
        Row: {
          id: string;
          asset_request_id: string;
          asset_id: string;
          employee_id: string;
          assigned_at: string;
          assigned_by: string;
          returned_at: string | null;
          created_at: string;
          version: number;
        };
        Insert: Partial<Database["assets"]["Tables"]["asset_assignments"]["Row"]>;
        Update: Partial<Database["assets"]["Tables"]["asset_assignments"]["Row"]>;
        Relationships: [
          {
            foreignKeyName: "asset_assignments_asset_id_fkey";
            columns: ["asset_id"];
            isOneToOne: false;
            referencedRelation: "assets";
            referencedColumns: ["id"];
          }
        ];
      };
    };
    Views: {
      v_asset_request_approvals: {
        Row: {
          asset_request_id: string;
          employee_id: string;
          from_status: string | null;
          to_status: string;
          changed_at: string;
          reason: string | null;
          actor_user_id: string | null;
          action: string | null;
          action_comments: string | null;
        };
        Relationships: [];
      };
    };
    Functions: {
      submit_asset_request: {
        Args: {
          p_asset_category_id: string;
          p_justification: string;
          p_idempotency_key?: string | null;
        };
        Returns: {
          asset_request_id: string;
          workflow_request_id: string | null;
          status: string;
        };
      };
      fulfill_asset_request: {
        Args: {
          p_asset_request_id: string;
          p_asset_id: string;
        };
        Returns: {
          assignment_id: string;
          asset_id: string;
          status: string;
        };
      };
    };
  };
  hr: {
    Tables: {
      contracts: {
        Row: {
          id: string;
          employee_id: string;
          contract_number: string;
          contract_type: ContractType;
          current_version_id: string | null;
          status: ContractStatus;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
          version: number;
        };
        Insert: Partial<Database["hr"]["Tables"]["contracts"]["Row"]>;
        Update: Partial<Database["hr"]["Tables"]["contracts"]["Row"]>;
        Relationships: [
          {
            foreignKeyName: "contracts_current_version_id_fkey";
            columns: ["current_version_id"];
            isOneToOne: false;
            referencedRelation: "contract_versions";
            referencedColumns: ["id"];
          }
        ];
      };
      contract_versions: {
        Row: {
          id: string;
          contract_id: string;
          version_no: number;
          effective_from: string;
          effective_to: string | null;
          document_file_id: string | null;
          notes: string | null;
          created_at: string;
          created_by: string | null;
          version: number;
        };
        Insert: Partial<Database["hr"]["Tables"]["contract_versions"]["Row"]>;
        Update: Partial<Database["hr"]["Tables"]["contract_versions"]["Row"]>;
        Relationships: [
          {
            foreignKeyName: "contract_versions_contract_id_fkey";
            columns: ["contract_id"];
            isOneToOne: false;
            referencedRelation: "contracts";
            referencedColumns: ["id"];
          }
        ];
      };
      contract_requests: {
        Row: {
          id: string;
          contract_id: string;
          contract_version_id: string;
          workflow_request_id: string | null;
          requested_by: string;
          submitted_at: string | null;
          created_at: string;
          updated_at: string;
          created_by: string | null;
          updated_by: string | null;
          version: number;
        };
        Insert: Partial<Database["hr"]["Tables"]["contract_requests"]["Row"]>;
        Update: Partial<Database["hr"]["Tables"]["contract_requests"]["Row"]>;
        Relationships: [
          {
            foreignKeyName: "contract_requests_contract_id_fkey";
            columns: ["contract_id"];
            isOneToOne: false;
            referencedRelation: "contracts";
            referencedColumns: ["id"];
          }
        ];
      };
    };
    Views: {
      v_contract_approvals: {
        Row: {
          contract_id: string;
          contract_request_id: string;
          employee_id: string;
          from_status: string | null;
          to_status: string;
          changed_at: string;
          reason: string | null;
          actor_user_id: string | null;
          action: string | null;
          action_comments: string | null;
        };
        Relationships: [];
      };
    };
    Functions: {
      create_contract: {
        Args: {
          p_employee_id: string;
          p_contract_type: ContractType;
          p_effective_from: string;
          p_effective_to?: string | null;
          p_document_file_id?: string | null;
          p_notes?: string | null;
          p_contract_number?: string | null;
          p_idempotency_key?: string | null;
        };
        Returns: {
          contract_id: string;
          contract_version_id: string;
          contract_request_id: string;
          contract_number: string;
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
        Insert: Partial<Database["workflow"]["Tables"]["approval_requests"]["Row"]>;
        Update: Partial<Database["workflow"]["Tables"]["approval_requests"]["Row"]>;
        Relationships: [];
      };
      approval_steps: {
        Row: {
          id: string;
          approval_request_id: string;
          workflow_step_id: string;
          workflow_version_id: string;
          step_no: number;
          status: string;
        };
        Insert: Partial<Database["workflow"]["Tables"]["approval_steps"]["Row"]>;
        Update: Partial<Database["workflow"]["Tables"]["approval_steps"]["Row"]>;
        Relationships: [
          {
            foreignKeyName: "approval_steps_step_version_fk";
            columns: ["workflow_step_id", "workflow_version_id"];
            isOneToOne: false;
            referencedRelation: "workflow_steps";
            referencedColumns: ["id", "workflow_version_id"];
          }
        ];
      };
      workflow_steps: {
        Row: {
          id: string;
          workflow_version_id: string;
          step_key: string;
          step_no: number;
          step_name: string;
        };
        Insert: Partial<Database["workflow"]["Tables"]["workflow_steps"]["Row"]>;
        Update: Partial<Database["workflow"]["Tables"]["workflow_steps"]["Row"]>;
        Relationships: [];
      };
    };
    Views: {};
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
