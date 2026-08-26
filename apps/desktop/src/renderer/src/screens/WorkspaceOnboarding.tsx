import { Button, Card, CardContent, CardDescription, CardHeader, CardTitle, TextField } from "@accounting/ui";
import { useMutation } from "@tanstack/react-query";
import { useState } from "react";

import { createWorkspace } from "../lib/apiClient";

export function WorkspaceOnboarding({ onCreated }: { onCreated: (workspaceId: string) => void }) {
  const [name, setName] = useState("");

  const mutation = useMutation({
    mutationFn: () => createWorkspace({ name }),
    onSuccess: (workspace) => onCreated(workspace.id),
  });

  return (
    <div className="flex h-screen items-center justify-center bg-background p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Set up your books</CardTitle>
          <CardDescription>Name your company or workspace to get started.</CardDescription>
        </CardHeader>
        <CardContent>
          <form
            className="flex flex-col gap-4"
            onSubmit={(event) => {
              event.preventDefault();
              if (name.trim()) mutation.mutate();
            }}
          >
            <TextField
              label="Workspace name"
              value={name}
              onChange={setName}
              placeholder="Acme Bookkeeping"
              isRequired
              autoFocus
            />
            {mutation.isError ? (
              <p className="text-xs text-destructive">{mutation.error.message}</p>
            ) : null}
            <Button type="submit" isDisabled={mutation.isPending || !name.trim()}>
              {mutation.isPending ? "Creating…" : "Create workspace"}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
