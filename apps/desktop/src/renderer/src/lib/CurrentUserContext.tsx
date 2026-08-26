import { createContext, useContext, type ReactNode } from "react";

import type { Me, Role } from "./types";

/**
 * The logged-in user + their workspace memberships, resolved once by
 * AuthGate and made available to every screen below it -- so a screen that
 * wants to know "is the current viewer an owner of this workspace" (e.g.
 * MembersScreen, to hide controls that would 403) doesn't need its own
 * GET /auth/me round trip.
 */
const CurrentUserContext = createContext<Me | null>(null);

export function CurrentUserProvider({ me, children }: { me: Me; children: ReactNode }) {
  return <CurrentUserContext.Provider value={me}>{children}</CurrentUserContext.Provider>;
}

export function useCurrentUser(): Me {
  const me = useContext(CurrentUserContext);
  if (!me) {
    throw new Error("useCurrentUser() called outside a CurrentUserProvider (below AuthGate)");
  }
  return me;
}

/** This viewer's role in one specific workspace, or null if they aren't a
 * member of it (shouldn't normally happen for a workspace already shown in
 * the UI, but the server -- not this -- is what actually enforces access). */
export function useRoleIn(workspaceId: string): Role | null {
  const { memberships } = useCurrentUser();
  return memberships.find((m) => m.workspace_id === workspaceId)?.role ?? null;
}
