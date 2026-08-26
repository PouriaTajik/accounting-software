import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";

import { AppShell, type View } from "./components/AppShell";
import { ApiError, getWorkspace } from "./lib/apiClient";
import { useCurrentUser } from "./lib/CurrentUserContext";
import { useWorkspaceId } from "./lib/useWorkspace";
import { AccountsScreen } from "./screens/AccountsScreen";
import { AuthGate } from "./screens/AuthGate";
import { JournalScreen } from "./screens/JournalScreen";
import { MembersScreen } from "./screens/MembersScreen";
import { ReadinessGate } from "./screens/ReadinessGate";
import { WorkspaceOnboarding } from "./screens/WorkspaceOnboarding";

export function App() {
  return (
    <ReadinessGate>
      <AuthGate>
        <WorkspaceRoot />
      </AuthGate>
    </ReadinessGate>
  );
}

function WorkspaceRoot() {
  const queryClient = useQueryClient();
  const { workspaceId, setWorkspaceId } = useWorkspaceId();
  const { memberships } = useCurrentUser();

  // Computed at render time, not synced back via a reactive useEffect.
  // An effect that writes workspaceId whenever it disagrees with
  // memberships can ping-pong indefinitely against WorkspaceApp resetting
  // workspaceId on a query error: memberships is a snapshot from the last
  // successful /auth/me, so for one render after any access loss (a 401,
  // a removed membership) it still names the very workspace that just
  // failed, and a *reactive* re-select would immediately retry it -- with
  // a cached error, React Query reports isError synchronously on remount
  // with no network wait, so that retry loop can spin thousands of times a
  // second rather than settling. Computing the fallback at render time,
  // with no write-back, means a stale membership can influence what's
  // *shown* for a render but never *drives another mount* on its own.
  const effectiveWorkspaceId =
    workspaceId && memberships.some((m) => m.workspace_id === workspaceId)
      ? workspaceId
      : (memberships[0]?.workspace_id ?? null);

  if (!effectiveWorkspaceId) {
    return (
      <WorkspaceOnboarding
        onCreated={(id) => {
          // create_workspace seats the creator as owner server-side
          // (core/workspaces.py) in the same transaction, but the `me`
          // this component's memberships came from was fetched before
          // that workspace -- and its membership -- existed.
          queryClient.invalidateQueries({ queryKey: ["auth", "me"] });
          setWorkspaceId(id);
        }}
      />
    );
  }

  return (
    <WorkspaceApp workspaceId={effectiveWorkspaceId} onMissing={() => setWorkspaceId(null)} />
  );
}

function WorkspaceApp({ workspaceId, onMissing }: { workspaceId: string; onMissing: () => void }) {
  const queryClient = useQueryClient();
  const [view, setView] = useState<View>("accounts");
  const workspaceQuery = useQuery({
    queryKey: ["workspace", workspaceId],
    queryFn: () => getWorkspace(workspaceId),
    retry: false,
  });

  // Handles a workspace the current session can no longer reach. Either way,
  // CurrentUserContext's `memberships` -- a snapshot from the last
  // successful /auth/me -- has to be refreshed before falling back, or
  // WorkspaceRoot's render-time fallback (above) just re-selects the same
  // now-unreachable workspace from that same stale snapshot, and with a
  // cached error React Query reports isError synchronously on the next
  // mount with no network wait -- which is exactly what produced tens of
  // thousands of requests in seconds the first time this shipped without
  // the refresh below.
  //
  // A 401 specifically means the session itself is gone, not just this
  // workspace, so every cached query is suspect -- queryClient.clear()
  // rather than only refreshing membership. Anything else (403
  // not_a_member, 404) is specific to this workspace: refresh membership
  // truth and let onMissing()'s fallback pick from what's actually current.
  //
  // handledError is belt-and-suspenders against acting twice on what React
  // Query reports as the "same" error across remounts -- the primary fix is
  // the refresh itself, not this guard.
  const handledError = useRef<unknown>(undefined);
  useEffect(() => {
    if (!workspaceQuery.isError || workspaceQuery.error === handledError.current) return;
    handledError.current = workspaceQuery.error;

    const error = workspaceQuery.error;
    if (error instanceof ApiError && error.status === 401) {
      queryClient.clear();
    } else {
      queryClient.invalidateQueries({ queryKey: ["auth", "me"] });
      onMissing();
    }
  }, [workspaceQuery.isError, workspaceQuery.error, onMissing, queryClient]);

  if (workspaceQuery.isError) {
    return null;
  }

  if (!workspaceQuery.data) {
    return (
      <div className="flex h-screen items-center justify-center text-sm text-muted-foreground">
        Loading…
      </div>
    );
  }

  return (
    <AppShell
      workspaceName={workspaceQuery.data.name}
      activeView={view}
      onNavigate={setView}
      onLoggedOut={() => {
        // invalidateQueries, not clear(): this workspace's own query keeps
        // showing its last-good cached data (no error, nothing to handle)
        // for the brief moment until /auth/me's background refetch
        // resolves and AuthGate unmounts this whole subtree cleanly.
        // clear() was tried first and forced workspaceQuery to refetch
        // too, landing it in the 401 branch below on a component that was
        // about to unmount anyway -- harmless in isolation, but it was the
        // trigger for the request storm this file's other comments
        // describe; the actual fix was making that branch safe, but there
        // is also just no reason to invite it here.
        queryClient.invalidateQueries({ queryKey: ["auth", "me"] });
      }}
    >
      {view === "accounts" ? (
        <AccountsScreen workspaceId={workspaceId} />
      ) : view === "journal" ? (
        <JournalScreen workspaceId={workspaceId} />
      ) : (
        <MembersScreen workspaceId={workspaceId} />
      )}
    </AppShell>
  );
}
