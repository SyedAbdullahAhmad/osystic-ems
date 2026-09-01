// src/app/api/leave/types/route.ts
import { NextResponse } from "next/server";
import { createClient, createLeaveDB } from "@/lib/supabase-server";

export async function GET() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return NextResponse.json({ error: "Unauthenticated" }, { status: 401 });
  }

  const leaveDB = await createLeaveDB();
  const { data, error } = await leaveDB.from("leave_types").select("*").eq("status", "ACTIVE").order("leave_name");

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({ data });
}
