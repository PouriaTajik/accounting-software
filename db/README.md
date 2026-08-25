# Database

`schema.sql` is the canonical schema for both deployment targets — the
embedded Postgres inside the desktop app and hosted/on-prem multi-tenant
Postgres. There is no second schema.

## Apply order

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v nl_query_password="'<secret>'" -f db/roles.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/verify_schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/verify_roles.sql
```

Roles come before the verification scripts: `verify_roles.sql` asserts against
the role `roles.sql` creates.

Run `roles.sql` **once per database, not once per cluster.** The `nl_query`
role is a cluster-level object, but every `GRANT`/`REVOKE` in that file applies
only to the database it is run against — so a second database in the same
cluster starts out with `nl_query` able to read its base tables.
`verify_roles.sql` fails loudly on a database that was missed, which is most of
why it exists.

`schema.sql` is **not** re-runnable — it is a bootstrap file for a fresh
database, and applying it twice fails on the first `CREATE TABLE`. That is
deliberate: `CREATE TABLE IF NOT EXISTS` would silently skip a table whose
definition had drifted, which on a ledger is worse than an error. Migrations
are still an open decision (see below). `roles.sql` *is* re-runnable.

Both verification scripts run entirely inside a transaction they roll back, so
they are safe against a live database, and both exit non-zero naming the first
check that fails:

- **`verify_schema.sql`** asserts each ledger invariant is actually enforced by
  the database. Run it after any schema change — it is the regression suite for
  the parts of correctness that live in Postgres rather than in Python.
- **`verify_roles.sql`** asserts the `nl_query` role cannot reach the ledger.
  Run it after any change to `roles.sql` or to the `ledger_query` views.

Both currently pass against PostgreSQL 16.

### Without Docker

If a local Postgres is already running, skip Compose entirely:

```bash
createdb accounting
DATABASE_URL="postgresql:///accounting" npm run db:apply
DATABASE_URL="postgresql:///accounting" npm run db:verify:local
```

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

**Still open:**
- **Single currency.** `workspaces.base_currency` is the only currency column;
  lines carry no currency or FX rate. Fine for MVP, structurally awkward to
  retrofit later. Worth deciding deliberately rather than by default.
- **Tax.** Only an extracted OCR field in `documents.extracted_fields`. No
  rates, jurisdictions, or a tax line concept in the ledger.
- **Row-level security.** Composite FKs stop cross-tenant *references*; they do
  not stop a buggy query from *reading* the wrong tenant. RLS policies on
  `workspace_id` would close that for hosted mode. Not added — it changes how
  every connection must be configured, and you asked to review the schema
  before it grows.
- **Migrations.** `schema.sql` is the source of truth for a fresh database,
  which is correct now and insufficient the moment you have a user with data.
  Sqitch/Alembic/plain numbered SQL is an unmade decision.
- **ElectricSQL replica identity.** Electric consumes logical replication;
  update/delete events generally need `REPLICA IDENTITY FULL` on synced tables.
  Deliberately not set here — it roughly doubles WAL volume, and the phase-3
  spike should establish what Electric actually requires before it goes into
  the canonical schema.
