export interface BaseEntity {
  id: string;
  organization_id: string;
  created_at: string;
  updated_at: string;
}

export interface UserProfile {
  id: string;
  user_id: string;
  organization_id: string;
  role: string;
  full_name: string;
  email: string;
  created_at: string;
  updated_at: string;
}
export * from "./leave.types";
export * from "./workflow.types";
export * from "./database.types";
