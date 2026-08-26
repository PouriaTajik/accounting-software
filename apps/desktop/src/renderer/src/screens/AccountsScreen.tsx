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

import { createAccount, listAccounts } from "../lib/apiClient";
import type { Account, AccountType, NormalBalance } from "../lib/types";

const ACCOUNT_TYPES: { value: AccountType; label: string }[] = [
  { value: "asset", label: "Asset" },
  { value: "liability", label: "Liability" },
  { value: "equity", label: "Equity" },
  { value: "revenue", label: "Revenue" },
  { value: "expense", label: "Expense" },
];

const DEBIT_NORMAL: AccountType[] = ["asset", "expense"];

const columnHelper = createColumnHelper<Account>();

const columns = [
  columnHelper.accessor("code", {
    header: "Code",
    cell: (info) => <span className="tabular-figure text-muted-foreground">{info.getValue()}</span>,
  }),
  columnHelper.accessor("name", {
    header: "Name",
    cell: (info) => <span className="font-medium">{info.getValue()}</span>,
  }),
  columnHelper.accessor("type", {
    header: "Type",
    cell: (info) => <Badge variant="neutral" className="capitalize">{info.getValue()}</Badge>,
  }),
  columnHelper.accessor("normal_balance", {
    header: "Normal balance",
    cell: (info) => <span className="capitalize text-muted-foreground">{info.getValue()}</span>,
  }),
];

export function AccountsScreen({ workspaceId }: { workspaceId: string }) {
  const query = useQuery({
    queryKey: ["accounts", workspaceId],
    queryFn: () => listAccounts(workspaceId),
  });

  const table = useReactTable({
    data: query.data ?? [],
    columns,
    getCoreRowModel: getCoreRowModel(),
  });

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-foreground">Chart of accounts</h1>
          <p className="text-sm text-muted-foreground">
            {query.data ? `${query.data.length} account${query.data.length === 1 ? "" : "s"}` : "…"}
          </p>
        </div>
        <NewAccountDialog workspaceId={workspaceId} />
      </div>

      {query.isError ? (
        <p className="text-sm text-destructive">{(query.error as Error).message}</p>
      ) : (
        <DataTable table={table} emptyState="No accounts yet. Add your first one above." />
      )}
    </div>
  );
}

function NewAccountDialog({ workspaceId }: { workspaceId: string }) {
  const queryClient = useQueryClient();
  const [isOpen, setIsOpen] = useState(false);
  const [code, setCode] = useState("");
  const [name, setName] = useState("");
  const [type, setType] = useState<AccountType>("asset");

  const mutation = useMutation({
    mutationFn: () => {
      const normal_balance: NormalBalance = DEBIT_NORMAL.includes(type) ? "debit" : "credit";
      return createAccount(workspaceId, { code, name, type, normal_balance });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["accounts", workspaceId] });
      setCode("");
      setName("");
      setIsOpen(false);
    },
  });

  return (
    <DialogTrigger isOpen={isOpen} onOpenChange={setIsOpen}>
      <Button onPress={() => setIsOpen(true)}>New account</Button>
      <Dialog title="New account" description="Added to this workspace's chart of accounts.">
        <form
          className="flex flex-col gap-4"
          onSubmit={(event) => {
            event.preventDefault();
            mutation.mutate();
          }}
        >
          <TextField label="Code" value={code} onChange={setCode} placeholder="1000" isRequired tabularFigure />
          <TextField label="Name" value={name} onChange={setName} placeholder="Cash" isRequired />
          <Select
            label="Type"
            options={ACCOUNT_TYPES}
            selectedKey={type}
            onSelectionChange={(key) => setType(key as AccountType)}
          />
          {mutation.isError ? (
            <p className="text-xs text-destructive">{(mutation.error as Error).message}</p>
          ) : null}
          <Button type="submit" isDisabled={mutation.isPending || !code.trim() || !name.trim()}>
            {mutation.isPending ? "Adding…" : "Add account"}
          </Button>
        </form>
      </Dialog>
    </DialogTrigger>
  );
}
