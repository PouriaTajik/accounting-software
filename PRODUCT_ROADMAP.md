# Product Roadmap

Grounded in decisions made so far. See BUSINESS_PRINCIPLES.md for the
least-steps/AI-first design constraint that should shape how each of these
is actually built, not just whether it's in scope.

## MVP

**Core ledger**
- Chart of accounts (asset/liability/equity/revenue/expense, parent/child)
- Double-entry journal, draft → posted lifecycle
- Immutable posted entries, corrections via reversing entries
- Single workspace per install to start (multi-workspace scaffolding exists
  in the schema, but multi-workspace UX can come after MVP)

**Data entry (the primary product surface, given no bank feed)**
- Receipt/invoice photo capture → OCR → AI field extraction → high-confidence
  entries auto-posted as one-tap-approve drafts; low-confidence entries get
  a review form
- CSV/statement import: single-pass AI column-mapping + categorization,
  exception-only review screen
- Fast manual entry: predictive payee/amount/category, keyboard-first flow

**AI layer**
- `AIProvider` abstraction (LiteLLM), cloud-with-API-key and fully-offline
  Ollama both supported from MVP, switchable per workspace in settings
- Categorization: rules-table match first, AI fallback for the rest;
  user corrections silently become rules
- Anomaly detection: statistical detection (z-score/IQR) + AI-generated
  plain-language explanation, surfaced inline in the transaction list
- Natural-language ledger query via a persistent ask affordance

**Reconciliation**
- Mark a batch of entries reconciled against a statement (manual, since
  there's no live feed to check against automatically)

**Reports**
- P&L and balance sheet, computed on-demand via SQL against posted entries
  — no precomputed/materialized balances. Matches the immutable-ledger
  design and is the simplest thing that could work at MVP transaction
  volumes. Cash flow statement follows once these two are proven.
- Tax is a stored/display field only (from OCR extraction or manual entry)
  — no rate tables, jurisdiction logic, or tax calculation. Revisit as its
  own decision if/when real tax reporting is needed.

**Access control**
- Password + session auth added to `packages/api` (credentials table with a
  hashed password, session cookies) — one auth path for both `apps/desktop`
  and `apps/server`, rather than desktop skipping auth. `users` has no
  credential columns yet (deliberately, per migration 0003); this is where
  they land. OIDC/SSO can layer on later as a paid enterprise option without
  touching the session-consuming authorization code.
- `workspace_members.role` (`owner` / `bookkeeper` / `viewer`) already
  exists in the schema (migration 0003) and is currently unenforced —
  the remaining work is a FastAPI dependency that resolves the current user
  from the session and checks role against the requested action.
- This lands in MVP, before cowork, not alongside it as originally assumed:
  auth is what makes "more than one person reaches a shared workspace" a
  real scenario even without realtime sync, so role enforcement matters as
  soon as auth exists.

**Audit trail**
- Simple read-only activity view surfacing what the immutable ledger already
  stores for free: `created_by`/`posted_by`, timestamps, reversing-entry
  chains. No new schema required.

**Platform**
- Electron desktop app, Mac + Windows
- English (LTR) + Persian (RTL) from day one
- Self-hosted deployment path (Docker Compose)

## Later / Phase 2+

- **Cowork realtime multi-device** (Postgres + ElectricSQL) — gated on the
  write-path sync spike from the architecture doc; build after MVP single-
  user flows are solid
- **Managed hosting offering** — the paid convenience tier, once self-hosted
  MVP is proven
- **Multi-workspace UX** — switching between multiple companies/entities in
  one install
- **Enterprise customization intake process** — more a services/business
  process than a software feature, but worth designing the extension points
  for (custom fields, custom categorization rules, custom report templates)
  during MVP so customization isn't a rewrite later

## Not currently planned

- **Outbound invoicing** (sending invoices to customers) — out of scope.
  This is bookkeeping/accounting software, not AR/invoicing software;
  `documents.kind = 'invoice'` continues to mean bills received only.
  Revisit only if customers actually ask for it, rather than building it
  speculatively into an already-large MVP.
