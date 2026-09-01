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

async function buildClient(schema?: string) {
  const cookieStore = await cookies();

  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      db: schema ? { schema: schema as never } : undefined,
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options)
            );
          } catch {
            // Ignore in Server Components
          }
        },
      },
    }
  );
}

export const createClient = () => buildClient();
export const createWorkflowDB = () => buildClient("workflow");
export const createLeaveDB = () => buildClient("leave");
