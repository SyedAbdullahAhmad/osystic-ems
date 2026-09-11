// src/lib/supabase.ts
//
// Multi-schema client pattern, matching Finance's convention: one typed
// client per schema this app talks to. Uses createBrowserClient from
// @supabase/ssr (cookie-based session, consistent with
// supabase-server.ts) rather than plain createClient from
// @supabase/supabase-js - the earlier version of this file used plain
// createClient, which doesn't sync session state with server
// components/middleware in the App Router.
//
// Fixed: leaveDB previously pointed at schema "leave_management", which
// doesn't exist - 001_create_schemas.sql creates a schema named "leave".

import { createBrowserClient } from "@supabase/ssr";
import type { Database } from "@/types/database.types";

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

/** Default client - public schema. */
export const supabase = createBrowserClient(SUPABASE_URL, SUPABASE_ANON_KEY);

/**
 * core schema client - RBAC reads (core.get_user_permissions(),
 * core.has_permission(), etc.). Requires "core" to also be added under
 * Project Settings -> API -> Exposed schemas, same as workflow/leave -
 * the default client (public schema) can never reach core.* functions
 * regardless of grants, since PostgREST routes by schema, not by what
 * the function happens to be able to see.
 *
 * isSingleton: false is REQUIRED here. createBrowserClient caches and
 * reuses the FIRST client instance created for every subsequent call
 * by default (a documented behavior, not a bug on our end -
 * https://github.com/supabase/ssr/issues/29) - without this flag,
 * coreDB/workflowDB/leaveDB would all silently collapse into the same
 * instance as the default `supabase` client above, permanently ignoring
 * their own schema option and always querying "public" no matter what
 * the code says. This is exactly what was happening: every fix to the
 * calling code was correct, but the client itself was never actually
 * using it.
 */
export const coreDB = createBrowserClient<Database, "core">(SUPABASE_URL, SUPABASE_ANON_KEY, {
  db: { schema: "core" },
  isSingleton: false,
});

/**
 * workflow schema client. Requires "workflow" to be added under
 * Project Settings -> API -> Exposed schemas in Supabase, then
 * NOTIFY pgrst, 'reload schema'; in the SQL Editor - PostgREST 404s on
 * anything in a non-exposed schema regardless of grants.
 *
 * isSingleton: false required - see coreDB's comment above.
 */
export const workflowDB = createBrowserClient<Database, "workflow">(SUPABASE_URL, SUPABASE_ANON_KEY, {
  db: { schema: "workflow" },
  isSingleton: false,
});

/**
 * leave schema client - this module's own tables/RPCs.
 * isSingleton: false required - see coreDB's comment above.
 */
export const leaveDB = createBrowserClient<Database, "leave">(SUPABASE_URL, SUPABASE_ANON_KEY, {
  db: { schema: "leave" },
  isSingleton: false,
});

/**
 * attendance schema client - the Attendance Corrections module's own
 * tables/RPCs. Same requirement as workflow/leave/core: "attendance"
 * must be added under Project Settings -> API -> Exposed schemas in
 * Supabase, then NOTIFY pgrst, 'reload schema'; in the SQL Editor -
 * PostgREST 404s on anything in a non-exposed schema regardless of
 * grants (the exact bug #2/#3 class already hit twice for
 * workflow/core - don't skip this step for a third schema).
 *
 * isSingleton: false required - see coreDB's comment above.
 */
export const attendanceDB = createBrowserClient<Database, "attendance">(SUPABASE_URL, SUPABASE_ANON_KEY, {
  db: { schema: "attendance" },
  isSingleton: false,
});

/**
 * assets schema client - the Assets module's own tables/RPCs. Same
 * requirement as workflow/leave/core/attendance: "assets" must be added
 * under Project Settings -> API -> Exposed schemas in Supabase, then
 * NOTIFY pgrst, 'reload schema'; in the SQL Editor - PostgREST 404s on
 * anything in a non-exposed schema regardless of grants (the exact
 * bug #2/#3 class already hit for workflow/core, then attendance -
 * don't skip this step for a fifth schema).
 *
 * isSingleton: false required - see coreDB's comment above.
 */
export const assetsDB = createBrowserClient<Database, "assets">(SUPABASE_URL, SUPABASE_ANON_KEY, {
  db: { schema: "assets" },
  isSingleton: false,
});

// NOTE: you may see a "Multiple GoTrueClient instances detected"
// warning in the browser console after this change. This is expected
// and harmless in this architecture - only the default `supabase`
// client above is actually used for session/auth state (via
// AuthContext.tsx); coreDB/workflowDB/leaveDB/attendanceDB/assetsDB
// exist purely to target a different schema for data queries, not to
// independently manage auth.