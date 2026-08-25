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

## Open questions — not yet decided, needed before their build phase

These came up as reasonable extrapolations but haven't been confirmed. Flag
and decide before the phase that depends on them, rather than assuming:

- **Reports** (P&L, balance sheet, cash flow) — the schema supports these,
  but no report-generation design has been discussed. Almost certainly
  needed before MVP is usable as real accounting software — worth deciding
  early even though it wasn't in the original feature discussion.
- **Outbound invoicing** (sending invoices to customers, vs. `documents.kind
  = 'invoice'` currently meaning bills received) — ambiguous in the schema
  as written; needs a decision on whether outbound invoicing is in scope at
  all.
- **Tax handling** — sales tax/VAT rates and jurisdiction logic; currently
  only an extracted OCR field with no calculation logic behind it.
- **User roles/permissions** — nothing yet distinguishes an owner from a
  bookkeeper from a read-only viewer. This likely needs to land before or
  alongside the cowork feature, since multi-user access without roles is a
  real risk once real books are shared.
- **Audit log / activity history UI** — the immutable-ledger design produces
  this data for free, but surfacing it as a user-facing audit trail is a
  separate UI decision not yet made.
