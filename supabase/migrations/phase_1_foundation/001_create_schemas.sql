-- ============================================================
-- EMS DATABASE FOUNDATION
-- Phase 1 - Migration 001
-- Schema Creation & Shared Utility Functions
-- ============================================================

-- ------------------------------------------------------------
-- Required Extensions
-- ------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ------------------------------------------------------------
-- Create Schemas
-- ------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS hr;
CREATE SCHEMA IF NOT EXISTS attendance;
CREATE SCHEMA IF NOT EXISTS leave;
CREATE SCHEMA IF NOT EXISTS assets;
CREATE SCHEMA IF NOT EXISTS access;
CREATE SCHEMA IF NOT EXISTS documents;
CREATE SCHEMA IF NOT EXISTS notifications;
CREATE SCHEMA IF NOT EXISTS employee_relations;
CREATE SCHEMA IF NOT EXISTS performance;
CREATE SCHEMA IF NOT EXISTS finance_integration;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS system;

-- ------------------------------------------------------------
-- Schema Permissions
-- ------------------------------------------------------------

GRANT USAGE ON SCHEMA
core,
hr,
attendance,
leave,
assets,
access,
documents,
notifications,
employee_relations,
performance,
finance_integration,
audit,
system
TO authenticated, service_role;

GRANT CREATE ON SCHEMA
core,
hr,
attendance,
leave,
assets,
access,
documents,
notifications,
employee_relations,
performance,
finance_integration,
audit,
system
TO service_role;

-- ------------------------------------------------------------
-- Default Table Privileges
-- ------------------------------------------------------------

ALTER DEFAULT PRIVILEGES IN SCHEMA core
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA hr
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA attendance
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA leave
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA assets
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA access
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA documents
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA notifications
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA employee_relations
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA performance
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA finance_integration
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA audit
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA system
GRANT ALL ON TABLES TO authenticated, service_role;

-- ============================================================
-- Shared Utility Functions
-- ============================================================

---------------------------------------------------------------
-- Automatically update updated_at
---------------------------------------------------------------

CREATE OR REPLACE FUNCTION core.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

---------------------------------------------------------------
-- Current Supabase User
---------------------------------------------------------------

CREATE OR REPLACE FUNCTION core.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
SELECT auth.uid();
$$;

---------------------------------------------------------------
-- Placeholder Functions
-- These will be completed after Core tables are created.
---------------------------------------------------------------

CREATE OR REPLACE FUNCTION core.current_profile_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION core.current_organization_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION core.has_role(role_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION core.has_permission(permission_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN FALSE;
END;
$$;