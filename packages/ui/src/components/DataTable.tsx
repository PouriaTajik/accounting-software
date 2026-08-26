import { flexRender, type Table as TanStackTable } from "@tanstack/react-table";
import type { ReactNode } from "react";

import { cn } from "../lib/cn";

export interface DataTableProps<TData> {
  table: TanStackTable<TData>;
  /** Shown in place of rows when the query has resolved with nothing. */
  emptyState?: ReactNode;
  onRowAction?: (row: TData) => void;
  className?: string;
}

/**
 * Headless by design -- this owns markup and styling only. Sorting, filtering
 * and pagination state live in the caller's `useReactTable()` config, per the
 * TanStack Table + TanStack Query pairing decided for ledger views.
 */
export function DataTable<TData>({
  table,
  emptyState,
  onRowAction,
  className,
}: DataTableProps<TData>) {
  const rows = table.getRowModel().rows;

  return (
    <div className={cn("overflow-x-auto rounded-lg border border-border", className)}>
      <table className="w-full border-collapse text-sm">
        <thead>
          {table.getHeaderGroups().map((headerGroup) => (
            <tr key={headerGroup.id} className="border-b border-border bg-muted/50">
              {headerGroup.headers.map((header) => (
                <th
                  key={header.id}
                  className="px-3 py-2 text-start text-xs font-medium uppercase tracking-wide text-muted-foreground"
                  colSpan={header.colSpan}
                >
                  {header.isPlaceholder
                    ? null
                    : flexRender(header.column.columnDef.header, header.getContext())}
                </th>
              ))}
            </tr>
          ))}
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td
                colSpan={table.getAllColumns().length}
                className="px-3 py-8 text-center text-sm text-muted-foreground"
              >
                {emptyState ?? "No rows."}
              </td>
            </tr>
          ) : (
            rows.map((row) => (
              <tr
                key={row.id}
                onClick={onRowAction ? () => onRowAction(row.original) : undefined}
                className={cn(
                  "border-b border-border last:border-0",
                  onRowAction && "cursor-pointer hover:bg-muted/50",
                )}
              >
                {row.getVisibleCells().map((cell) => (
                  <td key={cell.id} className="px-3 py-2 text-foreground">
                    {flexRender(cell.column.columnDef.cell, cell.getContext())}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}
