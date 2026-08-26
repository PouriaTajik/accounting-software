import { useQuery } from "@tanstack/react-query";
import { useState } from "react";

import { AppShell, type View } from "./components/AppShell";
import { getWorkspace } from "./lib/apiClient";
import { useWorkspaceId } from "./lib/useWorkspace";
import { AccountsScreen } from "./screens/AccountsScreen";
import { JournalScreen } from "./screens/JournalScreen";
import { ReadinessGate } from "./screens/ReadinessGate";
import { WorkspaceOnboarding } from "./screens/WorkspaceOnboarding";

export function App() {
  return (
    <ReadinessGate>
      <WorkspaceRoot />
    </ReadinessGate>
  );
}

function WorkspaceRoot() {
  const { workspaceId, setWorkspaceId } = useWorkspaceId();

  if (!workspaceId) {
    return <WorkspaceOnboarding onCreated={setWorkspaceId} />;
  }

  return <WorkspaceApp workspaceId={workspaceId} onMissing={() => setWorkspaceId(null)} />;
}

function WorkspaceApp({ workspaceId, onMissing }: { workspaceId: string; onMissing: () => void }) {
  const [view, setView] = useState<View>("accounts");
  const workspaceQuery = useQuery({
    queryKey: ["workspace", workspaceId],
    queryFn: () => getWorkspace(workspaceId),
    retry: false,
  });

  if (workspaceQuery.isError) {
    // Stale id from a previous, now-purged workspace -- fall back to onboarding
    // rather than showing a dead screen the user can't recover from.
    onMissing();
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
    <AppShell workspaceName={workspaceQuery.data.name} activeView={view} onNavigate={setView}>
      {view === "accounts" ? (
        <AccountsScreen workspaceId={workspaceId} />
      ) : (
        <JournalScreen workspaceId={workspaceId} />
      )}
    </AppShell>
  );
}
