"use client";
// src/components/sections/TopNavbar.tsx

import { useEffect, useState } from "react";
import { useTheme } from "next-themes";
import { LogOut, Moon, Sun } from "lucide-react";
import { useAuth } from "@/context/AuthContext";
import { Button } from "@/components/ui/Button";

export function TopNavbar() {
  const { user, signOut } = useAuth();
  const { theme, setTheme } = useTheme();

  // next-themes can't know the real theme on the server (it lives in
  // the client's cookie/localStorage), so `theme` is undefined during
  // SSR and only resolves after mount - rendering an icon based on it
  // before mount causes a server/client HTML mismatch. Don't render
  // the theme-dependent icon until after mount.
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  return (
    <header className="flex h-16 items-center justify-between border-b border-gray-200 bg-white px-6 dark:border-gray-800 dark:bg-gray-950">
      <div />
      <div className="flex items-center gap-4">
        <button
          onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
          className="rounded-md p-2 text-gray-500 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"
          aria-label="Toggle theme"
        >
          {mounted ? (
            theme === "dark" ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />
          ) : (
            <span className="block h-4 w-4" />
          )}
        </button>
        <span className="text-sm text-gray-600 dark:text-gray-400">{user?.email}</span>
        <Button variant="ghost" size="sm" onClick={signOut}>
          <LogOut className="h-4 w-4" />
          Sign out
        </Button>
      </div>
    </header>
  );
}