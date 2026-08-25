# Business & Product Principles

## Target market

This is **business accounting software (SMB → enterprise), not personal
finance software.** Double-entry bookkeeping, a chart of accounts, and
workspace-based multi-tenancy are business-accounting concepts; a personal
finance tool wouldn't need any of them. The user base has two tiers, mirroring
n8n's own model:

- **Self-serve / source-available**: indie businesses and SMBs, self-hosting
  or using the software free. (Source-available under FSL, not OSI open
  source — see README.md.)
- **Paid tier**: enterprises paying for customization and/or managed hosting.

## No bank feeds — manual entry is the primary data-entry path

There is no live bank feed integration. This is a deliberate constraint, not
a gap to apologize for, and it reshapes priority order:

- Because there's no automatic feed, **receipt/invoice OCR capture and
  CSV/statement import are the primary ways data enters the system** — not
  edge-case conveniences layered on top of an automatic feed. Build and
  polish these as core, not secondary.
- **Manual entry UX (typing in a transaction with no source document) is
  equally load-bearing**, since not everything has a receipt (transfers,
  cash, recurring items). It deserves the same design attention as OCR.
- **CSV/statement import** is the answer to bulk/historical data entry —
  the user can still export from their bank and import, without needing a
  live bank API integration.
- **Reconciliation matters more, not less**, since there's no automatic feed
  to check the ledger against — the software needs to make "does my ledger
  match reality" a fast, low-friction, recurring task.

## Core differentiator: AI-first + least-steps UX

The competitive thesis: **competitors have neither strong AI nor optimized
UX.** Being AI-first only pays off if it's expressed as fewer steps for the
user, not as a bolt-on feature. This is a design constraint that should
shape every screen and endpoint, not a marketing line.

**The organizing principle: AI does the first pass; the human only touches
what's uncertain.** Concretely, per feature area:

- **Receipt/invoice capture**: on a high-confidence extraction, the entry is
  already posted as a draft ready for one-tap approval — not a form the user
  fills in field-by-field. Only low-confidence extractions should interrupt
  the user with a form.
- **CSV/statement import**: one pass does column-mapping *and*
  categorization together. The user sees a single summary ("312
  transactions, 298 auto-categorized, 14 need your input") and only touches
  the exceptions — not a multi-screen wizard of mapping, then reviewing,
  then categorizing row by row.
- **Manual entry**: predictive, not blank-form. Recent payees surfaced
  first; amount and category pre-guessed the moment a payee is typed;
  keyboard-only path from "new entry" to "saved" for the common case.
- **Categorization corrections**: a user's correction silently becomes a
  rule (written to `categorization_rules`) without a separate "create a
  rule" step. The system gets smarter from the correction itself.
- **Anomaly detection**: anomalies surface inline where the user already is
  (in the transaction list), not in a separate inbox the user has to
  remember to check. The explanation and the fix are one action (e.g.
  "looks like a duplicate of Tuesday's entry — merge?").
- **Natural-language ledger query**: ask instead of navigate/filter/export.
  Must be discoverable — a persistent, always-available ask affordance, not
  buried in a menu.
- **Cowork conflict resolution**: default to the obviously-correct
  resolution when one exists (e.g. one side added a note, the other changed
  the amount — not really in conflict), and only force a manual choice when
  the system genuinely can't tell.

Any new feature should be evaluated against this principle before it's
built: *what is the fewest-step version of this, and where exactly does the
AI's first pass end and the human's confirmation begin?*
