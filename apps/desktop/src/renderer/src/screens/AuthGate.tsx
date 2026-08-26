import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";

import { getMe } from "../lib/apiClient";
import { CurrentUserProvider } from "../lib/CurrentUserContext";
import { ForgotPasswordScreen } from "./ForgotPasswordScreen";
import { LoginScreen } from "./LoginScreen";
import { RegisterScreen } from "./RegisterScreen";
import { ResetPasswordScreen } from "./ResetPasswordScreen";

type AuthView = "login" | "register" | "forgot-password" | "reset-password";

/**
 * Gates the whole app on a valid session, the same way ReadinessGate gates
 * it on the backend being up -- GET /auth/me is the source of truth for
 * "logged in", not anything stored client-side, since the session cookie is
 * httponly and this app can't read it directly anyway.
 */
export function AuthGate({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [view, setView] = useState<AuthView>("login");

  const meQuery = useQuery({
    queryKey: ["auth", "me"],
    queryFn: ({ signal }) => getMe(signal),
    retry: false,
  });

  if (meQuery.isPending) {
    return (
      <div className="flex h-screen items-center justify-center text-sm text-muted-foreground">
        Loading…
      </div>
    );
  }

  // isError, not just !data: React Query keeps the last-known-good `data`
  // from a prior successful fetch visible through a *failed* refetch by
  // default (so the UI doesn't flash blank on a transient error) -- but a
  // 401 on /auth/me specifically means the session that produced that data
  // is gone, so it must not keep counting as "logged in" just because the
  // stale object is still sitting in the cache. Without this check, logout
  // invalidated the query, the refetch correctly 401'd, and the app never
  // noticed: `data` from the login before it stayed truthy forever.
  if (meQuery.data && !meQuery.isError) {
    return <CurrentUserProvider me={meQuery.data}>{children}</CurrentUserProvider>;
  }

  const onAuthenticated = () => queryClient.invalidateQueries({ queryKey: ["auth", "me"] });

  switch (view) {
    case "register":
      return <RegisterScreen onRegistered={onAuthenticated} onLogin={() => setView("login")} />;
    case "forgot-password":
      return (
        <ForgotPasswordScreen
          onBack={() => setView("login")}
          onHaveToken={() => setView("reset-password")}
        />
      );
    case "reset-password":
      return <ResetPasswordScreen onReset={() => setView("login")} onBack={() => setView("login")} />;
    default:
      return (
        <LoginScreen
          onLoggedIn={onAuthenticated}
          onRegister={() => setView("register")}
          onForgotPassword={() => setView("forgot-password")}
        />
      );
  }
}
