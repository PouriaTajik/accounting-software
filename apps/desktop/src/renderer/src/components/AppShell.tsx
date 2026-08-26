import { cn } from "@accounting/ui";
import { BookOpen, Landmark } from "lucide-react";
import type { ReactNode } from "react";

export type View = "accounts" | "journal";

const NAV_ITEMS: { id: View; label: string; icon: typeof Landmark }[] = [
  { id: "accounts", label: "Accounts", icon: Landmark },
  { id: "journal", label: "Journal", icon: BookOpen },
];

export function AppShell({
  workspaceName,
  activeView,
  onNavigate,
  children,
}: {
  workspaceName: string;
  activeView: View;
  onNavigate: (view: View) => void;
  children: ReactNode;
}) {
  return (
    <div className="flex h-screen bg-background text-foreground">
      <aside className="flex w-56 shrink-0 flex-col border-e border-border bg-muted/30 p-4">
        <p className="mb-6 truncate text-sm font-semibold">{workspaceName}</p>
        <nav className="flex flex-col gap-1">
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
      </aside>
      <main className="flex-1 overflow-y-auto p-6">{children}</main>
    </div>
  );
}
