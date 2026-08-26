/**
 * Hand-written mirrors of packages/api/src/accounting_api/schemas/*.py.
 * No codegen step yet -- worth adding once the API surface stops changing
 * as fast as it has this phase.
 *
 * Money fields are `string`: FastAPI serializes Decimal as a JSON string
 * (design-tokens has no say here, but the reason is the same shape of
 * argument -- a float would reintroduce the representation error the
 * numeric DB column exists to avoid).
 */

export type AccountType = "asset" | "liability" | "equity" | "revenue" | "expense";
export type NormalBalance = "debit" | "credit";
export type CashFlowCategory = "operating" | "investing" | "financing";

export interface Account {
  id: string;
  workspace_id: string;
  code: string;
  name: string;
  type: AccountType;
  normal_balance: NormalBalance;
  parent_account_id: string | null;
  cash_flow_category: CashFlowCategory | null;
  is_archived: boolean;
  version: number;
}

export type JournalSource =
  | "manual"
  | "ocr_import"
  | "csv_import"
  | "ai_categorized"
  | "reversal"
  | "period_close";

export interface JournalLine {
  id: string;
  account_id: string;
  debit: string;
  credit: string;
  memo: string | null;
}

export interface JournalEntry {
  id: string;
  workspace_id: string;
  entry_date: string;
  memo: string | null;
  source: JournalSource;
  reverses_entry_id: string | null;
  posted_at: string | null;
  version: number;
  created_at: string;
  status: "draft" | "posted";
}

export interface JournalEntryDetail extends JournalEntry {
  lines: JournalLine[];
}

export type FiscalCalendar = "gregorian" | "solar_hijri";

export interface Workspace {
  id: string;
  name: string;
  base_currency: string;
  fiscal_calendar: FiscalCalendar;
  display_unit: string | null;
  display_exponent: number;
  books_locked_through: string | null;
  version: number;
}

export interface Page<T> {
  items: T[];
  next_cursor: string | null;
}

export interface DomainErrorPayload {
  code: string;
  message: string;
  [key: string]: unknown;
}

export type Role = "owner" | "bookkeeper" | "viewer";

export interface User {
  id: string;
  email: string;
  display_name: string | null;
  is_active: boolean;
  version: number;
  created_at: string;
  updated_at: string;
}

export interface Membership {
  workspace_id: string;
  role: Role;
}

export interface Me {
  user: User;
  memberships: Membership[];
}

/** A row from GET /workspaces/{id}/members -- membership joined with the
 * member's own identity, not the bare join table shape. */
export interface WorkspaceMember {
  user_id: string;
  role: Role;
  version: number;
  email: string;
  display_name: string | null;
}
