import { Button, Card, CardContent, CardDescription, CardHeader, CardTitle, TextField } from "@accounting/ui";
import { useMutation } from "@tanstack/react-query";
import { useState } from "react";

import { requestPasswordReset } from "../lib/apiClient";

export function ForgotPasswordScreen({
  onBack,
  onHaveToken,
}: {
  onBack: () => void;
  onHaveToken: () => void;
}) {
  const [email, setEmail] = useState("");

  const mutation = useMutation({
    mutationFn: () => requestPasswordReset(email),
  });

  return (
    <div className="flex h-screen items-center justify-center bg-background p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Reset your password</CardTitle>
          <CardDescription>We'll send a reset link to your email.</CardDescription>
        </CardHeader>
        <CardContent>
          {mutation.isSuccess ? (
            <div className="flex flex-col gap-4">
              {/* Always the same message whether or not the email matched an
               * account -- the API deliberately never reveals which
               * (routers/auth.py), so the UI can't either. */}
              <p className="text-sm text-foreground">
                If that email is registered, a reset link has been sent.
              </p>
              <Button variant="secondary" onPress={onHaveToken}>
                I have a reset token
              </Button>
              <button
                type="button"
                onClick={onBack}
                className="self-center text-xs text-muted-foreground underline outline-none"
              >
                Back to log in
              </button>
            </div>
          ) : (
            <form
              className="flex flex-col gap-4"
              onSubmit={(event) => {
                event.preventDefault();
                if (email.trim()) mutation.mutate();
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
              <Button type="submit" isDisabled={mutation.isPending || !email.trim()}>
                {mutation.isPending ? "Sending…" : "Send reset link"}
              </Button>
              <button
                type="button"
                onClick={onBack}
                className="self-center text-xs text-muted-foreground underline outline-none"
              >
                Back to log in
              </button>
            </form>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
