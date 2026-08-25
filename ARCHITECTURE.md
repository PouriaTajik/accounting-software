# Architecture Overview

See BUSINESS_PRINCIPLES.md and PRODUCT_ROADMAP.md for product context. Two
decisions from there affect this document directly:

- **Business/SMB-to-enterprise accounting, not personal finance** — this is
  why the schema below is double-entry with a chart of accounts rather than
  simple categorized transactions.
- **No bank feed integration.** Receipt/invoice OCR capture and CSV/
  statement import are the primary data-ingestion paths, not conveniences
  layered on top of an automatic feed — this should weight implementation
  priority on `documents` (OCR pipeline) and a CSV import pipeline (not yet
  scaffolded below) at least as heavily as the core ledger CRUD.

## Monorepo layout

```
/apps
  /desktop        Electron shell + React/TS UI. Ships the FastAPI backend as a
                   local subprocess. This is the product most users touch.
  /server          The same FastAPI backend, deployed multi-tenant for the
                   hosted/managed offering and for on-prem "cowork" installs.
                   apps/desktop and apps/server both import from /packages/api
                   — there is exactly one implementation of business logic.
/packages
  /ui              Shared design system: shadcn/React Aria primitives +
                   custom tokens (see design-tokens/). Consumed by desktop UI
                   and, later, any web dashboard.
  /api             FastAPI app, routers, business logic (ledger, invoices,
                   categorization). Framework-agnostic core wrapped by a thin
                   HTTP layer so it's testable without spinning up a server.
  /ai              Provider-agnostic AI layer (LiteLLM-based). Owned by no
                   single feature — OCR, categorization, anomaly explanation,
                   and NL-query all depend on this, never on a raw SDK call.
  /sync            ElectricSQL client wiring + conflict-resolution helpers
                   for the cowork feature.
/db
  schema.sql       Canonical Postgres schema (source of truth for both local
                   embedded Postgres and hosted multi-tenant Postgres).
```

One codebase, two deployment targets (embedded-local vs. multi-tenant-hosted)
— this is the same principle n8n/Supabase use and is what keeps the desktop
app from becoming a second, drifting implementation of your core logic.

## AI layer: one seam, two configs

`packages/ai` exposes a single `AIProvider` class. Every feature (OCR field
extraction, categorization, anomaly explanations, NL ledger queries) talks to
`AIProvider`, never to `openai`/`anthropic`/`ollama` SDKs directly. Whether a
workspace is running fully offline (Ollama, no network egress) or has plugged
in their own OpenAI/Anthropic/Azure key is just a row in
`workspace_ai_config` — resolved at request time, swappable in the UI without
a redeploy or a code change. This is also what lets a single desktop build
serve both your indie users (cloud key, easiest setup) and compliance-bound
enterprises (offline, air-gapped) without maintaining two builds.

## The "cowork" realtime multi-device feature

**Goal:** an on-prem enterprise install where multiple people, multiple
devices, see the same ledger update in real time, including while offline
intermittently.

**Why not a generic CRDT (e.g. Yjs) for this:** CRDTs solve "merge arbitrary
concurrent edits automatically," which is right for text/whiteboards but
wrong for a ledger — you never want two people's conflicting numeric edits
to silently auto-merge into a third number nobody approved. A ledger's
correctness comes from *append-only posting*, not clever merging.

**Chosen approach:**
- One Postgres instance per on-prem deployment — the durable source of truth.
- **ElectricSQL** replicates Postgres data down to a local embedded database
  on each connected device in real time, and syncs local writes back up. It
  is purpose-built for exactly this "one Postgres, many collaborating
  devices, offline-tolerant" shape, so you're not building a bespoke sync
  protocol.
- **Posted journal entries are immutable and append-only** (see
  `db/schema.sql`) — corrections happen via reversing entries. This removes
  almost all conflict surface by construction: there is nothing to merge
  once something is posted, because nobody ever mutates a posted row.
- **Drafts** (unposted invoices, in-progress categorization rules) use a
  `version` integer column — optimistic concurrency. If two devices edit the
  same draft offline, the later write wins and the loser is shown a "this
  was changed elsewhere" diff, rather than an automatic silent merge. This
  is a deliberate, explicit choice given the domain: a person should always
  see and confirm a conflict on money-related data.
- If you later want live cursors / "someone else is typing" on a single
  in-progress invoice, that's a good candidate for a small Yjs document
  scoped *only* to that draft's in-progress form state — never to posted
  data. Worth deferring until you see demand for it.

## Scalability notes

- Postgres schema is written to be identical whether it's SQLite-for-local
  or Postgres-hosted-multi-tenant — `db/schema.sql` targets Postgres syntax
  directly; local mode runs an embedded Postgres (e.g. via `pg_embed` /
  a bundled Postgres binary) rather than a parallel SQLite schema, so there
  is one schema to maintain and no migration rewrite when a user upgrades
  from local to hosted.
- Multi-tenant hosted mode: `workspace_id` is the tenant boundary on every
  table from day one, even in single-user local mode — this means turning
  on hosted multi-tenancy later is a deployment change, not a schema change.
- AI cost/latency control at scale: categorization and anomaly detection are
  designed to avoid a full LLM call per transaction (see inline notes in
  `packages/ai/provider.py` usage) — this matters more as a hosted tenant's
  transaction volume grows, since LLM cost scales with your hosting margin.
