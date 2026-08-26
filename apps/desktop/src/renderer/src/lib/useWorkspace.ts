import { useCallback, useState } from "react";

const STORAGE_KEY = "accounting.activeWorkspaceId";

/**
 * No multi-workspace UX yet (post-MVP per PRODUCT_ROADMAP.md) -- this is one
 * desktop install remembering the one workspace it was last pointed at,
 * nothing more. Auth exists (AuthGate, CurrentUserContext); this is just
 * which of the logged-in user's workspaces to show, independent of who's
 * logged in -- App.tsx clears it on logout so the next login doesn't
 * inherit a workspace that user isn't a member of.
 */
export function useWorkspaceId() {
  const [workspaceId, setWorkspaceIdState] = useState<string | null>(() =>
    window.localStorage.getItem(STORAGE_KEY),
  );

  const setWorkspaceId = useCallback((id: string | null) => {
    if (id) window.localStorage.setItem(STORAGE_KEY, id);
    else window.localStorage.removeItem(STORAGE_KEY);
    setWorkspaceIdState(id);
  }, []);

  return { workspaceId, setWorkspaceId };
}
