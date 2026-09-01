"use client";
// src/components/ErrorBoundary.tsx

import { Component, type ErrorInfo, type ReactNode } from "react";
import { AlertTriangle } from "lucide-react";

interface Props {
  children: ReactNode;
  fallback?: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false, error: null };

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("ErrorBoundary caught:", error, info);
  }

  render() {
    if (this.state.hasError) {
      return (
        this.props.fallback ?? (
          <div className="flex flex-col items-center justify-center gap-3 rounded-lg border border-red-200 bg-red-50 p-8 text-center dark:border-red-900 dark:bg-red-950">
            <AlertTriangle className="h-8 w-8 text-red-500" />
            <p className="font-medium text-red-700 dark:text-red-300">Something went wrong.</p>
            <p className="text-sm text-red-600 dark:text-red-400">{this.state.error?.message}</p>
          </div>
        )
      );
    }

    return this.props.children;
  }
}
