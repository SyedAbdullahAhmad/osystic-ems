-- ===========================================================
-- PHASE 1 - STEP 4
-- Core RBAC tables
--
-- Column-for-column, constraint-for-constraint match to Finance's real,
-- live schema (verified against their actual schema.sql dump, not a
-- guess or a disposable stand-in) - this is the same RBAC model the
-- team lead instructed EMS to reuse exactly: "reuse the Finance RBAC
-- tables exactly as they currently exist: core.roles, core.permissions,
-- core.role_permissions, core.user_roles."
--
-- Supersedes core.has_permission(permission_code text) / has_role() /
-- current_organization_id() / current_profile_id() placeholders in
-- 001_create_schemas.sql, which were explicitly marked "will be
-- completed after Core tables are created" - the REAL has_permission()
-- (2-arg: user_id, permission_code) is defined in 005_rls_policies.sql,
-- verified against Finance's actual Phase 3 permission-functions code.
-- The old 1-arg placeholder is left in place (harmless - Postgres
-- resolves by argument count) but nothing in this codebase calls it;
-- consider removing it once nothing references it.
-- ===========================================================

CREATE TABLE IF NOT EXISTS "core"."roles" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "name" text NOT NULL,
    "display_name" text NOT NULL,
    "description" text,
    "is_system" boolean DEFAULT false,
    "level" integer DEFAULT 0,
    "created_at" timestamptz DEFAULT now(),
    "updated_at" timestamptz DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id") ON DELETE SET NULL,
    CONSTRAINT "roles_name_key" UNIQUE ("name")
);

CREATE TABLE IF NOT EXISTS "core"."permissions" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "code" text NOT NULL,
    "name" text NOT NULL,
    "module" text NOT NULL,
    "action" text NOT NULL,
    "description" text,
    "is_system" boolean DEFAULT false,
    "created_at" timestamptz DEFAULT now(),
    "updated_at" timestamptz DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id") ON DELETE SET NULL,
    CONSTRAINT "permissions_code_key" UNIQUE ("code")
);

CREATE TABLE IF NOT EXISTS "core"."role_permissions" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "role_id" uuid NOT NULL REFERENCES "core"."roles"("id") ON DELETE CASCADE,
    "permission_id" uuid NOT NULL REFERENCES "core"."permissions"("id") ON DELETE CASCADE,
    "data_scope" text NOT NULL DEFAULT 'ALL',
    "amount_limit" numeric(18,2),
    "effective_from" date NOT NULL DEFAULT CURRENT_DATE,
    "effective_to" date,
    "created_at" timestamptz DEFAULT now(),
    "updated_at" timestamptz DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id") ON DELETE SET NULL,
    CONSTRAINT "role_permissions_data_scope_check" CHECK ("data_scope" = ANY (ARRAY['OWN', 'DEPARTMENT', 'PROJECT', 'ALL']))
);

CREATE TABLE IF NOT EXISTS "core"."user_roles" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "user_id" uuid NOT NULL REFERENCES "auth"."users"("id") ON DELETE CASCADE,
    "role_id" uuid NOT NULL REFERENCES "core"."roles"("id") ON DELETE CASCADE,
    "effective_from" date NOT NULL DEFAULT CURRENT_DATE,
    "effective_to" date,
    "delegated_from" uuid REFERENCES "auth"."users"("id") ON DELETE SET NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamptz DEFAULT now(),
    "updated_at" timestamptz DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id") ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS "idx_user_roles_user_id" ON "core"."user_roles"("user_id");
CREATE INDEX IF NOT EXISTS "idx_role_permissions_role_id" ON "core"."role_permissions"("role_id");
