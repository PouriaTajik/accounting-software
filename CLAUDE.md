# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

AI-first, source-available double-entry accounting software for SMB-to-enterprise, not personal finance. Electron desktop (Mac + Windows) and a hosted/on-prem multi-tenant deployment share **one** FastAPI backend — `apps/desktop` and `apps/server` both import `create_app` from `packages/api`. There is no bank feed integration by design: receipt/invoice OCR and CSV/statement import are the primary data-entry paths, not conveniences layered on an automatic feed (see `BUSINESS_PRINCIPLES.md`).

Design decisions live in `ARCHITECTURE.md`, `BUSINESS_PRINCIPLES.md`, and `PRODUCT_ROADMAP.md`. **Read `db/README.md` before touching the schema** — it explains the row-level-security model and the invariants below in depth.

Licensing is FSL-1.1-ALv2 (source-available, not OSI open source) — flag any licensing question rather than assuming.

## Commands

Backend (Python, `packages/api` + `packages/ai`):
```bash
npm run api:install       # pip install -e packages/ai && packages/api[dev]
npm run api:test          # pytest packages/api
npm run api:dev           # uvicorn --reload, port 8000; docs at /docs
pytest packages/api/tests/test_accounts.py -q       # single file
pytest packages/api/tests/test_accounts.py::test_x  # single test
ruff check packages/api/ packages/ai/               # lint (config in root pyproject.toml)
```

Database (Postgres via Docker Compose, or any Postgres reachable at `DATABASE_URL`):
```bash
npm run db:up                                   # starts Postgres empty on purpose
export DATABASE_URL="postgresql://accounting:accounting@localhost:5432/accounting"
npm run db:migrate        # apply pending migrations (forward-only, no rollback)
npm run db:roles          # creates accounting_app / nl_query roles (idempotent)
npm run db:apply          # migrate + roles
npm run db:verify         # runs every db/verify_*.sql suite against DATABASE_URL
npm run db:snapshot       # regenerate db/schema.sql after adding a migration; commit it
```
`ACCOUNTING_PROVISIONING_DATABASE_URL` (owner role, e.g. `accounting:accounting@...`) is required for `POST /workspaces` to work at all — `accounting_app` structurally cannot create a workspace (no session to scope RLS to yet). `ACCOUNTING_DATABASE_URL` should be the `accounting_app` role, not the owner — connecting the API as the owner silently disables every RLS policy (a startup check warns in local mode, refuses to serve in server mode).

Frontend (`apps/desktop`, `packages/ui`; npm workspaces):
```bash
npm install                                  # root install, all workspaces
npm run desktop:dev                          # electron-vite dev; needs API + Postgres already running
npm run typecheck --workspace=@accounting/ui
npm run typecheck --workspace=@accounting/desktop
```
`ACCOUNTING_CORS_ALLOW_ORIGINS=["http://localhost:5173"]` is required in `.env` for `desktop:dev` to reach the API (dev-only; a packaged build loads via `file://`).

Adding a migration: `db/migrations/000N_name.sql` (next number, no gaps) → `npm run db:migrate` against a scratch DB → `npm run db:verify` → `npm run db:snapshot` and commit `db/schema.sql`. Migrations are forward-only and checksummed — editing an applied one is refused by the runner.

## Architecture

### Backend layering (`packages/api/src/accounting_api/`)
- `routers/` — HTTP only: parse request, call `core/`, return. No business logic here, enforced by `test_core_does_not_import_a_web_framework`.
- `core/` — business logic, framework-agnostic. Every function takes an already workspace-scoped `asyncpg.Connection` (from `Database.workspace()`), never a bare `workspace_id` it filters on itself — a forgotten `WHERE` clause is not a bug class that exists here, because RLS enforces the tenant boundary at the database.
- `db.py` — three connection pools, one per trust boundary: `.workspace(id)` (the `accounting_app` role, RLS-bound, used for every normal request), `.read_only(id)` (the `nl_query` role, for generated text-to-SQL), `.provision()` (the owner role, only for creating a workspace).
- `errors.py` — `DomainError` subclasses + `translate_database_error()`, which maps Postgres SQLSTATEs to typed errors by inspecting the trigger's message text (several distinct guards share one SQLSTATE, e.g. 23001 covers posted-entry immutability, period-lock, fiscal-year-closed, and the tenant-boundary guard — the message is what tells them apart). Registered as FastAPI exception handlers in `main.py`.
- `deps.py` — `WorkspaceId` (from the `X-Workspace-Id` header; will later come from an authenticated session, there is no auth yet — every endpoint is currently open) and `not_implemented()` for phase-2 stubs (raises 501, deliberately distinguishable from a working endpoint with no data).
- A stub router calls `not_implemented("description")`; a real one wires `router → core → asyncpg`, with `Database.workspace(workspace_id)` opening the transaction.

Implemented routers: `health`, `accounts`, `journal-entries`, `workspaces`. Still-stub routers (501): `ai_config`, `documents`, `imports`, `categorization`, `anomalies`, `query` — this is the AI/OCR/data-entry layer, phase 2's unfinished half.

### The database is where invariants live, not Python
`db/README.md`'s table is the reference; the short version:
- A posted journal entry (and its lines) is immutable — triggers, not app code, enforce it. There is no `update_posted_entry`; `reverse_entry` is the only correction mechanism.
- Posting requires debits = credits, ≥2 lines, non-zero value, and an open fiscal period/unlocked date — enforced in the draft→posted transition. Routers/core surface the database's refusal via `translate_database_error`, they don't duplicate the check.
- Every mutable table has a DB-owned `version` column bumped by trigger on every UPDATE — the API pattern is always `UPDATE ... WHERE id = $1 AND version = $2`, and 0 rows back means someone else wrote first (`VersionConflict`, carries both sides, never auto-merged). If you add a new versioned table, it needs its own trigger wired — `workspaces` went six migrations without one before that bug was caught (see migration 0006).
- Row-level security: `accounting_app` (the API's role) is deliberately **not** the table owner, because an owner is exempt from its own RLS policies. `workspace_id = app_current_workspace()` (set via `SET LOCAL app.workspace_id` inside `Database.workspace()`) gates every policy; unscoped means zero rows, not unfiltered.
- PATCH endpoints use `payload.model_dump(exclude={"version"}, exclude_unset=True)`, not a plain `is not None` filter — the latter makes "field omitted" and "field explicitly sent as `null`" indistinguishable, silently blocking any client from ever clearing a nullable column.
- Currency: Level 0 only (one currency per workspace) — `journal_lines.currency = base_currency` is enforced by a constraint; Level 1 columns (`fx_rate`, `original_debit/credit`) exist but are inert until that constraint is dropped. Toman is a display unit over rial (`workspaces.display_unit`/`display_exponent`), never a second currency.
- Amounts are `numeric(24,6)` (widened from `numeric(18,2)` in migration 0002 for rial magnitudes) — the shared TS/Pydantic `Money` type must match this precision, and amounts serialize as strings (never float) end to end.

### Frontend (`apps/desktop`, `packages/ui`)
- `packages/ui` is shadcn-style primitives built on `react-aria-components` (not Radix — a deliberate deviation from default shadcn), styled from `design-tokens/tokens.css` and `design-tokens/tailwind.config.ts`, which are the source of truth for color/radius/typography and must not be forked per-app — extend, don't edit.
- Logical properties only (`ms-`/`me-`/`ps-`/`pe-`, `text-start`/`text-end`), never `ml-`/`mr-`/`left-`/`right-` — this is what makes Persian RTL automatic instead of retrofitted later. Any ledger amount, date, or account code gets the `.tabular-figure` class (`direction: ltr; unicode-bidi: isolate`) so it never mirrors under RTL.
- `document.documentElement.lang`/`.dir` are set once at the app root (`main.tsx`), never inferred per-component. No i18n library is chosen yet — English-only for now.
- `apps/desktop/src/renderer/src/lib/apiClient.ts` + `types.ts` are hand-written mirrors of the Pydantic schemas (no codegen yet) — when a backend schema changes, update both by hand. Watch for endpoint shapes that intentionally diverge, e.g. `GET /journal-entries` (list) omits `lines` to avoid an N+1 fetch on a growing feed; only `GET /journal-entries/{id}` (detail) includes them.
- Electron does not spawn the API or an embedded Postgres as a subprocess yet — `npm run db:up` and `npm run api:dev` are run separately in dev. `ReadinessGate` polls `GET /api/v1/health/ready` (liveness alone isn't enough — the API subprocess and Postgres start independently) before showing any UI.

### Two threat models, two roles, one schema
`db/roles.sql` creates `accounting_app` (the API's role — DML only, no DDL, not the owner, so RLS actually binds) and `nl_query` (generated text-to-SQL's role — read-only, statement-timed-out, reaches only the `ledger_query` schema, no privileges on `public` at all, not even `USAGE`). Never widen `accounting_app`'s privileges to "make something work" — if a write is structurally impossible for it (like creating a workspace), that's answered by a separate narrowly-scoped connection (`Database.provision()`), not by weakening RLS.
