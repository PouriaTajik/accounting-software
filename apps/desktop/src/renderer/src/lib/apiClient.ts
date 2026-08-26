import type {
  Account,
  DomainErrorPayload,
  JournalEntry,
  JournalEntryDetail,
  Me,
  Page,
  Role,
  User,
  Workspace,
  WorkspaceMember,
} from "./types";

// "localhost", not "127.0.0.1" -- the two are different *sites* for
// SameSite cookie purposes (SameSite compares the host string, not the
// resolved address), and ACCOUNTING_CORS_ALLOW_ORIGINS is already
// http://localhost:5173 (see .env.example). A mismatch here is harmless
// until a session cookie is involved: SameSite=lax then silently drops it
// on every cross-site fetch, which looks exactly like "login succeeded but
// nothing else believes it."
const BASE_URL = "http://localhost:8000/api/v1";

export class ApiError extends Error {
  constructor(
    public status: number,
    public payload: DomainErrorPayload,
  ) {
    super(payload.message);
    this.name = "ApiError";
  }
}

interface RequestOptions {
  method?: "GET" | "POST" | "PATCH" | "DELETE";
  workspaceId?: string;
  body?: unknown;
  signal?: AbortSignal;
}

async function apiFetch<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const headers: Record<string, string> = {};
  if (options.body !== undefined) headers["Content-Type"] = "application/json";
  if (options.workspaceId) headers["X-Workspace-Id"] = options.workspaceId;

  const response = await fetch(`${BASE_URL}${path}`, {
    method: options.method ?? "GET",
    headers,
    body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
    signal: options.signal,
    // The API and the dev server are different origins (127.0.0.1:8000 vs
    // localhost:5173), so the session cookie set by POST /auth/login is
    // neither stored nor replayed without this -- main.py already sets
    // allow_credentials=True on CORS to allow it.
    credentials: "include",
  });

  if (response.status === 204) return undefined as T;

  const payload = await response.json();
  if (!response.ok) throw new ApiError(response.status, payload as DomainErrorPayload);
  return payload as T;
}

// --- health -------------------------------------------------------------

export interface HealthReady {
  status: "ok" | "degraded";
  database: boolean;
}

export function getHealthReady(signal?: AbortSignal): Promise<HealthReady> {
  return apiFetch("/health/ready", { signal });
}

// --- workspaces -----------------------------------------------------------

export function createWorkspace(input: {
  name: string;
  base_currency?: string;
  fiscal_calendar?: Workspace["fiscal_calendar"];
}): Promise<Workspace> {
  return apiFetch("/workspaces", { method: "POST", body: input });
}

export function getWorkspace(workspaceId: string): Promise<Workspace> {
  return apiFetch(`/workspaces/${workspaceId}`, { workspaceId });
}

export function updateWorkspace(
  workspaceId: string,
  input: { version: number } & Partial<
    Pick<Workspace, "name" | "base_currency" | "fiscal_calendar" | "books_locked_through">
  >,
): Promise<Workspace> {
  return apiFetch(`/workspaces/${workspaceId}`, { method: "PATCH", workspaceId, body: input });
}

// --- accounts ---------------------------------------------------------------

export function listAccounts(
  workspaceId: string,
  options: { includeArchived?: boolean } = {},
): Promise<Account[]> {
  const query = options.includeArchived ? "?include_archived=true" : "";
  return apiFetch(`/accounts${query}`, { workspaceId });
}

export function createAccount(
  workspaceId: string,
  input: {
    code: string;
    name: string;
    type: Account["type"];
    normal_balance: Account["normal_balance"];
    parent_account_id?: string | null;
    cash_flow_category?: Account["cash_flow_category"];
  },
): Promise<Account> {
  return apiFetch("/accounts", { method: "POST", workspaceId, body: input });
}

export function archiveAccount(
  workspaceId: string,
  accountId: string,
  version: number,
): Promise<Account> {
  return apiFetch(`/accounts/${accountId}/archive`, {
    method: "POST",
    workspaceId,
    body: { version },
  });
}

// --- journal entries --------------------------------------------------------

/** The feed shape has no `lines` -- GET /journal-entries is deliberately
 * lightweight so listing a growing ledger doesn't fetch every entry's lines
 * on every page. Use getJournalEntry for the full detail. */
export function listJournalEntries(
  workspaceId: string,
  options: { status?: "draft" | "posted"; cursor?: string; limit?: number } = {},
): Promise<Page<JournalEntry>> {
  const params = new URLSearchParams();
  if (options.status) params.set("status", options.status);
  if (options.cursor) params.set("cursor", options.cursor);
  if (options.limit) params.set("limit", String(options.limit));
  const query = params.toString() ? `?${params.toString()}` : "";
  return apiFetch(`/journal-entries${query}`, { workspaceId });
}

export function getJournalEntry(workspaceId: string, entryId: string): Promise<JournalEntryDetail> {
  return apiFetch(`/journal-entries/${entryId}`, { workspaceId });
}

export interface JournalLineInput {
  account_id: string;
  debit?: string;
  credit?: string;
  memo?: string | null;
}

export function createDraftEntry(
  workspaceId: string,
  input: {
    entry_date: string;
    memo?: string | null;
    source?: JournalEntryDetail["source"];
    lines: JournalLineInput[];
  },
): Promise<JournalEntryDetail> {
  return apiFetch("/journal-entries", { method: "POST", workspaceId, body: input });
}

export function postJournalEntry(
  workspaceId: string,
  entryId: string,
  version: number,
): Promise<JournalEntryDetail> {
  return apiFetch(`/journal-entries/${entryId}/post`, {
    method: "POST",
    workspaceId,
    body: { version },
  });
}

export function reverseJournalEntry(
  workspaceId: string,
  entryId: string,
  memo?: string,
): Promise<JournalEntryDetail> {
  return apiFetch(`/journal-entries/${entryId}/reverse`, {
    method: "POST",
    workspaceId,
    body: { memo },
  });
}

// --- auth ---------------------------------------------------------------

export function register(input: {
  email: string;
  password: string;
  display_name?: string;
}): Promise<User> {
  return apiFetch("/auth/register", { method: "POST", body: input });
}

export function login(input: { email: string; password: string }): Promise<User> {
  return apiFetch("/auth/login", { method: "POST", body: input });
}

export function logout(): Promise<void> {
  return apiFetch("/auth/logout", { method: "POST" });
}

export function getMe(signal?: AbortSignal): Promise<Me> {
  return apiFetch("/auth/me", { signal });
}

export function requestPasswordReset(email: string): Promise<{ detail: string }> {
  return apiFetch("/auth/password-reset/request", { method: "POST", body: { email } });
}

export function confirmPasswordReset(token: string, newPassword: string): Promise<void> {
  return apiFetch("/auth/password-reset/confirm", {
    method: "POST",
    body: { token, new_password: newPassword },
  });
}

// --- workspace members ---------------------------------------------------

export function listMembers(workspaceId: string): Promise<WorkspaceMember[]> {
  return apiFetch(`/workspaces/${workspaceId}/members`);
}

export function addMember(
  workspaceId: string,
  input: { email: string; role: Role },
): Promise<WorkspaceMember> {
  return apiFetch(`/workspaces/${workspaceId}/members`, { method: "POST", body: input });
}

export function updateMemberRole(
  workspaceId: string,
  userId: string,
  input: { role: Role; version: number },
): Promise<WorkspaceMember> {
  return apiFetch(`/workspaces/${workspaceId}/members/${userId}`, {
    method: "PATCH",
    body: input,
  });
}

export function removeMember(workspaceId: string, userId: string): Promise<void> {
  return apiFetch(`/workspaces/${workspaceId}/members/${userId}`, { method: "DELETE" });
}
