import { cn } from "@accounting/ui";
import { BookOpen, Landmark, LogOut, Users } from "lucide-react";
import type { ReactNode } from "react";

import { logout } from "../lib/apiClient";

export type View = "accounts" | "journal" | "members";

const NAV_ITEMS: { id: View; label: string; icon: typeof Landmark }[] = [
  { id: "accounts", label: "Accounts", icon: Landmark },
  { id: "journal", label: "Journal", icon: BookOpen },
  { id: "members", label: "Team", icon: Users },
];

export function AppShell({
  workspaceName,
  activeView,
  onNavigate,
  onLoggedOut,
  children,
}: {
  workspaceName: string;
  activeView: View;
  onNavigate: (view: View) => void;
  onLoggedOut: () => void;
  children: ReactNode;
}) {
  return (
    <div className="flex h-screen bg-background text-foreground">
      <aside className="flex w-56 shrink-0 flex-col border-e border-border bg-muted/30 p-4">
        <p className="mb-6 truncate text-sm font-semibold">{workspaceName}</p>
        <nav className="flex flex-1 flex-col gap-1">
          {NAV_ITEMS.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              type="button"
              onClick={() => onNavigate(id)}
              className={cn(
                "flex items-center gap-2 rounded-md px-3 py-2 text-start text-sm font-medium outline-none",
                "focus-visible:ring-2 focus-visible:ring-ring",
                activeView === id
                  ? "bg-primary/10 text-primary"
                  : "text-muted-foreground hover:bg-muted hover:text-foreground",
              )}
            >
              <Icon className="h-4 w-4 shrink-0" />
              {label}
            </button>
          ))}
        </nav>
        <button
          type="button"
          onClick={() => {
            // Best-effort: even if the network call fails, the user still
            // wants to leave, so onLoggedOut runs either way.
            logout()
              .catch(() => {})
              .finally(onLoggedOut);
          }}
          className={cn(
            "flex items-center gap-2 rounded-md px-3 py-2 text-start text-sm font-medium outline-none",
            "text-muted-foreground hover:bg-muted hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring",
          )}
        >
          <LogOut className="h-4 w-4 shrink-0" />
          Log out
        </button>
      </aside>
      <main className="flex-1 overflow-y-auto p-6">{children}</main>
    </div>
  );
}
