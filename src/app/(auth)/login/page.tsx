"use client";
// src/app/(auth)/login/page.tsx
//
// useSearchParams() requires a Suspense boundary for Next.js to
// statically prerender this page - split into an inner component (the
// actual page content) and a Suspense-wrapped default export. Pre-existing
// gap, unrelated to the database.types.ts/supabase client fix - this
// simply never surfaced before because the build never got past the
// TypeScript phase until now.

import { Suspense, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Link from "next/link";
import toast from "react-hot-toast";
import { supabase } from "@/lib/supabase";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";

function LoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);

    const { error } = await supabase.auth.signInWithPassword({ email, password });

    setLoading(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    const redirectTo = searchParams.get("redirectedFrom") || "/dashboard";
    router.push(redirectTo);
    router.refresh();
  };

  return (
    <form onSubmit={handleSubmit} className="w-full max-w-md rounded-xl bg-white p-8 shadow">
      <h1 className="text-2xl font-bold text-gray-900">Login</h1>
      <p className="mt-2 text-gray-600">Employee Management System</p>

      <div className="mt-6 flex flex-col gap-4">
        <Input
          type="email"
          label="Email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
        />
        <Input
          type="password"
          label="Password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
        />
        <Button type="submit" loading={loading}>
          Sign in
        </Button>
        <p className="text-center text-sm text-gray-500">
          Don&apos;t have an account?{" "}
          <Link href="/signup" className="font-medium text-blue-600 hover:underline">
            Sign up
          </Link>
        </p>
      </div>
    </form>
  );
}

export default function LoginPage() {
  return (
    <Suspense fallback={null}>
      <LoginForm />
    </Suspense>
  );
}
