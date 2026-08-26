import {
  Badge,
  Button,
  DataTable,
  Dialog,
  DialogTrigger,
  Select,
  TextField,
} from "@accounting/ui";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createColumnHelper, getCoreRowModel, useReactTable } from "@tanstack/react-table";
import { useState } from "react";

import { addMember, listMembers, removeMember, updateMemberRole } from "../lib/apiClient";
import { useCurrentUser, useRoleIn } from "../lib/CurrentUserContext";
import type { Role, WorkspaceMember } from "../lib/types";

const ROLE_OPTIONS: { value: Role; label: string }[] = [
  { value: "owner", label: "Owner" },
  { value: "bookkeeper", label: "Bookkeeper" },
  { value: "viewer", label: "Viewer" },
];

const columnHelper = createColumnHelper<WorkspaceMember>();

export function MembersScreen({ workspaceId }: { workspaceId: string }) {
  const queryClient = useQueryClient();
  const { user } = useCurrentUser();
  // The server enforces every one of these actions regardless (deps.py's
  // Owner dependency) -- this is purely so a non-owner sees a clean
  // read-only list instead of controls that would 403.
  const isOwner = useRoleIn(workspaceId) === "owner";

  const query = useQuery({
    queryKey: ["members", workspaceId],
    queryFn: () => listMembers(workspaceId),
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ["members", workspaceId] });
    // A role change or removal can target the viewer's own membership (the
    // Select covers every row when they're an owner, and "Leave" always
    // targets self) -- without this, CurrentUserContext's cached role would
    // go stale until something unrelated happened to refetch /auth/me.
    queryClient.invalidateQueries({ queryKey: ["auth", "me"] });
  };

  const roleMutation = useMutation({
    mutationFn: ({ member, role }: { member: WorkspaceMember; role: Role }) =>
      updateMemberRole(workspaceId, member.user_id, { role, version: member.version }),
    onSuccess: invalidate,
  });

  const removeMutation = useMutation({
    mutationFn: (member: WorkspaceMember) => removeMember(workspaceId, member.user_id),
    onSuccess: invalidate,
  });

  const columns = [
    columnHelper.accessor("email", {
      header: "Member",
      cell: (info) => (
        <div className="flex flex-col">
          <span className="font-medium">{info.row.original.display_name ?? info.getValue()}</span>
          <span className="text-xs text-muted-foreground">{info.getValue()}</span>
        </div>
      ),
    }),
    columnHelper.accessor("role", {
      header: "Role",
      cell: (info) => {
        const member = info.row.original;
        if (!isOwner) {
          return <Badge variant="neutral" className="capitalize">{info.getValue()}</Badge>;
        }
        return (
          <Select
            aria-label={`Role for ${member.email}`}
            options={ROLE_OPTIONS}
            selectedKey={member.role}
            onSelectionChange={(key) => roleMutation.mutate({ member, role: key as Role })}
            className="w-40"
          />
        );
      },
    }),
    columnHelper.display({
      id: "actions",
      header: "",
      cell: (info) => {
        const member = info.row.original;
        const isSelf = member.user_id === user.id;
        if (!isOwner && !isSelf) return null;
        return (
          <Button
            variant="ghost"
            size="sm"
            isDisabled={removeMutation.isPending}
            onPress={() => removeMutation.mutate(member)}
          >
            {isSelf ? "Leave" : "Remove"}
          </Button>
        );
      },
    }),
  ];

  const table = useReactTable({
    data: query.data ?? [],
    columns,
    getCoreRowModel: getCoreRowModel(),
  });

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-foreground">Team</h1>
          <p className="text-sm text-muted-foreground">
            {query.data ? `${query.data.length} member${query.data.length === 1 ? "" : "s"}` : "…"}
          </p>
        </div>
        {isOwner ? <AddMemberDialog workspaceId={workspaceId} onAdded={invalidate} /> : null}
      </div>

      {query.isError || roleMutation.isError || removeMutation.isError ? (
        <p className="text-sm text-destructive">
          {((roleMutation.error ?? removeMutation.error ?? query.error) as Error).message}
        </p>
      ) : null}

      <DataTable table={table} emptyState="No members yet." />
    </div>
  );
}

function AddMemberDialog({
  workspaceId,
  onAdded,
}: {
  workspaceId: string;
  onAdded: () => void;
}) {
  const [isOpen, setIsOpen] = useState(false);
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<Role>("bookkeeper");

  const mutation = useMutation({
    mutationFn: () => addMember(workspaceId, { email, role }),
    onSuccess: () => {
      onAdded();
      setEmail("");
      setIsOpen(false);
    },
  });

  return (
    <DialogTrigger isOpen={isOpen} onOpenChange={setIsOpen}>
      <Button onPress={() => setIsOpen(true)}>Add member</Button>
      <Dialog
        title="Add a member"
        description="They need an account already -- invite them to register first if they don't have one."
      >
        <form
          className="flex flex-col gap-4"
          onSubmit={(event) => {
            event.preventDefault();
            mutation.mutate();
          }}
        >
          <TextField
            label="Email"
            type="email"
            value={email}
            onChange={setEmail}
            placeholder="colleague@example.com"
            isRequired
            autoFocus
          />
          <Select
            label="Role"
            options={ROLE_OPTIONS}
            selectedKey={role}
            onSelectionChange={(key) => setRole(key as Role)}
          />
          {mutation.isError ? (
            <p className="text-xs text-destructive">{(mutation.error as Error).message}</p>
          ) : null}
          <Button type="submit" isDisabled={mutation.isPending || !email.trim()}>
            {mutation.isPending ? "Adding…" : "Add member"}
          </Button>
        </form>
      </Dialog>
    </DialogTrigger>
  );
}
