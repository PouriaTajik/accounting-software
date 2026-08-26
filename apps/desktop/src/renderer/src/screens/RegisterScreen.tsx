import { Button, Card, CardContent, CardDescription, CardHeader, CardTitle, TextField } from "@accounting/ui";
import { useMutation } from "@tanstack/react-query";
import { useState } from "react";

import { register } from "../lib/apiClient";

export function RegisterScreen({
  onRegistered,
  onLogin,
}: {
  onRegistered: () => void;
  onLogin: () => void;
}) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState("");

  const mutation = useMutation({
    // register() logs the new user in immediately server-side (one step,
    // not signup-then-login) -- see routers/auth.py.
    mutationFn: () =>
      register({ email, password, display_name: displayName.trim() || undefined }),
    onSuccess: onRegistered,
  });

  return (
    <div className="flex h-screen items-center justify-center bg-background p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Create an account</CardTitle>
          <CardDescription>You'll be signed in right away.</CardDescription>
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
              label="Name"
              value={displayName}
              onChange={setDisplayName}
              placeholder="Jane Doe"
              autoFocus
            />
            <TextField
              label="Email"
              type="email"
              value={email}
              onChange={setEmail}
              placeholder="you@example.com"
              isRequired
            />
            <TextField label="Password" type="password" value={password} onChange={setPassword} isRequired />
            {mutation.isError ? (
              <p className="text-xs text-destructive">{(mutation.error as Error).message}</p>
            ) : null}
            <Button type="submit" isDisabled={mutation.isPending || !email.trim() || !password}>
              {mutation.isPending ? "Creating…" : "Create account"}
            </Button>
            <button
              type="button"
              onClick={onLogin}
              className="self-center text-xs text-muted-foreground underline outline-none"
            >
              Already have an account? Log in
            </button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
