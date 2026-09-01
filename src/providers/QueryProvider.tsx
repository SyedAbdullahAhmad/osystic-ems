'use client';

import { useState } from 'react';
import { QueryClient, QueryClientProvider, QueryCache } from '@tanstack/react-query';
import toast from 'react-hot-toast';

export default function QueryProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        // Global error toast, in ONE place, for every query in the app -
        // not per-hook. QueryCache's onError runs when a query actually
        // settles, outside React's render cycle, so it's safe to call
        // toast() here. Calling toast() from a per-query throwOnError
        // callback (an earlier version of this) is NOT safe - React
        // Query can invoke that synchronously during render, which is
        // exactly what caused the "Cannot update a component while
        // rendering a different component" error.
        queryCache: new QueryCache({
          onError: (error) => {
            toast.error(error instanceof Error ? error.message : 'Something went wrong');
          },
        }),
        defaultOptions: {
          queries: {
            staleTime: 60 * 1000,
            refetchOnWindowFocus: false,
          },
        },
      })
  );

  return (
    <QueryClientProvider client={queryClient}>
      {children}
    </QueryClientProvider>
  );
}