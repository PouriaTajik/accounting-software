import { useCallback, useState } from "react";

const STORAGE_KEY = "accounting.activeWorkspaceId";

/**
 * No auth and no multi-workspace UX yet (both post-MVP per
 * PRODUCT_ROADMAP.md) -- this is one desktop install remembering the one
 * workspace it was pointed at, nothing more.
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
