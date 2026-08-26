import { Button, Card, CardContent, CardDescription, CardHeader, CardTitle, TextField } from "@accounting/ui";
import { useMutation } from "@tanstack/react-query";
import { useState } from "react";

import { login } from "../lib/apiClient";

export function LoginScreen({
  onLoggedIn,
  onRegister,
  onForgotPassword,
}: {
  onLoggedIn: () => void;
  onRegister: () => void;
  onForgotPassword: () => void;
}) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  const mutation = useMutation({
    mutationFn: () => login({ email, password }),
    onSuccess: onLoggedIn,
  });

  return (
    <div className="flex h-screen items-center justify-center bg-background p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Log in</CardTitle>
          <CardDescription>Sign in to your books.</CardDescription>
        </CardHeader>
        <CardContent>
          <form
            className="flex flex-col gap-4"
            onSubmit={(event) => {
              event.preventDefault();
              if (email.trim() && password) mutation.mutate();
            }}
          >
            <TextField
              label="Email"
              type="email"
              value={email}
              onChange={setEmail}
              placeholder="you@example.com"
              isRequired
              autoFocus
            />
            <TextField
              label="Password"
              type="password"
              value={password}
              onChange={setPassword}
              isRequired
            />
            {mutation.isError ? (
              <p className="text-xs text-destructive">{(mutation.error as Error).message}</p>
            ) : null}
            <Button type="submit" isDisabled={mutation.isPending || !email.trim() || !password}>
              {mutation.isPending ? "Logging in…" : "Log in"}
            </Button>
            <div className="flex items-center justify-between text-xs text-muted-foreground">
              <button type="button" onClick={onForgotPassword} className="underline outline-none">
                Forgot password?
              </button>
              <button type="button" onClick={onRegister} className="underline outline-none">
                Create an account
              </button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
