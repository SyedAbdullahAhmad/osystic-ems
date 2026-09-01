// src/app/api/leave/requests/route.ts
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
  const { data, error } = await leaveDB
    .from("leave_requests")
    .select("*, leave_types(leave_name)")
    .order("created_at", { ascending: false });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({ data });
}

export async function POST(request: Request) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return NextResponse.json({ error: "Unauthenticated" }, { status: 401 });
  }

  const body = await request.json();
  const { leaveTypeId, startDate, endDate, totalDays, reason } = body;

  if (!leaveTypeId || !startDate || !endDate || !totalDays) {
    return NextResponse.json({ error: "Missing required fields" }, { status: 400 });
  }

  const leaveDB = await createLeaveDB();
  const { data, error } = await leaveDB.rpc("submit_leave_request", {
    p_leave_type_id: leaveTypeId,
    p_start_date: startDate,
    p_end_date: endDate,
    p_total_days: totalDays,
    p_reason: reason ?? null,
  });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({ data }, { status: 201 });
}
