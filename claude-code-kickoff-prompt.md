# Project kickoff prompt for Claude Code

Paste this as your opening message in Claude Code, in the repo root.

---

I'm building an open-source, AI-based accounting desktop app (Mac & Windows),
published on GitHub, with an open-core revenue model (enterprise customization
+ paid managed hosting — similar to n8n). Below are the architecture decisions
already made. Do not re-litigate these; build against them. Where something
genuinely isn't decided, stop and ask me rather than guessing.

## Build order (important)

Work in this sequence, confirming with me before moving to the next phase:

1. **Repo scaffolding + Postgres schema + backend architecture** (this phase)
2. **FastAPI backend**: core ledger logic, AI abstraction layer, OCR pipeline,
   categorization, anomaly detection, NL query endpoint
3. **ElectricSQL write-path spike** (see "Cowork feature" below) — a small,
   throwaway proof of concept validating multi-device write sync BEFORE we
   build the real cowork feature on top of it
4. **Electron + React shell**, wired to the backend from phase 2

Do not start on the Electron shell or frontend UI components until phases
1-3 are working and I've reviewed them.

## Monorepo structure

```
/apps
  /desktop        Electron + React/TS shell. Runs the FastAPI backend as a
                   local subprocess in dev/local mode.
  /server          Same FastAPI backend, deployed multi-tenant for hosted
                   and on-prem installs. apps/desktop and apps/server both
                   import from packages/api — one implementation of business
                   logic, not two.
/packages
  /ui              Shared design system: shadcn/ui built on React Aria,
                   customized tokens (see "Design system" below).
  /api             FastAPI app: routers + business logic (ledger, invoices,
                   categorization), structured so core logic is testable
                   without a running server.
  /ai              Provider-agnostic AI abstraction (LiteLLM-based).
  /sync            ElectricSQL client wiring + conflict-resolution helpers
                   for the cowork feature.
/db
  schema.sql       Canonical Postgres schema — source of truth for both
                   local embedded Postgres and hosted multi-tenant Postgres.
```

## Backend & data

- **Python + FastAPI** for the backend, shared unmodified between desktop
  (local subprocess) and hosted/on-prem multi-tenant deployment.
- **PostgreSQL** as the only datastore — including in local desktop mode
  (embedded Postgres, not a parallel SQLite schema), so there is one schema
  to maintain and no rewrite when a user upgrades from local to hosted.
- **`workspace_id` is the tenant boundary on every table from day one**,
  even in single-user local mode.
- **Ledger correctness by construction, not convention**: journal entries
  are append-only. Once `posted_at` is set, a row must be immutable —
  enforce this with a Postgres trigger that raises on UPDATE of a posted
  row, not just application-level validation. Corrections are reversing
  entries. Draft (unposted) rows and other mutable tables (accounts,
  categorization rules) use a `version` integer column for optimistic
  concurrency.
- Core tables to start from: `workspaces`, `workspace_ai_config`, `accounts`,
  `journal_entries`, `journal_lines`, `documents`, `categorization_rules`,
  `anomaly_flags`, `devices`. Ask me before adding tables beyond this set
  for phase 1 — I want to review the schema before it grows.

## AI abstraction layer

- Build one `AIProvider` class in `packages/ai`, backed by **LiteLLM**.
  Every feature (OCR field extraction, categorization fallback, anomaly
  explanation, NL ledger query) calls this class. Nothing outside
  `packages/ai` may import an `openai`/`anthropic`/`ollama` SDK directly.
- Config is per-workspace (`workspace_ai_config` table), resolved at
  request time: `mode` (`cloud_openai` | `cloud_anthropic` |
  `cloud_azure_openai` | `cloud_custom_endpoint` | `local_ollama`), `model`,
  optional `api_key` / `api_base` / `organization`. Switching a workspace
  between a client-supplied cloud API key and fully offline Ollama must be
  a config change, never a code branch.
- Use-case-specific design (avoid full-LLM-call-per-item where a cheaper
  method works — this matters for both cost and offline quality):
  - **OCR**: dedicated OCR engine (PaddleOCR or Tesseract) extracts raw
    text/layout first; `AIProvider` only does structured field extraction
    (vendor, line items, amounts, tax) from that text.
  - **Categorization**: check `categorization_rules` table for a match
    first; `AIProvider` is the fallback for unmatched/ambiguous
    transactions only.
  - **Anomaly detection**: statistical checks (z-score/IQR on transaction
    patterns) do the actual detection; `AIProvider` only generates the
    human-readable explanation of a flagged anomaly.
  - **NL ledger query**: text-to-SQL against a fixed, read-only schema
    view, executed with a read-only DB role — never against a live write
    connection.

## Cowork feature (on-prem multi-device realtime)

- One Postgres instance per on-prem deployment is the source of truth.
  **ElectricSQL** (Apache 2.0, self-hostable, GA since March 2025) syncs
  Postgres to a local embedded database on each connected device.
- **Known risk to validate first**: Electric's write-path (device → server)
  sync is newer than its read-path and described by third parties as
  "still maturing." Before building the real cowork feature, do a small
  throwaway spike: two local clients, one Postgres backend, concurrent
  writes to a mutable draft row, and confirm (a) how conflicts actually
  surface to the app, and (b) whether that matches the "explicit version
  conflict, no silent auto-merge" design below. Report back what you find
  before we build on top of it. If it doesn't hold up, tell me — don't
  route around it silently.
- **Conflict philosophy** (needed regardless of what the spike finds):
  posted journal entries are immutable, so there is nothing to merge once
  something is posted. Drafts use the `version` column for optimistic
  concurrency — on conflict, show the user both versions and let them
  choose, never auto-merge financial data.
- Live cursors / "someone else is typing" on a single in-progress invoice
  can be a small Yjs document scoped only to that draft's form state —
  defer this until the core sync is solid.

## Design system

- **React + TypeScript**, **shadcn/ui built on React Aria** as the
  component primitive layer, customized — not default shadcn look.
- **Tailwind CSS**, configured with logical-property utilities
  (`ms-`/`me-`/`ps-`/`pe-`, `text-start`/`text-end`) — never
  `ml-`/`mr-`/`left-`/`right-`/`text-left` in new components, so RTL is
  automatic rather than retrofitted.
- **TanStack Table + TanStack Query** for ledger views, reconciliation
  screens, transaction lists.
- **Radius**: moderate, not pill-shaped and not sharp-enterprise. Base
  `--radius: 0.625rem` (10px), scaled down for inputs/badges, up only for
  hero/marketing surfaces.
- **Color**: indigo primary (`hsl(243 75% 59%)`), warm amber accent for
  "needs attention" / AI-suggested states rather than harsh red,
  desaturated neutrals so dense transaction tables stay calm and readable.
  Full token set is in `design-tokens/tokens.css` if it already exists in
  this repo — otherwise generate it matching these values.
- **LTR/RTL from day zero**: English (LTR) is primary, Persian (RTL) is
  the first supported RTL locale. Set `document.documentElement.lang` and
  `.dir` once at the app root based on active locale — never inferred
  per-component. Font pairing: Inter for LTR, Vazirmatn for RTL. Numeric/
  currency values must stay LTR-isolated regardless of surrounding text
  direction (use a `.tabular-figure` style with `direction: ltr;
  unicode-bidi: isolate; font-variant-numeric: tabular-nums;`) — this
  matters because a Persian UI must never flip the digit order of a dollar
  amount.

## Licensing

- Not MIT. Use a license that protects the open-core hosting revenue model
  — AGPL-3.0, or a source-available license like BSL/FSL (what Sentry and
  n8n use). Flag this decision to me explicitly before you add a LICENSE
  file; don't default to one silently.

## What I want from you right now

Start with phase 1: scaffold the monorepo structure above, write
`db/schema.sql` per the rules above, and set up the FastAPI app skeleton in
`packages/api` (routers stubbed, no business logic yet). Show me the schema
and structure before writing any endpoint logic.
