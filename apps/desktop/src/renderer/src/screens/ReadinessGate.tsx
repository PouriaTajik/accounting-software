import { useQuery } from "@tanstack/react-query";
import type { ReactNode } from "react";

import { getHealthReady } from "../lib/apiClient";

/**
 * The API subprocess and its Postgres start independently (apps/desktop's
 * README) -- an open port is not the same as a usable database. Polls
 * GET /api/v1/health/ready and gates the whole app on it, rather than
 * letting every screen discover a cold backend on its own first request.
 */
export function ReadinessGate({ children }: { children: ReactNode }) {
  const { data, isPending, isError } = useQuery({
    queryKey: ["health", "ready"],
    queryFn: ({ signal }) => getHealthReady(signal),
    refetchInterval: (query) => (query.state.data?.status === "ok" ? false : 1500),
    retry: false,
  });

  if (data?.status === "ok") return <>{children}</>;

  return (
    <div className="flex h-screen flex-col items-center justify-center gap-3 bg-background text-foreground">
      <div className="h-8 w-8 animate-spin rounded-full border-2 border-muted border-t-primary" />
      <p className="text-sm text-muted-foreground">
        {isError || data?.status === "degraded"
          ? "Waiting for the database…"
          : isPending
            ? "Starting up…"
            : "Waiting for the backend…"}
      </p>
    </div>
  );
}
