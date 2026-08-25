# Accounting Software

An AI-first, source-available double-entry accounting app for businesses and SMBs.
Electron desktop (Mac + Windows), with the same backend deployable multi-tenant
for hosted and on-prem installs.

Built with React, FastAPI, PostgreSQL, LiteLLM and ElectricSQL.

Design decisions live in [ARCHITECTURE.md](ARCHITECTURE.md),
[BUSINESS_PRINCIPLES.md](BUSINESS_PRINCIPLES.md) and
[PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md). Read
[db/README.md](db/README.md) before touching the schema.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Monorepo scaffold, Postgres schema, FastAPI skeleton | **done, under review** |
| 2 | Ledger logic, AI layer, OCR, categorization, anomalies, NL query | migrations + currency done; rest not started |
| 3 | ElectricSQL write-path spike (throwaway) | not started |
| 4 | Electron + React shell | not started |

Phase 1 routers are registered and return **501**, deliberately: a stub has to
be distinguishable from a working endpoint that happens to have no data.

## Layout

```
apps/
  desktop/        Electron + React shell (phase 4)
  server/         Multi-tenant deployment of the same backend + Docker Compose
packages/
  api/            FastAPI app; routers/ is HTTP-only, core/ is the logic
  ai/             AIProvider (LiteLLM). The only place an LLM SDK may be imported
  ui/             Design system (phase 4)
  sync/           ElectricSQL wiring (phase 3)
db/
  migrations/     Numbered SQL, applied in order. The source of truth
  schema.sql      Generated snapshot of the migrated schema, for reading
  verify_*.sql    Prove the invariants, the role isolation and the currency
                  model are actually enforced, not merely intended
  roles.sql       The read-only role that generated text-to-SQL runs as
design-tokens/    Colors, radius, RTL/LTR typography
```

`apps/desktop` and `apps/server` both import `create_app` from `packages/api`.
There is one implementation of the business logic, not two.

## Getting started

```bash
npm run api:install
```

```bash
npm run api:test
```

Bring up Postgres, apply the migrations and roles, and check that the
invariants hold:

```bash
npm run db:up
export DATABASE_URL="postgresql://accounting:accounting@localhost:5432/accounting"
npm run db:apply && npm run db:verify
```

`DATABASE_URL` points at any Postgres — the Compose one above, a scratch
database, or an embedded desktop instance. Compose starts the database empty on
purpose: the migration runner is the only thing that creates the schema.

Then run the API against it:

```bash
npm run api:dev
```

Interactive docs at <http://localhost:8000/docs>.

## Licensing

**[Functional Source License 1.1, Apache 2.0 future license](LICENSE)**
(`FSL-1.1-ALv2`) — the canonical Sentry template, unmodified apart from the
copyright line.

In short: you may read, modify, self-host and use this internally, and provide
professional services around it. You may **not** offer it as a commercial
product or service that competes with ours. Each version converts to Apache-2.0
two years after its release.

This is source-available, not OSI open source — describe it as
"source-available" or "fair source", not "open source". That is the deliberate
trade: AGPL would have been OSI-approved but would not have stopped a
competitor from running a hosted version of this, which is the revenue model.
