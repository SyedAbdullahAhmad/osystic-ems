// src/lib/supabase-server.ts
//
// Server-side counterpart to src/lib/supabase.ts - used in route
// handlers and server components, where the session comes from cookies.
// Extended with schema-specific factories (createWorkflowDB,
// createLeaveDB) alongside the original createClient(), using the same
// getAll/setAll cookie API already established here (the current
// @supabase/ssr pattern - not the older get/set/remove trio).

import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import type { Database } from "@/types/database.types";

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

// One function per schema, each with its OWN explicit
// createServerClient<Database, "schema_name"> generic - a shared
// buildClient(schema?: string) helper (the earlier version of this file)
// can't do this correctly: TypeScript can't infer SchemaName from a
// runtime string parameter, only from a literal type known at compile
// time. That version silently type-erased schema to `never` via
// `schema as never`, which is exactly the same root cause that broke
// `next build` in lib/supabase.ts - see that file's comment header and
// database.types.ts's header for the full explanation.
async function cookieAdapter() {
  const cookieStore = await cookies();
  return {
    getAll() {
      return cookieStore.getAll();
    },
    setAll(cookiesToSet: { name: string; value: string; options?: Record<string, unknown> }[]) {
      try {
        cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
      } catch {
        // Ignore in Server Components
      }
    },
  };
}

export async function createClient() {
  return createServerClient<Database>(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: await cookieAdapter(),
  });
}

export async function createWorkflowDB() {
  return createServerClient<Database, "workflow">(SUPABASE_URL, SUPABASE_ANON_KEY, {
    db: { schema: "workflow" },
    cookies: await cookieAdapter(),
  });
}

export async function createLeaveDB() {
  return createServerClient<Database, "leave">(SUPABASE_URL, SUPABASE_ANON_KEY, {
    db: { schema: "leave" },
    cookies: await cookieAdapter(),
  });
}

export async function createAttendanceDB() {
  return createServerClient<Database, "attendance">(SUPABASE_URL, SUPABASE_ANON_KEY, {
    db: { schema: "attendance" },
    cookies: await cookieAdapter(),
  });
}
