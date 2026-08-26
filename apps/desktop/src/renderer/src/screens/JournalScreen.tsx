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

import { createDraftEntry, listAccounts, listJournalEntries, postJournalEntry } from "../lib/apiClient";
import type { Account, JournalEntry } from "../lib/types";

const columnHelper = createColumnHelper<JournalEntry>();

// No "Amount" column: GET /journal-entries is deliberately lightweight (no
// `lines`), so a growing ledger doesn't fetch every entry's lines on every
// page of the feed. A total would need either a backend-computed column or
// a follow-up detail fetch per row -- worth adding once this screen needs
// it, not assumed here.
const columns = [
  columnHelper.accessor("entry_date", {
    header: "Date",
    cell: (info) => <span className="tabular-figure">{info.getValue()}</span>,
  }),
  columnHelper.accessor("memo", {
    header: "Memo",
    cell: (info) => info.getValue() ?? <span className="text-muted-foreground">—</span>,
  }),
  columnHelper.accessor("status", {
    header: "Status",
    cell: (info) => (
      <Badge variant={info.getValue() === "posted" ? "success" : "neutral"} className="capitalize">
        {info.getValue()}
      </Badge>
    ),
  }),
];

export function JournalScreen({ workspaceId }: { workspaceId: string }) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: ["journal-entries", workspaceId],
    queryFn: () => listJournalEntries(workspaceId, { limit: 50 }),
  });

  const postMutation = useMutation({
    mutationFn: ({ entryId, version }: { entryId: string; version: number }) =>
      postJournalEntry(workspaceId, entryId, version),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["journal-entries", workspaceId] }),
  });

  const entries = query.data?.items ?? [];

  const tableColumns = [
    ...columns,
    columnHelper.display({
      id: "actions",
      header: "",
      cell: (info) =>
        info.row.original.status === "draft" ? (
          <Button
            size="sm"
            variant="outline"
            onPress={() =>
              postMutation.mutate({ entryId: info.row.original.id, version: info.row.original.version })
            }
            isDisabled={postMutation.isPending}
          >
            Post
          </Button>
        ) : null,
    }),
  ];

  const table = useReactTable({
    data: entries,
    columns: tableColumns,
    getCoreRowModel: getCoreRowModel(),
  });

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-foreground">Journal</h1>
          <p className="text-sm text-muted-foreground">
            {query.data ? `${entries.length} entr${entries.length === 1 ? "y" : "ies"}` : "…"}
          </p>
        </div>
        <NewEntryDialog workspaceId={workspaceId} />
      </div>

      {query.isError ? (
        <p className="text-sm text-destructive">{(query.error as Error).message}</p>
      ) : (
        <DataTable table={table} emptyState="No journal entries yet." />
      )}
    </div>
  );
}

interface LineDraft {
  accountId: string;
  amount: string;
  side: "debit" | "credit";
}

/** Deliberately fixed at two lines -- the common case of money moving from one
 * account to another. A line-by-line editor for arbitrary entries is a
 * natural next step, not built yet. */
function NewEntryDialog({ workspaceId }: { workspaceId: string }) {
  const queryClient = useQueryClient();
  const [isOpen, setIsOpen] = useState(false);
  const [entryDate, setEntryDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [memo, setMemo] = useState("");
  const [lineA, setLineA] = useState<LineDraft>({ accountId: "", amount: "", side: "debit" });
  const [lineB, setLineB] = useState<LineDraft>({ accountId: "", amount: "", side: "credit" });

  const accountsQuery = useQuery({
    queryKey: ["accounts", workspaceId],
    queryFn: () => listAccounts(workspaceId),
    enabled: isOpen,
  });
  const accountOptions = (accountsQuery.data ?? []).map((account: Account) => ({
    value: account.id,
    label: `${account.code} · ${account.name}`,
  }));

  const mutation = useMutation({
    mutationFn: () =>
      createDraftEntry(workspaceId, {
        entry_date: entryDate,
        memo: memo || null,
        lines: [lineA, lineB].map((line) => ({
          account_id: line.accountId,
          debit: line.side === "debit" ? line.amount : undefined,
          credit: line.side === "credit" ? line.amount : undefined,
        })),
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["journal-entries", workspaceId] });
      setMemo("");
      setLineA({ accountId: "", amount: "", side: "debit" });
      setLineB({ accountId: "", amount: "", side: "credit" });
      setIsOpen(false);
    },
  });

  const canSubmit =
    lineA.accountId && lineB.accountId && lineA.amount && lineB.amount && lineA.amount === lineB.amount;

  return (
    <DialogTrigger isOpen={isOpen} onOpenChange={setIsOpen}>
      <Button onPress={() => setIsOpen(true)}>New entry</Button>
      <Dialog title="New journal entry" description="Saved as a draft; post it once it's ready.">
        <form
          className="flex flex-col gap-4"
          onSubmit={(event) => {
            event.preventDefault();
            mutation.mutate();
          }}
        >
          <TextField
            label="Date"
            type="date"
            value={entryDate}
            onChange={setEntryDate}
            isRequired
            tabularFigure
          />
          <TextField label="Memo" value={memo} onChange={setMemo} placeholder="What happened?" />

          <LineEditor label="Debit" line={lineA} onChange={setLineA} accountOptions={accountOptions} />
          <LineEditor label="Credit" line={lineB} onChange={setLineB} accountOptions={accountOptions} />

          {lineA.amount && lineB.amount && lineA.amount !== lineB.amount ? (
            <p className="text-xs text-warning">Debit and credit must match to balance.</p>
          ) : null}
          {mutation.isError ? (
            <p className="text-xs text-destructive">{(mutation.error as Error).message}</p>
          ) : null}
          <Button type="submit" isDisabled={mutation.isPending || !canSubmit}>
            {mutation.isPending ? "Saving…" : "Save draft"}
          </Button>
        </form>
      </Dialog>
    </DialogTrigger>
  );
}

function LineEditor({
  label,
  line,
  onChange,
  accountOptions,
}: {
  label: string;
  line: LineDraft;
  onChange: (line: LineDraft) => void;
  accountOptions: { value: string; label: string }[];
}) {
  return (
    <div className="flex flex-col gap-2 rounded-md border border-border p-3">
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <Select
        options={accountOptions}
        placeholder="Choose account…"
        selectedKey={line.accountId || null}
        onSelectionChange={(key) => onChange({ ...line, accountId: (key as string) ?? "" })}
      />
      <TextField
        placeholder="0.00"
        value={line.amount}
        onChange={(amount) => onChange({ ...line, amount })}
        tabularFigure
        isRequired
      />
    </div>
  );
}
