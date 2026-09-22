-- ========================================================================
-- 001_shared_core_schema.sql
-- Phase 7: Shared-Core People/Organization Model - core tables
--
-- Design frozen per SHARED_CORE_PEOPLE_ORG_PROPOSAL_v2.md and Umar's
-- sign-off (Shared-Core_Final_Review_and_Sign-off_Report.pdf, 2026-09-14).
-- This file only creates new tables in the already-existing "core"
-- schema (created in phase_1_foundation/001_create_schemas.sql, which
-- already granted this schema's default table privileges to
-- authenticated/service_role - no additional GRANT needed for that).
--
-- ADDITIVE ONLY: nothing existing is touched, altered, or dropped by
-- this file. Four brand-new tables, one seed row.
--
-- Column rules below are taken directly from proposal v2 S2 (the exact
-- table of required/nullable/uniqueness rules Umar asked for) - not
-- re-derived or guessed.
-- ========================================================================

CREATE SCHEMA IF NOT EXISTS "core";

CREATE TYPE "core"."person_type" AS ENUM ('EMPLOYEE', 'CANDIDATE', 'CONTRACTOR', 'OTHER');
CREATE TYPE "core"."person_status" AS ENUM ('ACTIVE', 'ARCHIVED');
CREATE TYPE "core"."person_link_status" AS ENUM ('ACTIVE', 'REVOKED');

-- ------------------------------------------------------------------------
-- core.organizations - seeded with exactly one OSYSTIC row below. The
-- provisioning RPC (003) resolves this row explicitly by code rather
-- than any hardcoded UUID default, per proposal v2 S2's reasoning.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "core"."organizations" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "name" varchar(255) NOT NULL,
    "code" varchar(50) UNIQUE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

-- ------------------------------------------------------------------------
-- core.people - represents a person independently of whether they have
-- a Supabase login (candidates, contractors, archived workers do NOT
-- require one). Deliberately identity-only - sensitive fields (national
-- ID, date of birth, etc.) stay in hr.employee_sensitive_profiles (DBML
-- table, out of scope for this migration, untouched by it).
--
-- created_by/updated_by are the ACTOR (an authenticated staff member,
-- or the migration actor during backfill), NEVER the person the record
-- is about - do not conflate the two anywhere this table is used.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "core"."people" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "organization_id" uuid NOT NULL REFERENCES "core"."organizations"("id"),
    "full_name" varchar(255) NOT NULL,
    "primary_email" varchar(255),
    "primary_phone" varchar(30),
    "person_type" "core"."person_type" NOT NULL DEFAULT 'EMPLOYEE',
    "status" "core"."person_status" NOT NULL DEFAULT 'ACTIVE',
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

-- primary_email is the reconciliation key the provisioning RPC (003)
-- depends on - unique only when present, per proposal v2 S2.
CREATE UNIQUE INDEX IF NOT EXISTS "idx_people_primary_email_unique"
    ON "core"."people"("primary_email")
    WHERE "primary_email" IS NOT NULL;

-- ------------------------------------------------------------------------
-- core.person_user_links - the actual identity-linking mechanism.
-- Optional mapping: a person has zero or one ACTIVE link to a login at
-- a time. THE MOST SENSITIVE TABLE IN THIS PROPOSAL per Umar's review -
-- see 002 for why INSERT/UPDATE is never a direct client-side write.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "core"."person_user_links" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "person_id" uuid NOT NULL REFERENCES "core"."people"("id"),
    "user_id" uuid NOT NULL REFERENCES "auth"."users"("id"),
    "linked_at" timestamptz NOT NULL DEFAULT now(),
    "status" "core"."person_link_status" NOT NULL DEFAULT 'ACTIVE',
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1
);

-- At most one ACTIVE link per person, and at most one ACTIVE link per
-- login - both partial unique indexes required per proposal v2 S2 (DBML
-- cannot express this, so it's enforced here in the actual migration).
CREATE UNIQUE INDEX IF NOT EXISTS "idx_person_user_links_one_active_per_person"
    ON "core"."person_user_links"("person_id")
    WHERE "status" = 'ACTIVE';
CREATE UNIQUE INDEX IF NOT EXISTS "idx_person_user_links_one_active_per_user"
    ON "core"."person_user_links"("user_id")
    WHERE "status" = 'ACTIVE';

-- ------------------------------------------------------------------------
-- core.departments - EMS has authoritative write ownership; Finance
-- consumes department UUID references read-only (per proposal v2).
-- Deliberately flat (no parent/child hierarchy) - a slice, not the
-- whole draft, same approach used for every EMS module so far.
-- ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "core"."departments" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
    "organization_id" uuid NOT NULL REFERENCES "core"."organizations"("id"),
    "name" varchar(255) NOT NULL,
    "code" varchar(50),
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "created_by" uuid REFERENCES "auth"."users"("id"),
    "updated_by" uuid REFERENCES "auth"."users"("id"),
    "version" int NOT NULL DEFAULT 1,
    UNIQUE ("organization_id", "code")
);

CREATE INDEX IF NOT EXISTS "idx_people_organization" ON "core"."people"("organization_id");
CREATE INDEX IF NOT EXISTS "idx_person_user_links_person" ON "core"."person_user_links"("person_id");
CREATE INDEX IF NOT EXISTS "idx_person_user_links_user" ON "core"."person_user_links"("user_id");
CREATE INDEX IF NOT EXISTS "idx_departments_organization" ON "core"."departments"("organization_id");

-- ------------------------------------------------------------------------
-- Seed: exactly one OSYSTIC organization row. No created_by (no
-- authenticated session exists at true migration-time for this one
-- bootstrap row; every subsequent core.organizations write goes through
-- the actor-integrity trigger in 002).
-- ------------------------------------------------------------------------
INSERT INTO "core"."organizations" ("name", "code")
SELECT 'OSYSTIC', 'OSYSTIC'
WHERE NOT EXISTS (
    SELECT 1 FROM "core"."organizations" WHERE "code" = 'OSYSTIC'
);

-- ========================================================================
-- END 001_shared_core_schema.sql
-- ========================================================================
