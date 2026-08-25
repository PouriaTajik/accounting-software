# Database

One schema serves both deployment targets — the embedded Postgres inside the
desktop app and hosted/on-prem multi-tenant Postgres. There is no second
schema.

| File | What it is |
|---|---|
| `migrations/NNNN_*.sql` | **The source of truth.** Hand-written, applied in order, never edited once applied. |
| `schema.sql` | **Generated.** A `pg_dump` snapshot of the migrated schema, for reading and diffing. Nothing applies it. |
| `roles.sql` | The read-only role that generated text-to-SQL runs as. Needs a password, so it is not a migration. |
| `verify_*.sql` | Assertion suites. Each rolls back; each exits non-zero naming the first failure. |

## Getting a database up

```bash
export DATABASE_URL="postgresql://accounting:accounting@localhost:5432/accounting"

npm run db:apply     # migrations, then roles
npm run db:verify    # all three assertion suites
```

`db:apply` is `db:migrate` followed by `db:roles`. Roles come after because
`verify_roles.sql` asserts against the role `roles.sql` creates.

Nothing creates the schema except the migration runner — Compose deliberately
mounts nothing into `/docker-entrypoint-initdb.d`. A schema applied at first
boot would be invisible to the runner, which would then try to apply `0001`
over existing objects and fail.

## Migrations

```bash
npm run db:migrate        # apply everything pending
npm run db:migrate:dry    # show what would be applied
npm run db:snapshot       # regenerate db/schema.sql afterwards, and commit it
```

The runner lives in `packages/api/src/accounting_api/migrations.py`. Its design
is driven by the desktop target, which is the hard case: migrations run on user
machines, offline, possibly skipping many versions, with nobody around to fix a
half-applied schema.

- **Forward-only.** No down-migrations. You cannot un-ship a version a user has
  already run, so a rollback path is a fiction that invites careless
  migrations. Fix a bad migration by writing the next one.
- **One transaction each.** Postgres has transactional DDL, so a migration
  lands completely or not at all. A migration needing `CREATE INDEX
  CONCURRENTLY` opts out with a `-- migrate:no-transaction` marker and gives up
  that guarantee knowingly.
- **Fail closed.** Applied migrations are checksummed, so editing one is
  refused; so is a gap in the numbering, and so is a database carrying a
  version this build does not ship (which means the app was downgraded).
- **Serialized by advisory lock**, so two instances starting at once cannot
  both apply the same migration.

### Adding one

1. `db/migrations/000N_short_name.sql` — next number, no gaps.
2. `npm run db:migrate` against a scratch database.
3. `npm run db:verify` — all three suites.
4. `npm run db:snapshot` and commit the regenerated `db/schema.sql`.

Numbers are the ordering, so two branches that both add an `000N` collide on
purpose: the runner refuses and a human renames one.

`npm run db:snapshot -- --check` writes nothing and fails if the committed
snapshot is stale. That is the CI form, once there is CI.

## Verification suites

All three run inside a transaction they roll back, so they are safe against a
live database (a scratch one is still the sane choice). All three currently
pass against PostgreSQL 16.

- **`verify_schema.sql`** (25 checks) — each ledger invariant is actually
  enforced by the database. The regression suite for the correctness that lives
  in Postgres rather than in Python.
- **`verify_roles.sql`** (24 checks) — the `nl_query` role cannot reach the
  ledger. Run after any change to `roles.sql` or the `ledger_query` views.
- **`verify_currency.sql`** (22 checks) — toman stays a display unit, rial
  magnitudes fit, and the Level 0 gate holds.

Run `roles.sql` **once per database, not once per cluster.** The `nl_query`
role is a cluster-level object, but every `GRANT`/`REVOKE` in that file applies
only to the database it is run against — so a second database in the same
cluster starts out with `nl_query` able to read its base tables.
`verify_roles.sql` fails loudly on a database that was missed, which is most of
why it exists.

## What is enforced in the database, and why

Application-level validation is not enough here. Once ElectricSQL is syncing
writes from multiple devices, an invariant that lives only in a FastAPI
handler is an invariant that a sync path can walk around. So:

| Invariant | Mechanism |
|---|---|
| A posted entry is immutable | `BEFORE UPDATE` trigger raises on any posted row |
| A posted entry cannot be deleted | `BEFORE DELETE` trigger, break-glass flag only |
| A posted entry's **lines** are immutable | `BEFORE INSERT/UPDATE/DELETE` trigger on `journal_lines`, checked against the parent's `posted_at` |
| Posting requires debits = credits | balance check in the draft→posted transition |
| Posting requires ≥ 2 lines and non-zero value | same check |
| Posting is a transition, not an initial state | `BEFORE INSERT` rejects a row born with `posted_at` set |
| A line is single-sided and non-negative | `journal_lines_single_sided` check constraint |
| No row references another tenant's row | composite `(workspace_id, id)` foreign keys |
| `workspace_id` is never reassigned | trigger on every mutable table |
| Concurrent edits collide loudly | DB-owned `version` counter, bumped on every UPDATE |

Optimistic concurrency is therefore always:

```sql
UPDATE accounts SET name = $3 WHERE id = $1 AND version = $2;
-- 0 rows affected  ->  someone else wrote first; surface both versions
```

The database bumps `version` itself, so a client that forgets to increment it
still cannot silently clobber a concurrent write.

## Currency, toman, and the Level 0 gate

**Toman is a display unit, not a currency.** IRR is the ISO 4217 code; toman
has none, and one toman is ten rial exactly, always — a fixed denomination like
dollars-to-cents, not an exchange rate. Modelling it as a second currency would
put a pair that can never fluctuate through the FX machinery: rounding on a
relationship that must never round, and a balance sheet able to show FX
gain/loss between rial and toman.

So the ledger stores rial and toman is presentation — `workspaces.display_unit`
names it, `display_exponent` shifts it. Rial is the smaller unit, so conversion
is exact both ways; storing toman would lose the odd rial. A future
redenomination changes the exponent, not the schema.

`currencies` carries a constraint named
`currencies_toman_is_a_display_unit_not_a_currency`, so the predictable mistake
— a developer adding `IRT` because a user asked for toman — fails with that
sentence as the error message.

The ledger runs at **Level 0**: one currency per workspace. Level 1's columns
are already in `journal_lines` (`currency`, `original_debit`/`original_credit`,
`fx_rate`, `fx_rate_source`), held inert by one constraint:

```sql
ALTER TABLE journal_lines DROP CONSTRAINT journal_lines_single_currency_until_l1;
```

That drop is the entire schema half of Level 1. It is gated rather than open
because foreign-currency entries without rate capture in the UI, FX gain/loss
accounts, and a revaluation decision produce books that balance and are wrong.

The columns are there now rather than later because posted lines are immutable
by trigger: adding a `NOT NULL` column to them afterwards means disabling that
trigger to rewrite every posted row, or a nullable column forever with
`COALESCE` through every report. `0002_currency.sql` already has to switch the
trigger off for its backfill, with the ledger essentially empty.

`fx_rate` is recorded **per line**, not looked up from a rates table. There is
no bank feed to source rates from, and in the Iranian market there is no single
rate to source — official, NIMA and free-market rates differ, and the books must
record the one actually transacted at. `fx_rate_source` says which.

Amounts are `numeric(24,6)`. `numeric(18,2)` left only sixteen digits ahead of
the decimal, against a currency where an ordinary SMB invoice runs to ten
figures. The extra scale is headroom for FX conversion, not a claim that
fractional rial exist.

Callers do not carry any of this: a `BEFORE INSERT` trigger fills
`base_currency`, `currency`, the original amounts and an identity rate from the
workspace. An `INSERT` written before `0002` still works unchanged, which is
why `verify_schema.sql` needed no edits.

## Break-glass: deleting a workspace

`ON DELETE CASCADE` from `workspaces` hits the posted-entry delete guard, so
deleting a workspace that has posted books **fails by default**. Tenant
offboarding and GDPR erasure opt in explicitly, per transaction:

```sql
BEGIN;
SET LOCAL app.ledger_purge = 'on';
DELETE FROM workspaces WHERE id = $1;
COMMIT;
```

Nothing in the normal request path may set that flag. Keep it to a dedicated
admin/offboarding code path so it stays greppable.

## Natural-language query isolation

`ledger_query` is a read-only projection of the ledger, and it is the only
schema the `nl_query` role can reach (`db/roles.sql`). Two things make it safe
independently of how well the prompt is written:

1. **Every view filters on `app_current_workspace()`**, read from
   `SET LOCAL app.workspace_id`. Tenant scoping does not depend on the model
   remembering a `WHERE` clause, and an unscoped session sees *nothing* rather
   than everything.
2. **The role holds no privileges on `public` at all** — not on the base tables,
   and not even `USAGE` on the schema. It reads the `ledger_query` views by
   ownership chaining and has no `INSERT`/`UPDATE`/`DELETE` grant anywhere, so
   there is no write path to reach. This is the control that holds.

Assume a scanned receipt will eventually contain text attempting to steer the
model. The control is the role's capability, not the instructions.

**A correction worth being explicit about.** Earlier drafts of this file and of
`roles.sql` claimed the role's `default_transaction_read_only` setting meant a
generated `DELETE` "cannot commit". That is false, and testing against PG16
confirmed it: `default_transaction_read_only`, `statement_timeout`,
`idle_in_transaction_session_timeout` and `search_path` are all `USERSET`
parameters, so `nl_query` can override any of them with a plain `SET` —

```
nl_query=> SET default_transaction_read_only = off;   -- succeeds
nl_query=> SET statement_timeout = 0;                 -- succeeds
```

Postgres offers no way to forbid that for a non-superuser. Those settings are
kept because they make the *accidental* case fail fast, but they are defaults,
not boundaries. Only the privilege grant in point 2 is a boundary, which is why
`verify_roles.sql` tests that layer and not those settings.

The GUC defaults apply at login, which `SET ROLE` does not trigger, so
`verify_roles.sql` can only assert they are *configured*. To watch them take
effect, log in as the role directly:

```bash
psql "postgresql://nl_query:<secret>@localhost/accounting" \
     -c "SHOW default_transaction_read_only;"   # -> on
psql "postgresql://nl_query:<secret>@localhost/accounting" \
     -c "SELECT * FROM public.journal_lines;"   # -> permission denied for schema public
```

---

## Decisions I made while writing this — flag anything you disagree with

These follow from rules you already set, but they are choices, so they are
listed rather than buried:

- **Dropped `uuid-ossp`** in favour of the built-in `gen_random_uuid()`
  (PG13+). One less extension to install, and no superuser requirement on
  managed Postgres or the embedded desktop instance.
- **`journal_lines` gained `workspace_id`.** Your rule was "`workspace_id` on
  every table from day one"; it was the one table without it. It also lets
  ElectricSQL sync the table with a workspace-scoped shape, which it otherwise
  could not do without joining through the parent.
- **Composite `(workspace_id, id)` foreign keys throughout**, so a line can
  never reference another workspace's account. Previously `journal_lines.
  account_id` pointed at `accounts(id)` with nothing tying the two tenants
  together.
- **`journal_lines` check tightened** from `debit = 0 OR credit = 0`, which
  permitted a both-zero line and negative amounts on either side.
- **`created_by_device_id` is now nullable** — hosted CSV import and API-created
  entries have no originating desktop device.
- **Added columns (no new tables):** `journal_entries.reverses_entry_id` (makes
  "corrections are reversing entries" auditable rather than merely stated, with
  a unique index so an entry is reversed at most once),
  `documents.extraction_confidence` (the least-steps rule in
  BUSINESS_PRINCIPLES.md needs a threshold to branch on),
  `anomaly_flags.detector` (which statistical check fired, since the LLM only
  writes the explanation), and `version`/`created_at`/`updated_at` where they
  were missing.
- **`source` gained `csv_import` and `reversal`.** CSV import is a primary
  ingestion path per BUSINESS_PRINCIPLES.md and had no way to identify itself.

## Open questions — decide before the phase that needs them

**Decided — both land in phase 2, not yet written:**

- **`users` + roles.** `devices.user_id` is currently an unconstrained, nullable
  uuid pointing at nothing. Approved to add, which also unblocks the phase-3
  sync spike from baking in an identity-free model.
- **`reconciliations`.** Needed for the MVP "mark a batch of entries reconciled
  against a statement" flow — somewhere to record the batch and the statement
  it was matched against.

**Decided and now built:**

- **Migrations: numbered SQL + a small runner.** Sqitch is a Perl program and
  cannot be bundled into an Electron app; Alembic's draw is autogenerate, which
  needs SQLAlchemy models that do not exist and would not produce this DDL
  anyway. See the Migrations section above.
- **Currency: Level 0 behaviour, Level 1 columns, toman as a display unit.**
  See the currency section above.

**Decided — not yet written:**

- **`users` + roles.** `devices.user_id` is currently an unconstrained, nullable
  uuid pointing at nothing. Approved to add, which also unblocks the phase-3
  sync spike from baking in an identity-free model. Lands **before** RLS: the
  policies may want to reference a user, not only a workspace.
- **Row-level security.** Approved. Composite FKs stop cross-tenant
  *references*; they do nothing about a buggy query *reading* the wrong tenant,
  which is the highest-severity bug class in a multi-tenant accounting product.
  Three traps to handle when it lands: the table owner **bypasses RLS by
  default** (needs `FORCE ROW LEVEL SECURITY` plus an owner/app role split —
  otherwise the policies silently do nothing, exactly like the ineffective
  `REVOKE ... FROM public` this file used to claim); `SET LOCAL` never plain
  `SET`, or the scope leaks across pooled connections; and a `verify_rls.sql`
  asserting both, so the owner-bypass trap fails a test rather than becoming an
  incident. `Database.workspace()` in `packages/api` already sets
  `app.workspace_id` transaction-locally, so the connection side is ready.
- **Fiscal periods and closing.** Approved. There is no period concept in the
  schema at all, and a correct P&L needs period boundaries and a notion of a
  locked period. It interacts with immutability — closing entries are entries,
  and locking a period is a posting-time check — so it touches trigger logic
  that `verify_schema.sql` covers. Reports are the acceptance test for
  `accounts.type`: the five values cannot currently express a contra account
  (accumulated depreciation is asset-typed with a credit balance), and cash-flow
  classification has nowhere to live.
- **Reconciliations.** Needed for the MVP "mark a batch of entries reconciled
  against a statement" flow — somewhere to record the batch and the statement
  it was matched against.
- **Tax: storage seam only.** No rates, jurisdictions or calculation logic in
  MVP; a place for OCR to put what it extracted. Jurisdiction logic is a quarter
  of work and not the differentiator.
- **Outbound invoicing: out of MVP**, explicitly. `documents.kind = 'invoice'`
  means bills *received*. Sending invoices would need customers, invoice line
  items, payment status and AR aging — a sales surface bolted onto a
  bookkeeping product whose differentiator is ingestion.

**Still open:**

- **ElectricSQL replica identity.** Electric consumes logical replication;
  update/delete events generally need `REPLICA IDENTITY FULL` on synced tables.
  Deliberately not set here — it roughly doubles WAL volume, and the phase-3
  spike should establish what Electric actually requires before it goes into
  the canonical schema.
- **Level 1 multi-currency.** The schema is ready (drop one constraint). What
  is not decided: FX gain/loss account handling, and whether period-end
  revaluation is in scope. Needed before the gate comes off.
- **Minor-unit enforcement.** `currencies.minor_unit` is recorded but nothing
  rejects a fractional rial. A trigger could; deferred until posting-time
  rounding rules are settled, since that is where it belongs.
