import { Button, Card, CardContent, CardDescription, CardHeader, CardTitle, TextField } from "@accounting/ui";
import { useMutation } from "@tanstack/react-query";
import { useState } from "react";

import { confirmPasswordReset } from "../lib/apiClient";

/**
 * Takes a pasted token rather than following a clickable link -- there is no
 * web dashboard to receive one yet (only apps/desktop and apps/server exist,
 * per ARCHITECTURE.md), and building an Electron deep-link protocol handler
 * for this is separate, unrelated work. The email/log line still includes a
 * full link for a future dashboard; this screen is the part that works
 * today without it.
 */
export function ResetPasswordScreen({ onReset, onBack }: { onReset: () => void; onBack: () => void }) {
  const [token, setToken] = useState("");
  const [newPassword, setNewPassword] = useState("");

  const mutation = useMutation({
    mutationFn: () => confirmPasswordReset(token, newPassword),
    onSuccess: onReset,
  });

  return (
    <div className="flex h-screen items-center justify-center bg-background p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Set a new password</CardTitle>
          <CardDescription>Paste the reset token you were sent.</CardDescription>
        </CardHeader>
        <CardContent>
          <form
            className="flex flex-col gap-4"
            onSubmit={(event) => {
              event.preventDefault();
              if (token.trim() && newPassword) mutation.mutate();
            }}
          >
            <TextField
              label="Reset token"
              value={token}
              onChange={setToken}
              placeholder="paste the token from your email"
              isRequired
              autoFocus
            />
            <TextField
              label="New password"
              type="password"
              value={newPassword}
              onChange={setNewPassword}
              isRequired
            />
            {mutation.isError ? (
              <p className="text-xs text-destructive">{(mutation.error as Error).message}</p>
            ) : null}
            <Button type="submit" isDisabled={mutation.isPending || !token.trim() || !newPassword}>
              {mutation.isPending ? "Resetting…" : "Reset password"}
            </Button>
            <button
              type="button"
              onClick={onBack}
              className="self-center text-xs text-muted-foreground underline outline-none"
            >
              Back to log in
            </button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
